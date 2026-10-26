import Foundation
import GatewayCore
import Logging
import Synchronization

/// Timings of a link (docs/link.md "Connection"). Tests shorten them.
public struct LinkTiming: Sendable {
    /// The first reconnect delay; it doubles after each failed attempt up to `maxBackoff`.
    public var initialBackoff: Duration = .seconds(1)
    public var maxBackoff: Duration = .seconds(60)
    /// Each delay is randomised by up to this fraction, up or down.
    public var jitter: Double = 0.2
    /// A connection that stayed open this long resets the backoff to `initialBackoff`.
    public var stableAfter: Duration = .seconds(30)
    /// The gateway pings this often…
    public var pingInterval: Duration = .seconds(30)
    /// …and drops the connection when nothing (frame or pong) arrived for this long.
    public var idleTimeout: Duration = .seconds(90)
    /// How often the sign-in state is checked for changes to push as `auth_state`.
    public var authPollInterval: Duration = .seconds(1)

    public init() {}

    public static let standard = LinkTiming()

    /// The delay before reconnect attempt `attempt` (0-based), before jitter.
    public func backoff(attempt: Int) -> Duration {
        let factor = Double(1 << min(attempt, 30))
        let seconds = min(initialBackoff.seconds * factor, maxBackoff.seconds)
        return .milliseconds(Int64(seconds * 1000))
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// What a link is doing, for `tgw link list`, `GET /v1/admin/links` and `/v1/admin/status`.
public struct LinkStatus: Sendable, Equatable {
    public enum State: String, Sendable {
        /// Opening the WebSocket.
        case connecting
        /// Open; `hello` was sent.
        case connected
        /// Waiting to reconnect after a failure.
        case waiting
        /// Volgenic refused the token (HTTP 401 or close code 4401). No more attempts until
        /// the link is changed or the gateway reloaded.
        case unauthorized
        /// No token for this link in the secret store.
        case noToken = "no_token"
        /// Closed by the gateway (removed, or shutting down).
        case stopped
    }

    public var baseURL: String
    public var state: State
    /// When the link entered `state`.
    public var since: Date
    public var lastError: String?
    public var lastErrorAt: Date?
    /// When the next attempt is due, while `waiting`.
    public var retryAt: Date?

    public var isConnected: Bool { state == .connected }

    public var json: JSONValue {
        [
            "base_url": .string(baseURL),
            "state": .string(state.rawValue),
            "connected": .bool(isConnected),
            "since": .date(since),
            "last_error": .optional(lastError),
            "last_error_at": .date(lastErrorAt),
            "retry_at": .date(retryAt),
        ]
    }
}

/// One outbound link to a Volgenic server (docs/link.md). It dials
/// `<base>/messages/telegram/link` with the link token, sends `hello`, answers `request`
/// frames through the gateway's own API as the admin, streams the event log after
/// `subscribe`, and pushes `auth_state` when the sign-in state changes. It reconnects with
/// backoff, and gives up only when Volgenic refuses the token.
public actor GatewayLinkClient {
    public nonisolated let baseURL: String
    public nonisolated let token: String
    private let endpoint: URL
    private let transport: any LinkTransport
    private let handler: any LinkRequestHandling
    private let eventLog: EventLog
    private let telegram: any TelegramControl
    private let version: String
    private let timing: LinkTiming
    private let clock: any GatewayClock
    private let logger: Logger

    private var status: LinkStatus
    private var runner: Task<Void, Never>?
    private var connection: (any LinkConnection)?

    public init(
        baseURL: String, token: String, transport: any LinkTransport, handler: any LinkRequestHandling, eventLog: EventLog,
        telegram: any TelegramControl, version: String, timing: LinkTiming = .standard, clock: any GatewayClock = SystemClock(),
        logger: Logger = Logger(label: "link")
    ) throws {
        self.baseURL = baseURL
        self.token = token
        endpoint = try LinkSettings.endpoint(for: baseURL)
        self.transport = transport
        self.handler = handler
        self.eventLog = eventLog
        self.telegram = telegram
        self.version = version
        self.timing = timing
        self.clock = clock
        var logger = logger
        logger[metadataKey: "link"] = .string(baseURL)
        self.logger = logger
        status = LinkStatus(baseURL: baseURL, state: .stopped, since: clock.now)
    }

    public func currentStatus() -> LinkStatus { status }

    /// Starts connecting; returns at once.
    public func start() {
        guard runner == nil else { return }
        runner = Task { await self.run() }
    }

    /// Closes the connection (code 1001) and stops for good.
    public func stop() async {
        let runner = self.runner
        self.runner = nil
        runner?.cancel()
        connection?.close(code: 1001, reason: "gateway closing the link")
        connection = nil
        await runner?.value
        set(.stopped)
    }

    // MARK: Connection loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            set(.connecting)
            let opened: any LinkConnection
            do {
                opened = try await transport.connect(url: endpoint, token: token)
            } catch LinkTransportError.unauthorized {
                refused("Volgenic refused the link token (HTTP 401); add the link again with a new token")
                return
            } catch {
                if Task.isCancelled { return }
                failed("\(error)")
                await wait(attempt: attempt)
                attempt += 1
                continue
            }
            connection = opened
            set(.connected)
            logger.info("link connected to \(endpoint.absoluteString)")
            let openedAt = ContinuousClock.now
            let ending = await serve(opened)
            opened.close(code: 1001, reason: "")
            connection = nil
            if Task.isCancelled { return }
            if case .closed(let code, _) = ending, code == 4401 {
                refused("Volgenic revoked the link (close code 4401); add the link again with a new token")
                return
            }
            failed("\(ending)")
            if ContinuousClock.now - openedAt >= timing.stableAfter { attempt = 0 }
            await wait(attempt: attempt)
            attempt += 1
        }
    }

