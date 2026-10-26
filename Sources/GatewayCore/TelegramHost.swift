import Foundation
import Logging
import TDLibClient

/// The application's identity with Telegram as configured (`api_id`, `api_hash`).
public struct TelegramCredentials: Sendable, Equatable {
    public var apiId: Int32
    public var apiHash: String

    public init(apiId: Int32, apiHash: String) {
        self.apiId = apiId
        self.apiHash = apiHash
    }

    /// nil unless the configuration has both values.
    public init?(config: Config) {
        guard let apiId = config.apiId, let apiHash = config.apiHash, !apiHash.isEmpty else { return nil }
        self.init(apiId: apiId, apiHash: apiHash)
    }
}

/// A Telegram session the host can start and stop: `TelegramSession` in the gateway, a fake
/// in tests.
public protocol ManagedTelegramSession: TelegramControl, TDLibRequesting {
    /// Every TDLib update of this session. Finishes when the session shuts down.
    var updates: AsyncStream<JSONBox> { get }
    func start() async
    /// Closes TDLib and waits for it. Returns false if TDLib did not confirm it closed, in
    /// which case its directory may still be in use.
    func shutdown() async -> Bool
}

/// What a reload did to the Telegram session (`POST /v1/admin/reload`).
public enum TelegramReloadOutcome: String, Sendable {
    /// No credentials before, credentials now: a session was created.
    case started
    /// Credentials changed: the old session was closed, then a new one created.
    case restarted
    /// Same credentials as before: nothing was touched.
    case unchanged
    /// No credentials now: there is no session (one that existed was closed).
    case disabled
}

