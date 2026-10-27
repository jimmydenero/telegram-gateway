import Foundation

// The gateway's API objects, as documented in docs/api.md. Field names follow the JSON
// (snake_case) through `APIJSON.decoder`'s key strategy. Every enum that mirrors a string
// the daemon may extend decodes unknown values as `.unknown` rather than failing, because
// docs/api.md says unknown values and fields must be tolerated.

// MARK: - JSON plumbing

/// The one decoder/encoder pair used for every API call and every test fixture.
enum APIJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = RFC3339.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an RFC 3339 timestamp: \(string)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RFC3339.string(from: date))
        }
        return encoder
    }()
}

/// RFC 3339 timestamps in UTC, with or without fractional seconds (docs/api.md "Timestamps").
enum RFC3339 {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }

    static func string(from date: Date) -> String {
        date.formatted(fractional)
    }
}

/// A JSON value of any shape, for the places the API leaves open-ended (`error.details`).
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

/// Decodes a string enum, mapping anything the app does not know to `unknown`.
protocol LenientStringEnum: RawRepresentable, Decodable, Sendable where RawValue == String {
    static var unknown: Self { get }
}

extension LenientStringEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

// MARK: - Health and status

/// `tdlib.auth_state` in `/v1/health`: where the Telegram login stands.
enum AuthState: String, LenientStringEnum, Hashable {
    case waitPhoneNumber = "wait_phone_number"
    case waitQRConfirmation = "wait_qr_confirmation"
    case waitCode = "wait_code"
    case waitPassword = "wait_password"
    /// Telegram asked for a login e-mail (accounts that opted in to e-mail codes). Not in
    /// docs/api.md's list yet; the app handles them because TDLib has these states.
    case waitEmailAddress = "wait_email_address"
    case waitEmailCode = "wait_email_code"
    /// The phone number has no Telegram account. The gateway never registers one.
    case waitRegistration = "wait_registration"
    case ready
    case loggingOut = "logging_out"
    case closed
    case unknown

    var isLoggedIn: Bool { self == .ready }

    /// Whether the gateway's Telegram side is up at all. `unknown` is what a gateway reports
    /// while it has no Telegram key (or has not started its Telegram session yet); `closed` is
    /// a session that was shut down.
    var isTelegramRunning: Bool { self != .unknown && self != .closed }

    var label: String {
        switch self {
        case .waitPhoneNumber: "Not logged in"
        case .waitQRConfirmation: "Waiting for QR scan"
        case .waitCode: "Waiting for login code"
        case .waitPassword: "Waiting for 2FA password"
        case .waitEmailAddress: "Waiting for e-mail address"
        case .waitEmailCode: "Waiting for e-mail code"
        case .waitRegistration: "No account for this number"
        case .ready: "Logged in"
        case .loggingOut: "Logging out"
        case .closed: "Closed"
        case .unknown: "Unknown"
        }
    }
}

/// `tdlib.connection_state`: whether TDLib is talking to Telegram right now.
enum ConnectionState: String, LenientStringEnum, Hashable {
    case waitingForNetwork = "waiting_for_network"
    case connecting
    case updating
    case ready
    case unknown

    var label: String {
        switch self {
        case .waitingForNetwork: "Waiting for network"
        case .connecting: "Connecting"
        case .updating: "Catching up"
        case .ready: "Connected"
        case .unknown: "Unknown"
        }
    }
}

struct TDLibState: Decodable, Hashable, Sendable {
    var authState: AuthState
    var connectionState: ConnectionState
}

/// `GET /v1/health`.
struct Health: Decodable, Hashable, Sendable {
    var status: String
    var version: String
    var startedAt: Date
    var time: Date
    var tdlib: TDLibState
    var headSeq: Int
}

/// The logged-in Telegram account, from `GET /v1/admin/status`.
struct Account: Decodable, Hashable, Sendable {
    var userId: String
    var displayName: String
    var username: String?
    var phoneLast4: String?
}

struct WebhookCounts: Decodable, Hashable, Sendable {
    var active: Int
    var retrying: Int
    var paused: Int
}

struct BackfillStatus: Decodable, Hashable, Sendable {
    var inProgress: Bool
    var chatsPending: Int
}

