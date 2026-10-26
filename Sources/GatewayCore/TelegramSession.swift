import Foundation
import Logging
import TDLibClient

public struct AccountInfo: Sendable, Equatable {
    public var userId: Int64
    public var displayName: String
    public var username: String?
    public var phoneLast4: String?
    /// The whole number in international form (`+15551234567`). Only the link to Volgenic
    /// sends it (docs/link.md `hello`); the local API shows the last four digits.
    public var phoneNumber: String?

    public init(userId: Int64, displayName: String, username: String?, phoneLast4: String?, phoneNumber: String? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.username = username
        self.phoneLast4 = phoneLast4
        self.phoneNumber = phoneNumber
    }

    public var json: JSONValue {
        ["user_id": .id(userId), "display_name": .string(displayName), "username": .optional(username), "phone_last4": .optional(phoneLast4)]
    }
}

/// Details of the `wait_code` state: which channel the code went through and to which number.
public struct CodeInfo: Sendable, Equatable {
    /// `sms`, `call`, `telegram_message`, `flash_call`, `missed_call`, `fragment`, `firebase`, or `unknown`.
    public var type: String
    public var phoneNumber: String

    public init(type: String, phoneNumber: String) {
        self.type = type
        self.phoneNumber = phoneNumber
    }

    /// Decodes an `authenticationCodeInfo` object.
    public init(object: JSONObject) {
        phoneNumber = object.string("phone_number") ?? ""
        switch object.object("type")?.type {
        case "authenticationCodeTypeSms": type = "sms"
        case "authenticationCodeTypeCall": type = "call"
        case "authenticationCodeTypeTelegramMessage": type = "telegram_message"
        case "authenticationCodeTypeFlashCall": type = "flash_call"
        case "authenticationCodeTypeMissedCall": type = "missed_call"
        case "authenticationCodeTypeFragment": type = "fragment"
        case "authenticationCodeTypeFirebaseAndroid", "authenticationCodeTypeFirebaseIos": type = "firebase"
        default: type = "unknown"
        }
    }
}

/// What the API needs from the Telegram side: login state and the login steps
/// (docs/api.md "Admin: login"), connection state, the account, and a request handle for
/// history and media. `TelegramSession` is the real one; tests use a fake.
public protocol TelegramControl: Sendable {
    func authState() async -> AuthState?
    func connectionState() async -> ConnectionState
    /// The `tg://login?token=…` link while in `wait_qr_confirmation`.
    func qrLink() async -> String?
    /// Set while in `wait_code`.
    func codeInfo() async -> CodeInfo?
    func requestQr() async throws
    func setPhoneNumber(_ phone: String) async throws
    func checkCode(_ code: String) async throws
    func checkPassword(_ password: String) async throws
    func setEmailAddress(_ email: String) async throws
    func checkEmailCode(_ code: String) async throws
    func logOut() async throws
    func account() async -> AccountInfo?
    /// nil when TDLib is not running (no credentials configured).
    func requesting() async -> (any TDLibRequesting)?
}

extension TelegramControl {
    /// The `tdlib.auth_state` string.
    public func authStateName() async -> String {
        await authState()?.apiName ?? "unknown"
    }

    public func isReady() async -> Bool {
        await authState() == .ready
    }

    /// Throws `503 not_logged_in` / `503 telegram_unavailable` unless history and media can
    /// be served right now.
    public func requireLive() async throws -> any TDLibRequesting {
        guard let tdlib = await requesting(), await authState() == .ready else {
            throw APIError.notLoggedIn(authState: await authStateName())
        }
        let connection = await connectionState()
        guard connection == .ready || connection == .updating else {
            throw APIError.telegramUnavailable(connectionState: connection.rawValue)
        }
        return tdlib
    }
}

