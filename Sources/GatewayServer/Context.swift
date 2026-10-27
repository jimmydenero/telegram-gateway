import Foundation
import GatewayCore
import GatewayLink
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import NIOCore

/// Everything the routes need, built by the daemon (real) or a test (fakes).
extension Dependencies {
    /// A cached chat with its read state and position as TDLib reports them now. The store
    /// holds the state of monitored chats; this also covers granted chats no longer monitored.
    func live(_ chat: ChatInfo) async -> ChatInfo {
        var chat = chat
        if let state = await translator.state(chat.id) { chat.state = state }
        return chat
    }
}

public struct Dependencies: Sendable {
    public var store: Store
    public var eventLog: EventLog
    public var grants: Grants
    public var accessRequests: AccessRequests
    public var monitor: Monitor
    public var translator: Translator
    public var mediaCache: MediaCache
    /// Sends messages (`POST /v1/chats/{chat_id}/messages`). It must see every TDLib update
    /// through `observe` to learn whether a message was sent.
    public var sender: MessageSender
    public var dispatcher: WebhookDispatcher?
    public var telegram: any TelegramControl
    /// Re-reads config.json (`POST /v1/admin/reload`); nil where reloading is not available.
    public var reloader: ConfigReloader?
    /// The links to Volgenic (docs/link.md); nil where the gateway runs none.
    public var links: LinkManager?
    public var rateLimiter: RateLimiter
    public var clock: any GatewayClock
    public var config: Config
    public var shutdown: ShutdownSignal
    public var startedAt: Date
    public var version: String
    public var logger: Logger

    public init(
        store: Store, eventLog: EventLog, grants: Grants, accessRequests: AccessRequests, monitor: Monitor,
        translator: Translator, mediaCache: MediaCache, sender: MessageSender? = nil, uploadDirectory: URL? = nil, dispatcher: WebhookDispatcher?, telegram: any TelegramControl,
        reloader: ConfigReloader? = nil, links: LinkManager? = nil, rateLimiter: RateLimiter, clock: any GatewayClock, config: Config, shutdown: ShutdownSignal = ShutdownSignal(),
        startedAt: Date, version: String = "0.1.0", logger: Logger = Logger(label: "server")
    ) {
        self.store = store
        self.eventLog = eventLog
        self.grants = grants
        self.accessRequests = accessRequests
        self.monitor = monitor
        self.translator = translator
        self.mediaCache = mediaCache
        self.sender = sender ?? MessageSender(grants: grants, translator: translator, telegram: telegram, rateLimiter: rateLimiter, clock: clock, uploadDirectory: uploadDirectory)
        self.dispatcher = dispatcher
        self.telegram = telegram
        self.reloader = reloader
        self.links = links
        self.rateLimiter = rateLimiter
        self.clock = clock
        self.config = config
        self.shutdown = shutdown
        self.startedAt = startedAt
        self.version = version
        self.logger = logger
    }
}

/// Tells open WebSockets the daemon is going away (close code 1001) before the server stops.
public actor ShutdownSignal {
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    public private(set) var triggered = false

    public init() {}

    public func subscribe() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        if triggered { continuation.yield() }
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.remove(id) } }
        return stream
    }

    public func trigger() {
        triggered = true
        for (_, continuation) in subscribers { continuation.yield() }
    }

    private func remove(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

/// Per-request state: the authenticated principal, the request id, rate-limit numbers for
/// the response headers. Request bodies are capped at 64 KiB (docs/api.md `413`).
public struct GatewayRequestContext: RequestContext, WebSocketRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let webSocket: WebSocketHandlerReference<Self>
    public var principal: Principal?
    public var requestId: String
    public var rateLimit: (limit: Int, remaining: Int)?
    /// True for a request that arrived over a link to Volgenic (`InProcessAPI`).
    public internal(set) var viaLink = false

    public init(source: Source) {
        coreContext = .init(source: source)
        webSocket = .init()
        requestId = Identifiers.requestTraceId()
    }

    /// A context for a request that arrives over a link to Volgenic rather than a socket
    /// (`InProcessAPI`).
    init(linkLogger: Logger) {
        coreContext = .init(source: LinkRequestSource(logger: linkLogger))
        webSocket = .init()
        requestId = Identifiers.requestTraceId()
        viaLink = true
    }

    public var maxUploadSize: Int { 64 * 1024 }

    /// The principal, or `missing_token` when the auth middleware did not run.
    public func requirePrincipal() throws -> Principal {
        guard let principal else { throw APIError.missingToken }
        return principal
    }
}

struct LinkRequestSource: RequestContextSource {
    let logger: Logger
}

// MARK: Header names