/// `GET /v1/admin/status`: health plus everything the Status screen shows.
struct AdminStatus: Decodable, Hashable, Sendable {
    var status: String
    var version: String
    var startedAt: Date
    var time: Date
    var tdlib: TDLibState
    var headSeq: Int
    var account: Account?
    var monitoredChatCount: Int
    var grantCount: Int
    var webhooks: WebhookCounts
    var eventsLastHour: Int
    /// Since local midnight. Optional because it arrived after the first api.md.
    var eventsToday: Int?
    var oldestSeq: Int?
    var mediaCacheBytes: Int
    var backfill: BackfillStatus
}

/// What `POST /v1/admin/reload` did to the gateway's Telegram session.
enum TelegramReload: String, LenientStringEnum, Hashable {
    /// It was off (no key) and is now started.
    case started
    /// It was running and was recreated with the new configuration.
    case restarted
    /// Nothing relevant changed.
    case unchanged
    /// The configuration the gateway read has no Telegram key, so Telegram stays off.
    case disabled
    case unknown
}

/// `POST /v1/admin/reload`: the gateway re-read `config.json`.
struct ReloadResult: Decodable, Hashable, Sendable {
    var telegram: TelegramReload
    /// Settings that only take effect after a full restart of the gateway (for example `port`).
    var restartRequired: [String]

    init(telegram: TelegramReload, restartRequired: [String] = []) {
        self.telegram = telegram
        self.restartRequired = restartRequired
    }

    private enum CodingKeys: String, CodingKey { case telegram, restartRequired }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        telegram = try container.decodeIfPresent(TelegramReload.self, forKey: .telegram) ?? .unknown
        restartRequired = try container.decodeIfPresent([String].self, forKey: .restartRequired) ?? []
    }
}

// MARK: - Login

/// `GET /v1/admin/auth` (and what the `POST /v1/admin/auth/*` calls answer with).
struct AuthInfo: Decodable, Hashable, Sendable {
    var authState: AuthState
    /// `tg://login?token=…`, only in `wait_qr_confirmation`. Changes every ~30s.
    var qrLink: String?
    /// The phone number a code was sent to, in `wait_code`.
    var phoneHint: String?
    /// The two-factor password hint, in `wait_password`. docs/api.md only returns it on a
    /// wrong password; the app shows it whenever the daemon includes it.
    var passwordHint: String?
    /// In `wait_code`: where Telegram sent the code (`sms`, `telegram_message`, `call`…).
    var codeType: String?

    init(authState: AuthState, qrLink: String? = nil, phoneHint: String? = nil, passwordHint: String? = nil, codeType: String? = nil) {
        self.authState = authState
        self.qrLink = qrLink
        self.phoneHint = phoneHint
        self.passwordHint = passwordHint
        self.codeType = codeType
    }

    private enum CodingKeys: String, CodingKey {
        case authState, qrLink, phoneHint, passwordHint, codeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authState = try container.decode(AuthState.self, forKey: .authState)
        qrLink = try container.decodeIfPresent(String.self, forKey: .qrLink)
        phoneHint = try container.decodeIfPresent(String.self, forKey: .phoneHint)
        passwordHint = try container.decodeIfPresent(String.self, forKey: .passwordHint)
        codeType = try container.decodeIfPresent(String.self, forKey: .codeType)
    }
}

// MARK: - Chats

enum ChatType: String, LenientStringEnum, Hashable {
    case `private`
    case basicGroup = "basic_group"
    case supergroup
    case channel
    case unknown

    /// SF Symbol for the chat type.
    var symbolName: String {
        switch self {
        case .private: "person"
        case .basicGroup, .supergroup: "person.2"
        case .channel: "megaphone"
        case .unknown: "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .private: "Private"
        case .basicGroup: "Group"
        case .supergroup: "Supergroup"
        case .channel: "Channel"
        case .unknown: "Unknown"
        }
    }
}

/// A media reference (docs/events.md "media object"); the app only uses it for chat photos.
struct MediaReference: Decodable, Hashable, Sendable {
    var mediaId: String
    var width: Int?
    var height: Int?
}