/// The daemon's TDLib client: owns the instance, answers `waitTdlibParameters`, sets
/// `online = false` on `ready`, tracks the connection state, and forwards every update to
/// the monitor through `updates`. After `logOut` TDLib closes; a fresh client is created so
/// the user can log in again without restarting the daemon.
public actor TelegramSession: ManagedTelegramSession {
    public nonisolated let updates: AsyncStream<JSONBox>
    private let forward: AsyncStream<JSONBox>.Continuation
    private let parameters: TDLibParameters
    private let logger: Logger
    private let makeClient: @Sendable () -> TDLibClient

    private var client: TDLibClient?
    private var pump: Task<Void, Never>?
    private var currentAuthState: AuthState?
    private var currentCodeInfo: CodeInfo?
    private var currentConnectionState: ConnectionState = .connecting
    private var cachedAccount: AccountInfo?
    private var shuttingDown = false

    public init(parameters: TDLibParameters, logger: Logger = Logger(label: "telegram"), makeClient: @escaping @Sendable () -> TDLibClient = { TDLibClient() }) {
        self.parameters = parameters
        self.logger = logger
        self.makeClient = makeClient
        (updates, forward) = AsyncStream.makeStream(of: JSONBox.self, bufferingPolicy: .unbounded)
    }

    /// Creates the client and starts pumping its updates. TDLib does nothing until it receives
    /// a request, so a `getOption` nudges the first authorization state out.
    public func start() async {
        guard client == nil, !shuttingDown else { return }
        let client = makeClient()
        self.client = client
        currentAuthState = nil
        cachedAccount = nil
        pump = Task { [weak self] in
            for await update in client.updates {
                await self?.handle(JSONBox(update))
            }
            await self?.clientEnded(client)
        }
        _ = try? await client.send("getOption", ["name": "version"])
    }

    private func clientEnded(_ ended: TDLibClient) async {
        guard client === ended else { return }
        client = nil
        currentAuthState = .closed
        cachedAccount = nil
        if !shuttingDown {
            logger.info("TDLib closed; starting a fresh client")
            await start()
        }
    }

    private func handle(_ box: JSONBox) async {
        let update = box.object
        switch update.type {
        case "updateAuthorizationState":
            guard let stateObject = update.object("authorization_state") else { break }
            let state = AuthState(object: stateObject)
            currentAuthState = state
            currentCodeInfo = stateObject.object("code_info").map(CodeInfo.init(object:))
            switch state {
            case .waitTdlibParameters:
                _ = try? await client?.send(parameters.request)
            case .ready:
                _ = try? await client?.send("setOption", ["name": "online", "value": ["@type": "optionValueBoolean", "value": false]])
                cachedAccount = await fetchAccount()
            default:
                cachedAccount = nil
            }
        case "updateConnectionState":
            if let state = update.object("state") { currentConnectionState = ConnectionState(object: state) }
        default:
            break
        }
        forward.yield(box)
    }

    private func fetchAccount() async -> AccountInfo? {
        guard let client, let me = try? await client.send("getMe") else { return nil }
        let name = [me.string("first_name"), me.string("last_name")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let phone = me.string("phone_number") ?? ""
        return AccountInfo(
            userId: me.int64("id") ?? 0, displayName: name, username: Translator.username(me.object("usernames")),
            phoneLast4: phone.isEmpty ? nil : String(phone.suffix(4)),
            phoneNumber: phone.isEmpty ? nil : (phone.hasPrefix("+") ? phone : "+" + phone)
        )
    }

    /// Sends `close` and waits for TDLib to flush (docs/development.md: skipping this risks a
    /// slow recovery on next start).
    /// Returns whether TDLib confirmed it closed (true when there was no client).
    @discardableResult
    public func shutdown() async -> Bool {
        shuttingDown = true
        forward.finish()
        var closed = true
        if let client {
            await client.close()
            closed = await client.authState == .closed
        }
        pump?.cancel()
        client = nil
        currentAuthState = .closed
        return closed
    }

    // MARK: TelegramControl

    public func authState() -> AuthState? { currentAuthState }
    public func connectionState() -> ConnectionState { currentConnectionState }
    public func account() -> AccountInfo? { cachedAccount }
    public func requesting() -> (any TDLibRequesting)? { client }

    public func codeInfo() -> CodeInfo? { currentCodeInfo }

    public func setEmailAddress(_ email: String) async throws {
        try await authRequest("setAuthenticationEmailAddress", ["email_address": email], field: "email_address")
    }

    public func checkEmailCode(_ code: String) async throws {
        try await authRequest("checkAuthenticationEmailCode", ["code": ["@type": "emailAddressAuthenticationCode", "code": code]], field: "code", wrongReason: "wrong_code")
    }

    public func qrLink() -> String? {
        if case .waitOtherDeviceConfirmation(let link) = currentAuthState { return link }
        return nil
    }

    public func requestQr() async throws {
        try await authRequest("requestQrCodeAuthentication", ["other_user_ids": [Int64]()], field: "qr")
    }

    public func setPhoneNumber(_ phone: String) async throws {
        try await authRequest("setAuthenticationPhoneNumber", ["phone_number": phone], field: "phone_number")
    }

    public func checkCode(_ code: String) async throws {
        try await authRequest("checkAuthenticationCode", ["code": code], field: "code", wrongReason: "wrong_code")
    }

    public func checkPassword(_ password: String) async throws {
        var hint = ""
        if case .waitPassword(let h) = currentAuthState { hint = h }
        do {
            try await authRequest("checkAuthenticationPassword", ["password": password], field: "password", wrongReason: "wrong_password")
        } catch var error as APIError where error.code == "invalid_request" {
            error.details["password_hint"] = .string(hint)
            throw error
        }
    }

    public func logOut() async throws {
        try await authRequest("logOut", [:], field: "logout")
    }

    private func authRequest(_ type: String, _ fields: JSONObject, field: String, wrongReason: String? = nil) async throws {
        guard let client else { throw APIError.notLoggedIn(authState: "unknown") }
        var request = fields
        request["@type"] = type
        let box = JSONBox(request)
        do {
            _ = try await client.request(box)
        } catch let error as TDLibError {
            throw APIError.invalidRequest(field, wrongReason ?? error.message)
        }
    }
}

extension TelegramSession {
    /// Requests go to the current client; `503 not_logged_in` when there is none.
    public func request(_ request: JSONBox) async throws -> JSONBox {
        guard let client else { throw APIError.notLoggedIn(authState: currentAuthState?.apiName ?? "unknown") }
        return try await client.request(request)
    }
}

/// Stands in for TDLib when no `api_id` / `api_hash` is configured: the daemon serves the
/// store-backed API and reports `auth_state: unknown`. Every TDLib request fails with
/// `503 not_logged_in`.
public struct NoTelegram: TelegramControl, TDLibRequesting {
    public init() {}
    public func authState() async -> AuthState? { nil }
    public func connectionState() async -> ConnectionState { .waitingForNetwork }
    public func qrLink() async -> String? { nil }
    public func codeInfo() async -> CodeInfo? { nil }
    public func setEmailAddress(_ email: String) async throws { throw NoTelegram.error }
    public func checkEmailCode(_ code: String) async throws { throw NoTelegram.error }
    public func requestQr() async throws { throw NoTelegram.error }
    public func setPhoneNumber(_ phone: String) async throws { throw NoTelegram.error }
    public func checkCode(_ code: String) async throws { throw NoTelegram.error }
    public func checkPassword(_ password: String) async throws { throw NoTelegram.error }
    public func logOut() async throws { throw NoTelegram.error }
    public func account() async -> AccountInfo? { nil }
    public func requesting() async -> (any TDLibRequesting)? { nil }
    public func request(_ request: JSONBox) async throws -> JSONBox { throw NoTelegram.error }

    static var error: APIError {
        var error = APIError.notLoggedIn(authState: "unknown")
        error.message = "No api_id / api_hash configured; add them to config.json and restart the daemon."
        return error
    }
}