extension HTTPField.Name {
    public static let requestId = HTTPField.Name("X-TGW-Request-Id")!
    public static let rateLimitLimit = HTTPField.Name("X-RateLimit-Limit")!
    public static let rateLimitRemaining = HTTPField.Name("X-RateLimit-Remaining")!
    public static let cached = HTTPField.Name("X-TGW-Cached")!
}

// MARK: Responses

/// A JSON response with the documented content type.
func json(_ value: JSONValue, status: HTTPResponse.Status = .ok, headers: [(HTTPField.Name, String)] = []) -> Response {
    var fields = HTTPFields()
    fields[.contentType] = "application/json; charset=utf-8"
    for (name, value) in headers { fields[name] = value }
    let data = value.serialized()
    return Response(status: status, headers: fields, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func noContent() -> Response {
    Response(status: .noContent)
}

// MARK: Request parsing

/// Query-string access with the contract's parsing rules.
struct Query {
    let parameters: FlatDictionary<Substring, Substring>

    init(_ request: Request) {
        parameters = request.uri.queryParameters
    }

    func string(_ key: String) -> String? {
        parameters[key[...]].map(String.init)
    }

    func strings(_ key: String) -> [String] {
        parameters[values: key[...]].map(String.init)
    }

    func bool(_ key: String) -> Bool {
        ["true", "1", "yes"].contains(string(key)?.lowercased() ?? "")
    }

    func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = string(key) else { return defaultValue }
        guard let value = Int(raw), range.contains(value) else {
            throw APIError.invalidRequest(key, "must be an integer in \(range.lowerBound)–\(range.upperBound)")
        }
        return value
    }

    func int64(_ key: String) throws -> Int64? {
        guard let raw = string(key) else { return nil }
        guard let value = Int64(raw), value >= 0 else { throw APIError.invalidRequest(key, "must be a non-negative integer") }
        return value
    }

    /// `chat_id=…` repeated, as ids.
    func chatIds() throws -> Set<Int64>? {
        let raw = strings("chat_id")
        guard !raw.isEmpty else { return nil }
        return Set(try raw.map { try parseChatId($0, field: "chat_id") })
    }

    /// `types=a,b`.
    func eventTypes() throws -> Set<EventType>? {
        guard let raw = string("types"), !raw.isEmpty else { return nil }
        return Set(try raw.split(separator: ",").map { part in
            guard let type = EventType(rawValue: String(part).trimmingCharacters(in: .whitespaces)) else {
                throw APIError.invalidRequest("types", "unknown event type \(part)")
            }
            return type
        })
    }
}

func parseChatId(_ raw: String, field: String) throws -> Int64 {
    guard let id = Int64(raw) else { throw APIError.invalidRequest(field, "must be a chat id string") }
    return id
}

/// Reads and parses the JSON body (object required). Over 64 KiB → `413 payload_too_large`.
func jsonBody(_ request: Request, _ context: GatewayRequestContext, limit: Int? = nil) async throws -> JSONObjectValue {
    var request = request
    let buffer: ByteBuffer
    do {
        buffer = try await request.collectBody(upTo: limit ?? context.maxUploadSize)
    } catch is NIOTooManyBytesError {
        throw APIError.payloadTooLarge
    } catch let error as HTTPError where error.status == .contentTooLarge {
        throw APIError.payloadTooLarge
    }
    if buffer.readableBytes == 0 { return [:] }
    let value: JSONValue
    do {
        value = try JSONValue.parse(Data(buffer.readableBytesView))
    } catch {
        throw APIError.invalidRequest("body", "must be valid JSON")
    }
    guard let object = value.objectValue else { throw APIError.invalidRequest("body", "must be a JSON object") }
    return object
}

extension JSONObjectValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue else { throw APIError.invalidRequest(key, "must be a string") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = self[key], value != .null else { return nil }
        guard let string = value.stringValue else { throw APIError.invalidRequest(key, "must be a string") }
        return string
    }

    func scopes(_ key: String, required: Bool) throws -> [Scope]? {
        guard let value = self[key], value != .null else {
            if required { throw APIError.invalidRequest(key, "must be a non-empty array of scope names") }
            return nil
        }
        guard let array = value.arrayValue else { throw APIError.invalidRequest(key, "must be an array of scope names") }
        return try array.map { item in
            guard let raw = item.stringValue, let scope = Scope(rawValue: raw) else {
                throw APIError.invalidRequest(key, "unknown scope \(item.stringValue ?? item.serializedString())")
            }
            return scope
        }
    }

    func ids(_ key: String) throws -> [Int64]? {
        guard let value = self[key], value != .null else { return nil }
        guard let array = value.arrayValue else { throw APIError.invalidRequest(key, "must be an array of id strings") }
        return try array.map { item in
            guard let raw = item.stringValue ?? item.int64Value.map(String.init) else {
                throw APIError.invalidRequest(key, "ids must be strings")
            }
            return try parseChatId(raw, field: key)
        }
    }
}