/// The chat object (docs/api.md "Chats").
struct Chat: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var type: ChatType
    var title: String
    var username: String?
    var memberCount: Int?
    var isMonitored: Bool
    var photo: MediaReference?
}

/// `GET /v1/admin/chats?all=true`: one page of the account's chat list.
struct ChatPage: Decodable, Hashable, Sendable {
    var chats: [Chat]
    var hasMore: Bool
    var nextCursor: String?
}

/// `GET /v1/admin/folders`: a Telegram chat folder (a named tab in the Telegram apps).
struct Folder: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var chatIds: [String]
    var isMonitored: Bool
}

struct FolderList: Decodable, Sendable {
    var folders: [Folder]
}

/// `GET`/`PUT /v1/admin/monitored-chats`.
struct MonitoredChats: Codable, Hashable, Sendable {
    var chatIds: [String]
    var folderIds: [String]
    /// The union of the explicit chats and every chat in the monitored folders.
    var effectiveChatIds: [String]
}

/// Body of `PUT /v1/admin/monitored-chats`.
struct MonitoredChatsUpdate: Encodable, Sendable {
    var chatIds: [String]
    var folderIds: [String]
}

// MARK: - Access requests

/// `requested_chats`: a list of chat ids or the string `"any"`.
enum RequestedChats: Decodable, Hashable, Sendable {
    case any
    case list([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard string == "any" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "requested_chats must be \"any\" or a list")
            }
            self = .any
        } else {
            self = .list(try container.decode([String].self))
        }
    }

    var chatIds: [String] {
        if case .list(let ids) = self { return ids }
        return []
    }
}

struct RequestedChatStatus: Decodable, Hashable, Sendable {
    var chatId: String
    var title: String
    var isMonitored: Bool
}

enum AccessRequestStatus: String, LenientStringEnum, Hashable {
    case pending, approved, denied, expired, unknown
}

/// One entry of `GET /v1/admin/access-requests`.
struct AccessRequest: Decodable, Hashable, Identifiable, Sendable {
    var requestId: String
    var status: AccessRequestStatus
    var name: String
    var description: String
    var scopes: [String]
    var requestedChats: RequestedChats
    /// `null` when `requested_chats` was `"any"`.
    var requestedChatsStatus: [RequestedChatStatus]?
    var webhookUrl: String?
    var createdAt: Date
    var expiresAt: Date

    var id: String { requestId }
}

struct AccessRequestList: Decodable, Sendable {
    var accessRequests: [AccessRequest]
}

/// Body of `POST /v1/admin/access-requests/{id}/approve`: exactly one of the two.
enum GrantChatSelection: Hashable, Sendable {
    case chats([String])
    case folder(String)
}

struct ApproveRequest: Encodable, Sendable {
    var chatIds: [String]?
    var folderId: String?
    var scopes: [String]?

    init(selection: GrantChatSelection, scopes: [String]?) {
        switch selection {
        case .chats(let ids): chatIds = ids
        case .folder(let id): folderId = id
        }
        self.scopes = scopes
    }
}

struct DenyRequest: Encodable, Sendable {
    var reason: String?
}

// MARK: - Grants

struct AppInfo: Decodable, Hashable, Sendable {
    var name: String
    var description: String
}

/// `chats` in the grant object: a fixed list or a folder.
struct GrantChats: Decodable, Hashable, Sendable {
    var mode: String
    var chatIds: [String]?
    var folderId: String?
    var folderTitle: String?

    var isFolder: Bool { mode == "folder" }
}

enum WebhookLifecycle: String, LenientStringEnum, Hashable {
    case active, retrying, paused, unknown
}

/// The `webhook` part of a grant object.
struct WebhookStatus: Decodable, Hashable, Sendable {
    var url: String
    var state: WebhookLifecycle
    var cursorSeq: Int
    var pendingEvents: Int
    var lastDeliveryAt: Date?
    var lastError: String?
    var pausedAt: Date?
}

/// The grant object (docs/api.md "Grants").
struct Grant: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var app: AppInfo
    var scopes: [String]
    var chats: GrantChats
    var effectiveChatIds: [String]
    var webhook: WebhookStatus?
    var createdAt: Date
    var lastSeenAt: Date?
    var revokedAt: Date?
}