    private func wait(attempt: Int) async {
        let base = timing.backoff(attempt: attempt).seconds
        let jittered = base * (1 + Double.random(in: -timing.jitter...timing.jitter))
        let delay = Duration.milliseconds(Int64(max(jittered, 0) * 1000))
        status.state = .waiting
        status.since = clock.now
        status.retryAt = clock.now.addingTimeInterval(delay.seconds)
        try? await Task.sleep(for: delay)
    }

    private func set(_ state: LinkStatus.State) {
        guard status.state != state else { return }
        status.state = state
        status.since = clock.now
        status.retryAt = nil
    }

    private func failed(_ message: String) {
        status.lastError = message
        status.lastErrorAt = clock.now
        logger.warning("link: \(message)")
    }

    private func refused(_ message: String) {
        failed(message)
        set(.unauthorized)
        logger.error("link: \(message); not retrying until the link changes")
    }

    // MARK: One connection

    /// Runs one open connection until it ends; returns why it ended.
    private func serve(_ connection: any LinkConnection) async -> LinkTransportError {
        let lastHeard = Mutex(ContinuousClock.now)
        let sender = FrameSender(connection: connection)
        let hello = await currentAuth()
        do {
            let head = (try? await eventLog.headSeq()) ?? 0
            try await sender.send(LinkFrames.hello(version: version, authState: hello.state, account: hello.account, headSeq: head))
        } catch let error as LinkTransportError {
            return error
        } catch {
            return .closed(code: nil, reason: "\(error)")
        }

        let (frames, framesIn) = AsyncStream.makeStream(of: JSONValue.self)
        let ending = Mutex<LinkTransportError?>(nil)
        let handler = self.handler
        let eventLog = self.eventLog
        let timing = self.timing
        let logger = self.logger
        var subscription: Task<Void, Never>?

        await withTaskGroup(of: Void.self) { group in
            // Inbound frames, until the connection ends.
            group.addTask {
                while true {
                    do {
                        let text = try await connection.receive()
                        lastHeard.withLock { $0 = .now }
                        guard let frame = try? JSONValue.parse(text), frame.objectValue != nil else {
                            try? await sender.send(LinkFrames.error(code: "invalid_request", message: "Frames are JSON objects with a type."))
                            continue
                        }
                        framesIn.yield(frame)
                    } catch {
                        ending.withLock { $0 = $0 ?? ((error as? LinkTransportError) ?? .closed(code: nil, reason: "\(error)")) }
                        framesIn.finish()
                        return
                    }
                }
            }
            // Keepalive: ping, and drop a connection that has gone quiet.
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: timing.pingInterval)
                    if Task.isCancelled { return }
                    if ContinuousClock.now - lastHeard.withLock({ $0 }) > timing.idleTimeout {
                        ending.withLock { $0 = $0 ?? .closed(code: nil, reason: "nothing heard from Volgenic for \(Int(timing.idleTimeout.seconds))s") }
                        connection.close(code: 1001, reason: "idle")
                        return
                    }
                    Task {
                        if (try? await connection.ping()) != nil { lastHeard.withLock { $0 = .now } }
                    }
                }
            }
            // Sign-in state changes.
            group.addTask {
                var last = hello
                while !Task.isCancelled {
                    try? await Task.sleep(for: timing.authPollInterval)
                    if Task.isCancelled { return }
                    let now = await self.currentAuth()
                    guard now != last else { continue }
                    last = now
                    try? await sender.send(LinkFrames.authState(now.state, account: now.account))
                }
            }

            for await frame in frames {
                switch frame["type"]?.stringValue {
                case "request":
                    group.addTask {
                        let reply = await GatewayLinkClient.answer(frame, handler: handler, logger: logger)
                        if let reply { try? await sender.send(reply) }
                    }
                case "subscribe":
                    subscription?.cancel()
                    guard let since = frame["since"]?.int64Value, since >= 0 else {
                        subscription = nil
                        try? await sender.send(LinkFrames.error(code: "invalid_request", message: "subscribe needs since, a non-negative integer."))
                        continue
                    }
                    logger.info("link: subscribed from seq \(since)")
                    subscription = Task { await GatewayLinkClient.stream(since: since, eventLog: eventLog, sender: sender) }
                default:
                    logger.debug("link: ignoring a frame of type \(frame["type"]?.stringValue ?? "?")")
                }
            }
            subscription?.cancel()
            group.cancelAll()
        }
        await subscription?.value
        return ending.withLock { $0 } ?? .closed(code: nil, reason: "connection ended")
    }

    struct AuthSnapshot: Equatable, Sendable {
        var state: String
        var account: AccountInfo?
    }

    private func currentAuth() async -> AuthSnapshot {
        let state = await telegram.authStateName()
        return AuthSnapshot(state: state, account: state == "ready" ? await telegram.account() : nil)
    }

    /// Runs one `request` frame; nil when the frame has no id to answer to.
    static func answer(_ frame: JSONValue, handler: any LinkRequestHandling, logger: Logger) async -> JSONValue? {
        guard let id = frame["id"]?.stringValue ?? frame["id"].flatMap({ $0.doubleValue != nil ? $0.serializedString() : nil }) else {
            return LinkFrames.error(code: "invalid_request", message: "A request needs an id.")
        }
        switch LinkFrames.request(frame) {
        case .failure(let error):
            logger.info("link: refused \(frame["method"]?.stringValue ?? "?") \(frame["path"]?.stringValue ?? "?"): \(error.code)")
            return LinkFrames.response(id: id, .error(error))
        case .success(let request):
            let response = await handler.perform(request, maxBodyBytes: LinkPolicy.maxBodyBytes)
            logger.debug("link: \(request.method) \(request.path) → \(response.status)")
            return LinkFrames.response(id: id, response)
        }
    }

    /// The event log from `since`: a `gap` first if `since` is below what is retained, then
    /// the backlog, then live events, until cancelled or the connection fails.
    static func stream(since: Int64, eventLog: EventLog, sender: FrameSender) async {
        let heads = await eventLog.subscribe()
        var cursor = since
        func drain() async throws {
            while !Task.isCancelled {
                let page: EventLog.Page
                do {
                    page = try await eventLog.page(since: cursor, limit: 500)
                } catch EventLog.PageError.historyPruned(let oldest) {
                    try await sender.send(LinkFrames.gap(oldestSeq: oldest))
                    cursor = oldest - 1
                    continue
                }
                for event in page.events {
                    if Task.isCancelled { return }
                    try await sender.send(LinkFrames.event(event))
                }
                cursor = max(cursor, page.nextSince)
                if !page.hasMore { return }
            }
        }
        do {
            try await drain()
            for await _ in heads {
                if Task.isCancelled { return }
                try await drain()
            }
        } catch {
            return
        }
    }
}

/// Writes frames one at a time, in the order they were handed over.
actor FrameSender {
    private let connection: any LinkConnection

    init(connection: any LinkConnection) {
        self.connection = connection
    }

    func send(_ frame: JSONValue) async throws {
        try await connection.send(frame.serializedString())
    }
}
