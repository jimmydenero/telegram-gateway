import Foundation
import GatewayCore
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOPosix
import ServiceLifecycle
import Synchronization

/// A stand-in for Volgenic's side of the link: a WebSocket server on 127.0.0.1 (a port the
/// system picks) that accepts its tokens at `/messages/telegram/link`, refuses others, and
/// lets a test read and write frames on each connection. (`RefusingVolgenic` plays the 401.)
final class FakeVolgenic: Sendable {
    /// One accepted connection. Frames from the gateway are buffered; `next` reads them in
    /// order.
    final class Connection: Sendable {
        private let received = Mutex<(frames: [JSONValue], read: Int, closed: Bool)>(([], 0, false))
        let outbound: WebSocketOutboundWriter
        let authorization: String?

        init(outbound: WebSocketOutboundWriter, authorization: String?) {
            self.outbound = outbound
            self.authorization = authorization
        }

        func receive(_ frame: JSONValue) { received.withLock { $0.frames.append(frame) } }
        func ended() { received.withLock { $0.closed = true } }
        var isClosed: Bool { received.withLock { $0.closed } }
        /// Frames received and not yet read by `next`.
        var unread: [JSONValue] { received.withLock { Array($0.frames.dropFirst($0.read)) } }

        /// The next frame from the gateway, or a failure after `timeout`.
        func next(timeout: Duration = .seconds(5)) async throws -> JSONValue {
            let deadline = ContinuousClock.now + timeout
            while true {
                let (frame, closed) = received.withLock { r -> (JSONValue?, Bool) in
                    guard r.frames.count > r.read else { return (nil, r.closed) }
                    r.read += 1
                    return (r.frames[r.read - 1], false)
                }
                if let frame { return frame }
                if closed { throw FakeError("the connection closed") }
                if ContinuousClock.now > deadline { throw FakeError("no frame within \(timeout)") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Reads frames until one of `type` arrives.
        func next(ofType type: String, timeout: Duration = .seconds(5)) async throws -> JSONValue {
            while true {
                let frame = try await next(timeout: timeout)
                if frame["type"]?.stringValue == type { return frame }
            }
        }

        func send(_ frame: JSONValue) async throws {
            try await outbound.write(.text(frame.serializedString()))
        }

        func close(code: UInt16) async throws {
            try await outbound.close(.unknown(code), reason: "test")
        }
    }

    let tokens: Set<String>
    final class Registry: Sendable {
        let state = Mutex<(connections: [Connection], attempts: Int)>(([], 0))
    }

    private let registry = Registry()
    private let port = Mutex<Int?>(nil)
    private let group: ServiceGroup
    private let runner: Task<Void, any Error>
    private let started: AsyncStream<Int>

    convenience init(token: String) async throws {
        try await self.init(tokens: [token])
    }

    init(tokens: Set<String>) async throws {
        self.tokens = tokens
        let router = Router(context: BasicWebSocketRequestContext.self)
        let registry = self.registry
        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Int.self)
        started = startedStream
        router.add(middleware: TokenCheck(tokens: tokens, registry: registry))
        router.ws("/messages/telegram/link", onUpgrade: { inbound, outbound, context in
            let connection = Connection(outbound: outbound, authorization: context.request.headers[.authorization])
            registry.state.withLock { $0.connections.append(connection) }
            do {
                for try await message in inbound.messages(maxSize: 64 << 20) {
                    if case .text(let text) = message, let frame = try? JSONValue.parse(text) { connection.receive(frame) }
                }
            } catch {}
            connection.ended()
        })
        var logger = Logger(label: "fake-volgenic")
        logger.logLevel = .critical
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in startedContinuation.yield(channel.localAddress?.port ?? 0) },
            logger: logger
        )
        group = ServiceGroup(configuration: .init(services: [app], logger: logger))
        let group = self.group
        runner = Task { try await group.run() }
        var iterator = started.makeAsyncIterator()
        let bound = await iterator.next() ?? 0
        port.withLock { $0 = bound }
    }

    var baseURL: String { "http://127.0.0.1:\(port.withLock { $0 } ?? 0)" }
    var attempts: Int { registry.state.withLock { $0.attempts } }
    var connectionCount: Int { registry.state.withLock { $0.connections.count } }

    /// The `index`th connection (0-based), waiting for it to arrive.
    func connection(_ index: Int, timeout: Duration = .seconds(5)) async throws -> Connection {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let connection = registry.state.withLock({ $0.connections.count > index ? $0.connections[index] : nil }) { return connection }
            if ContinuousClock.now > deadline { throw FakeError("no connection #\(index) within \(timeout)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func stop() async {
        await group.triggerGracefulShutdown()
        _ = try? await runner.value
    }
}

/// Answers 401 to an upgrade without the right token, as Volgenic does.
struct TokenCheck: RouterMiddleware {
    typealias Context = BasicWebSocketRequestContext
    let tokens: Set<String>
    let registry: FakeVolgenic.Registry

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // A refused upgrade may pass through here twice (WebSocket path, then plain HTTP), so
        // tests compare counts over time rather than expect an exact number.
        registry.state.withLock { $0.attempts += 1 }
        guard tokens.contains(where: { request.headers[.authorization] == "Bearer \($0)" }) else { return Response(status: .unauthorized) }
        return try await next(request, context)
    }
}

struct FakeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Volgenic refusing a token: answers every request on 127.0.0.1 with a plain
/// `HTTP/1.1 401 Unauthorized` and closes. (Hummingbird's WebSocket upgrader answers a
/// refused upgrade with 400, so the WebSocket fake cannot play this part.)
final class RefusingVolgenic: Sendable {
    final class Counter: Sendable {
        let value = Mutex(0)
    }

    final class Refuse: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let counter: Counter
        var received = ""
        var answered = false

        init(counter: Counter) {
            self.counter = counter
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            received += buffer.readString(length: buffer.readableBytes) ?? ""
            guard !answered, received.contains("\r\n\r\n") else { return }
            answered = true
            counter.value.withLock { $0 += 1 }
            let response = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            let out = context.channel.allocator.buffer(string: response)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { [context] _ in context.close(promise: nil) }
        }
    }

    private let channel: any Channel
    private let counter = Counter()

    init() async throws {
        let counter = self.counter
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(Refuse(counter: counter)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    var baseURL: String { "http://127.0.0.1:\(channel.localAddress?.port ?? 0)" }
    var attempts: Int { counter.value.withLock { $0 } }

    func stop() async {
        try? await channel.close()
    }
}