struct GrantList: Decodable, Sendable {
    var grants: [Grant]
}

struct GrantStats: Decodable, Hashable, Sendable {
    var eventsDelivered24h: Int
    var websocketConnections: Int

    // The decoder's snake-case strategy rewrites the JSON key `events_delivered_24h` to
    // `eventsDelivered24H` (it capitalises every component after the first) before matching.
    private enum CodingKeys: String, CodingKey {
        case eventsDelivered24h = "eventsDelivered24H"
        case websocketConnections
    }
}

/// `GET /v1/admin/grants/{id}`.
struct GrantDetail: Decodable, Hashable, Sendable {
    var grant: Grant
    var stats: GrantStats
}

enum DeliveryStatus: String, LenientStringEnum, Hashable {
    case succeeded, failed, inFlight = "in_flight", unknown
}

/// One entry of `GET /v1/admin/grants/{id}/deliveries`.
struct Delivery: Decodable, Hashable, Identifiable, Sendable {
    var deliveryId: String
    var firstSeq: Int
    var lastSeq: Int
    var eventCount: Int
    var attempt: Int
    var status: DeliveryStatus
    var httpStatus: Int?
    var error: String?
    var sentAt: Date
    var completedAt: Date?

    var id: String { deliveryId }
}

struct DeliveryList: Decodable, Sendable {
    var deliveries: [Delivery]
    var hasMore: Bool
}

// MARK: - Scopes

/// The scopes in docs/grants.md, with the one-line meaning shown when approving.
enum Scope {
    static let all = ["messages:read", "history:read", "media:read", "chats:read", "messages:send", "messages:mark_read", "chats:manage"]

    static func explanation(_ scope: String) -> String {
        switch scope {
        case "messages:read": "Receive new messages as they arrive"
        case "history:read": "Read past messages from Telegram"
        case "media:read": "Download photos, videos and files"
        case "chats:read": "List the granted chats and learn when coverage changes"
        case "messages:send": "Send messages and files, forward, edit and delete what you sent, react and vote as you"
        case "messages:mark_read": "Mark messages read as you: senders see read receipts"
        case "chats:manage": "Pin, archive and mute the granted chats, and find chats by username or phone number"
        default: "Unknown scope"
        }
    }
}

// MARK: - Errors

/// The `error` object every non-2xx response carries.
struct APIError: Error, Decodable, Hashable, Sendable {
    var code: String
    var message: String
    var details: [String: JSONValue]?

    struct Envelope: Decodable {
        var error: APIError
        /// `POST /v1/admin/auth/password` puts `password_hint` next to `error` on a wrong password.
        var passwordHint: String?
    }

    var reason: String? { details?["reason"]?.stringValue }
}

/// What an `APIClient` call can fail with, in the terms the screens need.
enum APIClientError: Error, LocalizedError, Sendable {
    /// No TCP connection: the daemon is not running (or listens on another port).
    case unreachable(String)
    /// No admin token is stored, so the request could not be authenticated.
    case noToken
    /// The daemon answered with an error body.
    case api(APIError, status: Int, passwordHint: String?)
    /// Non-2xx without a parseable error body.
    case unexpectedStatus(Int)
    /// The body did not match the model.
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Gateway not reachable (\(detail))"
        case .noToken: "No admin token stored (secrets.json)"
        case .api(let error, _, _): error.message
        case .unexpectedStatus(let status): "Unexpected HTTP status \(status)"
        case .decoding(let detail): "Could not read the gateway's response: \(detail)"
        }
    }

    var apiCode: String? {
        if case .api(let error, _, _) = self { return error.code }
        return nil
    }

    var apiError: APIError? {
        if case .api(let error, _, _) = self { return error }
        return nil
    }

    var httpStatus: Int? {
        switch self {
        case .api(_, let status, _): status
        case .unexpectedStatus(let status): status
        default: nil
        }
    }

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// The gateway does not have this endpoint (an older gateway): HTTP 404.
    var isMissingEndpoint: Bool {
        switch self {
        case .api(_, let status, _): status == 404
        case .unexpectedStatus(let status): status == 404
        default: false
        }
    }
}