/// The gateway's single, stable handle on Telegram. Everything that needs TDLib (translator,
/// monitor, media cache, the API) holds the host, and the host holds at most one session,
/// which it can create, replace or drop while the gateway keeps running. It never has two
/// sessions at once: a replacement is created only after the old one confirmed it closed,
/// because TDLib's directory can be open in one client at a time.
///
/// With no session (no credentials configured) it behaves like a gateway without Telegram:
/// `auth_state` is `unknown` and every TDLib request is `503 not_logged_in`.
public actor TelegramHost: TelegramControl, TDLibRequesting {
    public typealias Factory = @Sendable (TelegramCredentials) throws -> any ManagedTelegramSession

    /// Updates of whichever session is current, in one stream that outlives sessions.
    public nonisolated let updates: AsyncStream<JSONBox>
    private let forward: AsyncStream<JSONBox>.Continuation
    private let factory: Factory
    private let logger: Logger

    private var credentials: TelegramCredentials?
    private var session: (any ManagedTelegramSession)?
    private var pump: Task<Void, Never>?
    private var reconciling = false
    private var stopped = false

    public init(logger: Logger = Logger(label: "telegram"), factory: @escaping Factory) {
        self.factory = factory
        self.logger = logger
        (updates, forward) = AsyncStream.makeStream(of: JSONBox.self, bufferingPolicy: .unbounded)
    }

    public var currentCredentials: TelegramCredentials? { credentials }

    /// Brings the session in line with `wanted`. Throws `409 reload_in_progress` while another
    /// call is running, and `500 internal` if the old session would not close (no new one is
    /// created then; restart the gateway).
    public func apply(_ wanted: TelegramCredentials?) async throws -> TelegramReloadOutcome {
        guard !stopped else { throw APIError.internalError("The gateway is shutting down.") }
        guard !reconciling else {
            throw APIError(status: 409, code: "reload_in_progress", message: "Another reload is still running; try again in a moment.")
        }
        if wanted == credentials {
            return wanted == nil ? .disabled : .unchanged
        }
        reconciling = true
        defer { reconciling = false }

        let hadSession = session != nil
        if let old = session {
            logger.info("closing the Telegram session")
            guard await close(old) else {
                throw APIError.internalError("TDLib did not confirm it closed; restart the gateway to apply the new credentials.")
            }
            session = nil
            credentials = nil
        }
        guard let wanted else {
            logger.info("Telegram disabled: no api_id / api_hash")
            return .disabled
        }
        let new: any ManagedTelegramSession
        do {
            new = try factory(wanted)
        } catch {
            throw APIError.internalError("Could not create the Telegram session: \(error)")
        }
        session = new
        credentials = wanted
        let stream = new.updates
        let forward = forward
        pump = Task {
            for await update in stream { forward.yield(update) }
        }
        await new.start()
        await waitForFirstState(new)
        logger.info("Telegram session \(hadSession ? "restarted" : "started")")
        return hadSession ? .restarted : .started
    }

    /// Closes the session, if any, for good (gateway shutdown).
    public func shutdown() async {
        stopped = true
        if let session { _ = await close(session) }
        session = nil
        credentials = nil
        forward.finish()
    }

    private func close(_ old: any ManagedTelegramSession) async -> Bool {
        guard await old.shutdown() else { return false } // still alive: keep forwarding its updates
        await pump?.value // its stream has finished
        pump = nil
        return true
    }

    /// Gives TDLib a moment to report where the login stands, so that health and the login
    /// endpoints show the new state as soon as a reload returns.
    private func waitForFirstState(_ session: any ManagedTelegramSession) async {
        for _ in 0..<60 {
            if let state = await session.authState(), state != .waitTdlibParameters { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: TelegramControl

    public func authState() async -> AuthState? { await session?.authState() }
    public func connectionState() async -> ConnectionState { await session?.connectionState() ?? .waitingForNetwork }
    public func qrLink() async -> String? { await session?.qrLink() }
    public func codeInfo() async -> CodeInfo? { await session?.codeInfo() }
    public func account() async -> AccountInfo? { await session?.account() }
    public func requesting() async -> (any TDLibRequesting)? { session == nil ? nil : self }

    public func requestQr() async throws { try await required().requestQr() }
    public func setPhoneNumber(_ phone: String) async throws { try await required().setPhoneNumber(phone) }
    public func checkCode(_ code: String) async throws { try await required().checkCode(code) }
    public func checkPassword(_ password: String) async throws { try await required().checkPassword(password) }
    public func setEmailAddress(_ email: String) async throws { try await required().setEmailAddress(email) }
    public func checkEmailCode(_ code: String) async throws { try await required().checkEmailCode(code) }
    public func logOut() async throws { try await required().logOut() }

    // MARK: TDLibRequesting

    public func request(_ request: JSONBox) async throws -> JSONBox {
        try await required().request(request)
    }

    private func required() throws -> any ManagedTelegramSession {
        guard let session else { throw NoTelegram.error }
        return session
    }
}

/// The outcome of `POST /v1/admin/reload`.
public struct ReloadResult: Sendable, Equatable {
    public var telegram: TelegramReloadOutcome
    /// Settings that changed in `config.json` but only take effect when the gateway restarts.
    public var restartRequired: [String]
    /// What happened to the links to Volgenic; nil where the gateway runs no links.
    public var links: LinkReloadSummary?

    public init(telegram: TelegramReloadOutcome, restartRequired: [String], links: LinkReloadSummary? = nil) {
        self.telegram = telegram
        self.restartRequired = restartRequired
        self.links = links
    }

    public var json: JSONValue {
        var object: JSONObjectValue = [
            "reloaded": true,
            "telegram": .string(telegram.rawValue),
            "restart_required": .array(restartRequired.map { .string($0) }),
        ]
        if let links { object["links"] = links.json }
        return .object(object)
    }
}

/// Re-reads `config.json` and applies what can change while the gateway runs: the Telegram
/// credentials and the links to Volgenic (with their tokens from the secret store). Everything else that differs from the running configuration is reported as
/// needing a restart.
public actor ConfigReloader {
    private let paths: Paths
    private let running: Config
    private let host: TelegramHost
    private let links: (any LinkReloading)?
    private let environment: [String: String]

    public init(
        paths: Paths, running: Config, host: TelegramHost, links: (any LinkReloading)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.paths = paths
        self.running = running
        self.host = host
        self.links = links
        self.environment = environment
    }

    public func reload() async throws -> ReloadResult {
        let fresh: Config
        do {
            fresh = try Config.load(paths: paths, environment: environment)
        } catch {
            throw APIError.invalidRequest("config.json", "\(error)")
        }
        var restart: [String] = []
        if fresh.port != running.port { restart.append("port") }
        if fresh.secrets != running.secrets { restart.append("secrets") }
        if fresh.eventsRetentionDays != running.eventsRetentionDays { restart.append("events_retention_days") }
        if fresh.mediaCacheMaxBytes != running.mediaCacheMaxBytes { restart.append("media_cache_max_bytes") }
        let outcome = try await host.apply(TelegramCredentials(config: fresh))
        let linkSummary = await links?.apply(fresh.links)
        return ReloadResult(telegram: outcome, restartRequired: restart, links: linkSummary)
    }
}
