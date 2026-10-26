import Foundation
import Synchronization

/// Opens the WebSocket to Volgenic. `URLSessionLinkTransport` in the gateway; tests may
/// substitute their own.
public protocol LinkTransport: Sendable {
    /// Connects to `url` with `Authorization: Bearer <token>` and returns once the WebSocket
    /// is open. Throws `LinkTransportError.unauthorized` when the server answers the upgrade
    /// with 401.
    func connect(url: URL, token: String) async throws -> any LinkConnection
}

/// An open WebSocket.
public protocol LinkConnection: Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Throws `LinkTransportError.closed` when the connection ends.
    func receive() async throws -> String
    /// Sends a ping and returns when the pong arrives.
    func ping() async throws
    func close(code: Int, reason: String)
}

public enum LinkTransportError: Error, Equatable, CustomStringConvertible {
    /// The server refused the upgrade with HTTP 401: the token is unknown or revoked.
    case unauthorized
    /// The upgrade failed for another reason (no connection, TLS, another HTTP status).
    case connectFailed(String)
    /// The open connection ended; `code` is the WebSocket close code when there was one.
    case closed(code: Int?, reason: String)

    public var description: String {
        switch self {
        case .unauthorized: "Volgenic refused the link token (HTTP 401)"
        case .connectFailed(let reason): "could not connect: \(reason)"
        case .closed(let code, let reason): "connection closed" + (code.map { " with code \($0)" } ?? "") + (reason.isEmpty ? "" : ": \(reason)")
        }
    }
}

/// The WebSocket client the gateway uses: Foundation's `URLSessionWebSocketTask`. It speaks
/// TLS with the system's trust store and proxy settings, sends the `Authorization` header
/// on the upgrade, answers the server's pings by itself, and reports the HTTP status of a
/// refused upgrade and the close code of a closed connection. One `URLSession` per
/// connection, invalidated when it closes.
public struct URLSessionLinkTransport: LinkTransport {
    /// Inbound frames larger than this fail the connection. Requests are small; 16 MiB is
    /// generous.
    public var maximumMessageSize = 16 * 1024 * 1024
    public var connectTimeout: TimeInterval = 30

    public init() {}

    public func connect(url: URL, token: String) async throws -> any LinkConnection {
        let delegate = SocketDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = connectTimeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = connectTimeout
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    delegate.onOpen(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            session.invalidateAndCancel()
            if status == 401 { throw LinkTransportError.unauthorized }
            if let status { throw LinkTransportError.connectFailed("the server answered HTTP \(status)") }
            throw LinkTransportError.connectFailed((error as NSError).localizedDescription)
        }
        return URLSessionLinkConnection(task: task, session: session, delegate: delegate)
    }
}

/// Learns when the upgrade succeeded or failed, and the close code the server sent.
final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct State {
        var opening: CheckedContinuation<Void, any Error>?
        var opened = false
        var closeCode: Int?
        var closeReason = ""
    }

    private let state = Mutex(State())

    func onOpen(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.opening = continuation }
    }

    var closeCode: Int? { state.withLock { $0.closeCode } }
    var closeReason: String { state.withLock { $0.closeReason } }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            state.opened = true
            defer { state.opening = nil }
            return state.opening
        }
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        state.withLock {
            $0.closeCode = closeCode.rawValue
            $0.closeReason = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            defer { state.opening = nil }
            return state.opening
        }
        continuation?.resume(throwing: error ?? LinkTransportError.connectFailed("the connection ended before it opened"))
    }
}

final class URLSessionLinkConnection: LinkConnection {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: SocketDelegate

    init(task: URLSessionWebSocketTask, session: URLSession, delegate: SocketDelegate) {
        self.task = task
        self.session = session
        self.delegate = delegate
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw closedError(error)
        }
    }

    func receive() async throws -> String {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw closedError(error)
            }
            switch message {
            case .string(let text): return text
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { return text }
            @unknown default: continue
            }
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close(code: Int, reason: String) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .goingAway
        task.cancel(with: closeCode, reason: Data(reason.utf8))
        session.finishTasksAndInvalidate()
    }

    /// The close code the server sent, from the delegate or the task.
    private func closedError(_ error: any Error) -> LinkTransportError {
        let code = delegate.closeCode ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue)
        let reason = delegate.closeReason.isEmpty ? (error as NSError).localizedDescription : delegate.closeReason
        return .closed(code: code, reason: reason)
    }
}
