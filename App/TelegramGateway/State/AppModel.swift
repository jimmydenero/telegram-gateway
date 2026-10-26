import Foundation
import Observation
import OSLog
import Synchronization

let appLog = Logger(subsystem: "local.telegram-gateway", category: "app")

/// Holds the admin token where the HTTP client (any thread) and the model (main actor) can
/// both reach it.
final class TokenBox: Sendable {
    private let storage = Mutex<String?>(nil)
    func get() -> String? { storage.withLock { $0 } }
    func set(_ token: String?) { storage.withLock { $0 = token } }
}

/// The monitored set as the user is editing it, before Save.
struct MonitoredDraft: Equatable, Sendable {
    var chatIds: Set<String> = []
    var folderIds: Set<String> = []

    init(_ monitored: MonitoredChats? = nil) {
        chatIds = Set(monitored?.chatIds ?? [])
        folderIds = Set(monitored?.folderIds ?? [])
    }
}

/// What the user is about to grant for one access request.
struct ApprovalDraft: Equatable, Sendable {
    var request: AccessRequest
    /// Ticked chats, monitored or not. Unmonitored ones are monitored as part of approving.
    var chatIds: Set<String>
    /// True when the grant follows a folder instead of listing chats.
    var followFolder = false
    var folderId: String?
    var scopes: Set<String>
    /// Whether monitored chats the app did not ask for are listed too.
    var showOtherChats = false
}

/// One thing that is waiting for the user. The popover lists all of them; the window's
/// Overview lists the app-related ones (the others are its hero's own action).
enum NeedsItem: Identifiable, Equatable, Sendable {
    case setUp
    case startGateway
    case keyMissing
    case signIn
    case chooseChats
    case request(AccessRequest)
    case webhook(Grant)

    var id: String {
        switch self {
        case .setUp: "set-up"
        case .startGateway: "start-gateway"
        case .keyMissing: "key-missing"
        case .signIn: "sign-in"
        case .chooseChats: "choose-chats"
        case .request(let request): "request-\(request.requestId)"
        case .webhook(let grant): "webhook-\(grant.id)"
        }
    }

    /// The row's one line, and a second line only where it adds a fact.
    var title: String {
        switch self {
        case .setUp: "Set up Telegram Gateway"
        case .startGateway: "Start the gateway"
        case .keyMissing: "Restart the gateway"
        case .signIn: "Sign in to Telegram"
        case .chooseChats: "Choose chats to monitor"
        case .request(let request): "\(request.name) wants access"
        case .webhook(let grant): grant.webhook?.state == .paused ? "\(grant.app.name): delivery paused" : "\(grant.app.name): delivery failing"
        }
    }

    var detail: String? {
        switch self {
        case .setUp, .startGateway, .keyMissing, .signIn, .chooseChats: nil
        case .request(let request): Wording.timeLeft(until: request.expiresAt)
        case .webhook(let grant):
            grant.webhook?.lastError.map { grant.webhook?.state == .paused ? $0.capitalizedFirst : "Retrying · \($0)" }
        }
    }
}

/// What is selected in the Apps section of the window.
enum AppSelection: Hashable, Sendable {
    case request(String)
    case grant(String)
}

/// Everything the menu bar UI shows, in one observable object. Views read it through the
/// environment; all mutation happens here on the main actor. Network calls go through
/// `client`, which is the real gateway or a `FakeAPIClient`.
@MainActor
@Observable
final class AppModel {
    /// Which screen the panel shows. Decided from facts, never set directly.
    enum Screen: Equatable {
        /// First refresh has not completed.
        case loading
        /// Step 1: the Telegram key is missing (or being changed), or first-run start.
        case connect
        /// Set up before, but the gateway is not answering now.
        case gatewayDown
        /// Gateway up, but its access key could not be read.
        case keyMissing
        /// Step 2: Telegram sign-in not finished.
        case login
        /// Signed in: Overview, Chats, Apps.
        case main
    }

    /// The main window's sidebar.
    enum Section: String, CaseIterable, Identifiable {
        case overview, chats, apps, gateway
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .chats: "Chats"
            case .apps: "Apps"
            case .gateway: "Gateway"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .chats: "bubble.left.and.bubble.right"
            case .apps: "square.grid.2x2"
            case .gateway: "server.rack"
            }
        }
    }

    /// Which rows the Chats table shows.
    enum ChatScope: String, CaseIterable, Identifiable {
        case monitored, folders, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .monitored: "Monitored"
            case .folders: "Folders"
            case .all: "All"
            }
        }
    }

    enum StartPhase: Equatable {
        case idle
        case starting
        case failed(String)
    }

    enum LoginMode: Equatable { case qr, phone }

    /// The header: one dot, one phrase.
    struct Headline: Equatable {
        var tone: Tone
        var phrase: String
    }

    enum HeroAction: Equatable { case chooseChats, startGateway }

    /// The Overview's state line.
    struct Hero: Equatable {
        var tone: Tone
        var title: String
        var detail: String?
        var action: HeroAction?
    }

    let client: any APIClient
    let daemon: DaemonManager
    let isPreview: Bool
    private let tokenBox: TokenBox

    // Configuration and token
    var config: GatewayConfig
    var configError: String?
    private(set) var token: String?
    var tokenError: String?

    // Gateway and Telegram state
    private(set) var initialised = false
    private(set) var reachable = false
    private(set) var health: Health?
    private(set) var status: AdminStatus?
    private(set) var lastRefresh: Date?
    var lastError: String?
    var startPhase: StartPhase = .idle
    /// The user is changing the Telegram key from the Gateway section.
    var editingKey = false
    /// Continue was pressed and the gateway has not confirmed Telegram is up yet (or failed
    /// to): the Connect screen stays, with its progress or its failure card.
    private(set) var connectPending = false
    /// First-run setup finished (chats chosen or the banner dismissed). Persisted.
    var onboardingDone: Bool {
        didSet { if !isPreview, persistsOnboarding { UserDefaults.standard.set(onboardingDone, forKey: Self.onboardingKey) } }
    }
    var persistsOnboarding = true
    /// How long a start may take before the fallback, and before giving up.
    var startTimeout: Duration = .seconds(8)

    // Login
    var auth: AuthInfo?
    var loginError: String?
    var loginBusy = false
    var loginMode: LoginMode = .qr

    // Chats
    var chats: [Chat] = []
    var folders: [Folder] = []
    private(set) var monitored: MonitoredChats?
    var draft = MonitoredDraft()
    var chatsLoading = false
    var chatsSaving = false
    var chatsError: String?

    // Apps
    var requests: [AccessRequest] = []
    var grants: [Grant] = []
    var accessError: String?
    var approval: ApprovalDraft?
    var approving = false

    // UI
    var section: Section = .overview
    var selectedApp: AppSelection?
    var chatScope: ChatScope = .all
    var chatSearch = ""
    /// The menu bar popover is showing.
    var isPanelOpen = false
    /// The main window is showing.
    var isWindowOpen = false
    /// Incremented whenever the main window should be shown and brought to the front. The
    /// menu bar scene observes it; nothing else opens the window.
    private(set) var windowRequests = 0
    private var setupWasNeeded = false

    private var pollTask: Task<Void, Never>?
    private static let onboardingKey = "onboardingDone"

    init(client: any APIClient, daemon: DaemonManager, config: GatewayConfig, tokenBox: TokenBox = TokenBox(), isPreview: Bool = false, onboardingDone: Bool = false) {
        self.client = client
        self.daemon = daemon
        self.config = config
        self.tokenBox = tokenBox
        self.isPreview = isPreview
        self.onboardingDone = onboardingDone
    }

    // MARK: Factories

    /// The app as it runs for real: real config file, real secrets file, real gateway.
    static func live(persistOnboarding: Bool = true) -> AppModel {
        var configError: String?
        let config: GatewayConfig
        do {
            config = try GatewayConfig.load()
        } catch {
            config = GatewayConfig()
            configError = error.localizedDescription
        }
        let box = TokenBox()
        let client = HTTPAPIClient(baseURL: config.baseURL, token: { box.get() })
        let done = persistOnboarding && UserDefaults.standard.bool(forKey: onboardingKey)
        let model = AppModel(client: client, daemon: DaemonManager(), config: config, tokenBox: box, onboardingDone: done)
        model.persistsOnboarding = persistOnboarding
        model.configError = configError
        return model
    }

    /// A model over `FakeAPIClient` for previews, snapshots and tests. It never reads the
    /// secrets file or the Keychain, never talks to launchd, and never sleeps for long.
    static func preview(_ scenario: FakeAPIClient.Scenario = .loggedIn, credentials: Bool = true, token: Bool = true, has2FA: Bool = true, onboarded: Bool = true) -> AppModel {
        let box = TokenBox()
        if token { box.set("tgw_previewtoken") }
        let config = credentials ? GatewayConfig(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef", daemonPath: "/tmp/GatewayDaemon") : GatewayConfig()
        let model = AppModel(client: FakeAPIClient(scenario: scenario, has2FA: has2FA), daemon: DaemonManager(previewMode: true), config: config, tokenBox: box, isPreview: true, onboardingDone: onboarded)
        model.token = box.get()
        model.startTimeout = .milliseconds(30)
        return model
    }

    // MARK: Derived state

    var screen: Screen {
        guard initialised else { return .loading }
        if !config.hasCredentials || editingKey || connectPending { return .connect }
        if !reachable { return onboardingDone ? .gatewayDown : .connect }
        guard token != nil else { return .keyMissing }
        guard let health else { return .connect }
        return health.tdlib.authState.isLoggedIn ? .main : .login
    }

    /// Setup and sign-in run as a focused flow; every other state has the sidebar.
    var showsSidebar: Bool { screen == .main || screen == .gatewayDown || screen == .keyMissing }

    var authState: AuthState { auth?.authState ?? health?.tdlib.authState ?? .unknown }
    var isConnected: Bool { health?.tdlib.connectionState == .ready }
    var pendingRequestCount: Int { requests.count }
    var monitoredCount: Int { monitored?.effectiveChatIds.count ?? status?.monitoredChatCount ?? 0 }
    var chatsByID: [String: Chat] { Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    /// "@ada", or the display name when the account has no username.
    var accountName: String? {
        guard let account = status?.account else { return nil }
        if let username = account.username, !username.isEmpty { return "@\(username)" }
        return account.displayName
    }

    var headline: Headline {
        switch screen {
        case .loading:
            return Headline(tone: .neutral, phrase: "Connecting…")
        case .connect, .gatewayDown:
            if startPhase == .starting { return Headline(tone: .attention, phrase: "Starting the gateway…") }
            if case .failed = startPhase, reachable { return Headline(tone: .failed, phrase: "Telegram didn't start") }
            if editingKey { return Headline(tone: .neutral, phrase: "Changing the Telegram key") }
            if !config.hasCredentials { return Headline(tone: .neutral, phrase: "Not set up yet") }
            return Headline(tone: .failed, phrase: "Gateway not running")
        case .keyMissing:
            return Headline(tone: .failed, phrase: "Gateway needs attention")
        case .login:
            switch authState {
            case .loggingOut: return Headline(tone: .attention, phrase: "Signing out…")
            case .waitPhoneNumber where loginMode == .qr, .waitQRConfirmation where loginMode == .qr:
                return Headline(tone: .attention, phrase: "Scan the code to sign in")
            case .waitPhoneNumber, .waitQRConfirmation:
                return Headline(tone: .attention, phrase: "Sign in to Telegram")
            default: return Headline(tone: .attention, phrase: "Finish signing in")
            }
        case .main:
            guard isConnected else { return Headline(tone: .attention, phrase: "Reconnecting to Telegram…") }
            return Headline(tone: .ok, phrase: accountName.map { "Connected as \($0)" } ?? "Connected")
        }
    }

    var hero: Hero {
        switch screen {
        case .loading:
            return Hero(tone: .neutral, title: "Connecting…", detail: nil, action: nil)
        case .connect:
            if startPhase == .starting { return Hero(tone: .attention, title: "Starting the gateway…", detail: nil, action: nil) }
            return Hero(tone: .attention, title: "Not set up yet", detail: "Connect the gateway to your Telegram account.", action: nil)
        case .gatewayDown:
            if startPhase == .starting { return Hero(tone: .attention, title: "Starting the gateway…", detail: nil, action: nil) }
            return Hero(tone: .failed, title: "Gateway not running", detail: "Nothing is monitored until it starts.", action: .startGateway)
        case .keyMissing:
            return Hero(tone: .failed, title: "Can't control the gateway", detail: "The app can't read the gateway's access key.", action: nil)
        case .login:
            return Hero(tone: .attention, title: "Not signed in", detail: "Nothing is collected until you sign in to Telegram.", action: nil)
        case .main:
            break
        }
        guard isConnected else {
            return Hero(tone: .attention, title: "Reconnecting…", detail: "Telegram's connection dropped. Messages sent meanwhile are collected once it is back.", action: nil)
        }
        let count = status?.monitoredChatCount ?? monitoredCount
        guard count > 0 else {
            return Hero(tone: .attention, title: "Not monitoring any chats", detail: "Nothing is collected until you pick some.", action: .chooseChats)
        }
        var detail = "\(Wording.count(status?.eventsLastHour ?? 0, "message")) in the last hour · \((status?.headSeq ?? health?.headSeq ?? 0).formatted()) total"
        if let backfill = status?.backfill, backfill.inProgress {
            detail += " · catching up on \(Wording.count(backfill.chatsPending, "chat"))"
        }
        return Hero(tone: .neutral, title: "Monitoring \(Wording.count(count, "chat"))", detail: detail, action: nil)
    }

    /// Pending requests, then deliveries that stopped or are failing.
    var appNeeds: [NeedsItem] {
        requests.map(NeedsItem.request) + grants.filter { $0.webhook?.state == .paused || $0.webhook?.state == .retrying }.map(NeedsItem.webhook)
    }

    /// Everything waiting for the user, whatever state the gateway is in.
    var needsYou: [NeedsItem] {
        switch screen {
        case .loading: []
        case .connect: startPhase == .starting ? [] : [.setUp]
        case .gatewayDown: startPhase == .starting ? [] : [.startGateway]
        case .keyMissing: [.keyMissing]
        case .login: [.signIn]
        case .main: ((status?.monitoredChatCount ?? monitoredCount) == 0 ? [.chooseChats] : []) + appNeeds
        }
    }

    // MARK: The window

    /// Shows the main window and brings it to the front (or re-focuses it).
    func requestWindow() {
        windowRequests += 1
    }

    /// Opens the window at the place where the user can deal with `item`.
    func open(_ item: NeedsItem) {
        switch item {
        case .setUp, .signIn:
            break
        case .startGateway, .keyMissing:
            section = .overview
        case .chooseChats:
            section = .chats
        case .request(let request):
            section = .apps
            selectedApp = .request(request.requestId)
            Task {
                if chats.isEmpty { await loadChats() }
                beginApproval(request)
            }
        case .webhook(let grant):
            section = .apps
            selectedApp = .grant(grant.id)
        }
        requestWindow()
    }

    /// Setup and sign-in cannot be done from the popover, so the window opens by itself when
    /// either becomes necessary (once per occurrence: closing it is respected).
    private func openWindowIfSetupNeeded() {
        let needed = initialised && (screen == .connect || screen == .login)
        if needed, !setupWasNeeded { requestWindow() }
        setupWasNeeded = needed
    }

    // MARK: Polling

    /// Starts the background refresh. Every 15s while the panel is closed (enough for the
    /// pending-request badge), every 5s while it is open.
    func start() {
        guard pollTask == nil else { return }
        appLog.notice("start: base URL \(self.config.baseURL.absoluteString, privacy: .public), credentials \(self.config.hasCredentials)")
        daemon.locate(config: config)
        daemon.refreshAgentState()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds: Double = self.isPanelOpen || self.isWindowOpen ? 5 : 15
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func panelOpened() {
        isPanelOpen = true
        daemon.refreshAgentState()
        Task { await refresh() }
    }

    func panelClosed() {
        isPanelOpen = false
    }

    func windowOpened() {
        isWindowOpen = true
        daemon.refreshAgentState()
        Task { await refresh() }
    }

    func windowClosed() {
        isWindowOpen = false
    }

    /// One round: token, health, then status, requests and grants if signed in.
    func refresh() async {
        if !isPreview { loadToken() }
        do {
            health = try await client.health()
            reachable = true
            lastError = nil
        } catch {
            reachable = false
            health = nil
            status = nil
            lastError = (error as? APIClientError)?.errorDescription ?? error.localizedDescription
        }
        defer {
            initialised = true
            lastRefresh = Date()
            openWindowIfSetupNeeded()
        }
        guard reachable, token != nil, let health else { return }
        if let auth, auth.authState.isLoggedIn != health.tdlib.authState.isLoggedIn { self.auth = nil }
        do {
            status = try await client.adminStatus()
            tokenError = nil
        } catch let error as APIClientError where error.apiCode == "invalid_token" || error.apiCode == "missing_token" {
            tokenError = "The gateway no longer accepts the app's access key."
        } catch {
            lastError = error.localizedDescription
        }
        guard health.tdlib.authState.isLoggedIn else { return }
        if let list = try? await client.accessRequests() { requests = list }
        if let list = try? await client.grants() { grants = list }
        // An install that already monitors chats or serves apps is past first-run setup.
        if !onboardingDone, let status, status.monitoredChatCount > 0 || status.grantCount > 0 {
            onboardingDone = true
        }
    }

    /// Reads `secrets.json` (or, opt-in, the Keychain). Never called for previews or tests.
    func loadToken() {
        do {
            token = try AdminToken.read(config: config)
            tokenBox.set(token)
            if token != nil { tokenError = nil }
        } catch {
            token = nil
            tokenBox.set(nil)
            tokenError = error.localizedDescription
            appLog.error("admin token: \(self.tokenError ?? "", privacy: .public)")
        }
    }

    // MARK: Step 1: connect

    /// "Continue": saves the key, then makes the gateway use it. The Connect screen stays up
    /// until Telegram is actually running in the gateway, or shows why it is not.
    func connect(apiId: Int, apiHash: String) async {
        if !isPreview {
            do {
                config = try GatewayConfig.merge(["api_id": apiId, "api_hash": apiHash])
                configError = nil
            } catch {
                configError = error.localizedDescription
                connectPending = true
                startPhase = .failed("Couldn't save the key: \(error.localizedDescription)")
                return
            }
        } else {
            config.apiId = apiId
            config.apiHash = apiHash
        }
        editingKey = false
        connectPending = true
        await startGateway()
        if startPhase == .idle { connectPending = false }
    }

    /// Leaves the Connect screen without (another) attempt.
    func cancelConnect() {
        editingKey = false
        connectPending = false
        if startPhase != .starting { startPhase = .idle }
    }

    func reloadConfig() {
        guard !isPreview else { return }
        do {
            config = try GatewayConfig.load()
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }

    /// Gets a gateway running with the current configuration, and Telegram running inside it.
    ///
    /// - A gateway that already answers is asked to reload its configuration in place
    ///   (`POST /v1/admin/reload`). It may have been started by this app or installed from the
    ///   command line; either way nothing needs restarting. A gateway too old to have the
    ///   endpoint, or one that says a full restart is required, is restarted instead.
    /// - Otherwise the gateway is started: the login-item route first and, if that does not
    ///   bring it up, inside this app. The user is never asked which.
    ///
    /// In both cases the gateway answering is not enough: Telegram must be up in it (its
    /// `auth_state` has left `unknown`) before this reports success.
    func startGateway() async {
        startPhase = .starting
        daemon.clearError()
        if reachable {
            if let failure = await reloadRunningGateway() { return failStart(failure) }
        } else {
            daemon.register(config: config)
            reloadConfig()
            var up = daemon.agentState == .enabled
            if up { up = await waitForGateway() }
            if !up {
                // Registered but silent: stop that copy so only one gateway ever runs.
                if daemon.agentState == .enabled { daemon.unregister() }
                daemon.runInForeground(config: config)
                if daemon.isForegroundRunning { up = await waitForGateway() }
            }
            if !up { return failStart(startFailureReason()) }
        }
        guard await waitForTelegram() else {
            return failStart("The gateway is running, but Telegram didn't start in it.\(daemon.lastLogLine().map { " \($0)" } ?? "")")
        }
        startPhase = .idle
    }

    private func failStart(_ reason: String) {
        startPhase = .failed(reason)
        appLog.error("gateway did not start: \(reason, privacy: .public)")
    }

    /// Asks the running gateway to pick up `config.json`. Returns why it could not, or nil.
    private func reloadRunningGateway() async -> String? {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let result = try await client.reload()
                if result.telegram == .disabled {
                    return "The gateway is running without the Telegram key. It may be reading a different settings file."
                }
                // Some settings (the port) only take effect in a new process.
                return result.restartRequired.isEmpty ? nil : await restartAndWait()
            } catch let error as APIClientError where error.isMissingEndpoint {
                // An older gateway: restarting makes it read the configuration at startup.
                return await restartAndWait()
            } catch APIClientError.noToken {
                // Without the access key the app cannot ask; a restart needs no key.
                return await restartAndWait()
            } catch let error as APIClientError where error.apiCode == "reload_in_progress" && attempt < 4 {
                // Another reload (tgw, or a second click) is running; let it finish.
                try? await Task.sleep(for: isPreview ? .milliseconds(5) : .milliseconds(500))
            } catch let error as APIClientError where error.httpStatus == 500 {
                // The gateway could not replace its Telegram session in place; a new process can.
                return await restartAndWait()
            } catch {
                return (error as? APIClientError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Restarts whichever gateway is running and waits for it to answer again. Returns why
    /// that failed, or nil.
    private func restartAndWait() async -> String? {
        await daemon.restart(config: config)
        if let error = daemon.lastError { return error }
        // Give the old process a moment to go away, so the wait sees the new one.
        if !isPreview { try? await Task.sleep(for: .seconds(1)) }
        return await waitForGateway() ? nil : startFailureReason()
    }

    private func waitForGateway() async -> Bool {
        let deadline = ContinuousClock.now + startTimeout
        repeat {
            await refresh()
            if reachable { return true }
            try? await Task.sleep(for: isPreview ? .milliseconds(5) : .milliseconds(500))
        } while ContinuousClock.now < deadline
        return false
    }

    /// Waits until the gateway reports a Telegram session (any state but `unknown`/`closed`).
    private func waitForTelegram() async -> Bool {
        let deadline = ContinuousClock.now + startTimeout
        repeat {
            await refresh()
            if let health, health.tdlib.authState.isTelegramRunning { return true }
            try? await Task.sleep(for: isPreview ? .milliseconds(5) : .milliseconds(500))
        } while ContinuousClock.now < deadline
        return false
    }

    private func startFailureReason() -> String {
        if case .exited(let code) = daemon.foreground {
            if let line = daemon.lastLogLine() { return line }
            return "It stopped right after starting (exit code \(code))."
        }
        if let error = daemon.lastError { return error }
        return "It didn't answer on port \(String(config.baseURL.port ?? GatewayConfig.defaultPort))."
    }

    /// "Restart gateway": restarts whichever gateway is running and waits for it to answer.
    /// A failure (nothing to restart, or it did not come back) is reported in `lastError`.
    func restartGateway() {
        Task { await restartGatewayAndWait() }
    }

    func restartGatewayAndWait() async {
        if let failure = await restartAndWait() {
            await refresh()
            lastError = failure
        }
    }

    /// From the sign-in screen when Telegram is not running in the gateway: reload (or
    /// restart) it and report the reason if that does not help.
    func reviveTelegram() {
        Task { await startGateway() }
    }

    // MARK: Step 2: sign in

    func refreshAuth() async {
        do {
            let info = try await client.auth()
            // Only publish a change: an identical link must not redraw (and flash) the QR.
            if auth != info { auth = info }
            if info.authState.isLoggedIn, health?.tdlib.authState.isLoggedIn == false {
                await refresh()
                didSignIn()
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    func requestQR() async {
        await login { try await self.client.requestQRLogin() }
    }

    func submitPhone(_ phone: String) async {
        await login { try await self.client.submitPhoneNumber(phone.trimmingCharacters(in: .whitespaces)) }
    }

    func submitCode(_ code: String) async {
        await login { try await self.client.submitCode(code.trimmingCharacters(in: .whitespaces)) }
    }

    func submitPassword(_ password: String) async {
        await login { try await self.client.submitPassword(password) }
    }

    func submitEmail(_ email: String) async {
        await login { try await self.client.submitEmailAddress(email.trimmingCharacters(in: .whitespaces)) }
    }

    func submitEmailCode(_ code: String) async {
        await login { try await self.client.submitEmailCode(code.trimmingCharacters(in: .whitespaces)) }
    }

    /// Back to the start of sign-in, by QR or by phone.
    func restartLogin(mode: LoginMode) async {
        loginMode = mode
        await requestQR()
    }

    private func login(_ action: () async throws -> AuthInfo) async {
        loginBusy = true
        loginError = nil
        defer { loginBusy = false }
        do {
            let info = try await action()
            auth = info
            if info.authState.isLoggedIn {
                await refresh()
                didSignIn()
            }
        } catch let error as APIClientError {
            if case .api(let apiError, _, let hint) = error {
                loginError = Self.loginMessage(for: apiError)
                if let hint, !hint.isEmpty, var current = auth { current.passwordHint = hint; auth = current }
            } else {
                loginError = error.errorDescription
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Telegram's and the gateway's error codes in plain words.
    static func loginMessage(for error: APIError) -> String {
        switch error.reason {
        case "wrong_password": return "That password isn't right."
        case "wrong_code": return "That code isn't right."
        default: break
        }
        if error.message.contains("API_ID_INVALID") { return "Telegram doesn't recognise the API ID and hash. Check them in Gateway details." }
        if error.message.contains("PHONE_NUMBER_INVALID") { return "Telegram doesn't recognise that number. Include the country code." }
        if error.message.contains("FLOOD") { return "Telegram is asking to wait before trying again." }
        return error.message
    }

    /// First sign-in lands on Chats, where step 3 is.
    private func didSignIn() {
        loginMode = .qr
        if !onboardingDone { section = .chats }
    }

    func logout() async {
        loginBusy = true
        defer { loginBusy = false }
        do {
            try await client.logout()
            auth = nil
            chats = []
            folders = []
            monitored = nil
            draft = MonitoredDraft()
            selectedApp = nil
            approval = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Chats

    func loadChats() async {
        chatsLoading = true
        chatsError = nil
        defer { chatsLoading = false }
        do {
            async let chatList = client.allChats()
            async let folderList = client.folders()
            async let monitoredSet = client.monitoredChats()
            chats = try await chatList
            folders = try await folderList
            setMonitored(try await monitoredSet)
        } catch {
            chatsError = error.localizedDescription
        }
    }

    /// Adopts the gateway's monitored set; the draft follows unless there are unsaved edits.
    private func setMonitored(_ new: MonitoredChats) {
        let wasDirty = isDraftDirty
        monitored = new
        if !wasDirty { draft = MonitoredDraft(new) }
        let effective = Set(new.effectiveChatIds)
        chats = chats.map { var chat = $0; chat.isMonitored = effective.contains(chat.id); return chat }
        folders = folders.map { var folder = $0; folder.isMonitored = new.folderIds.contains(folder.id); return folder }
    }

    var isDraftDirty: Bool { draft != MonitoredDraft(monitored) }

    /// How many ticks differ from what is saved.
    var draftChangeCount: Int {
        let saved = MonitoredDraft(monitored)
        return draft.chatIds.symmetricDifference(saved.chatIds).count + draft.folderIds.symmetricDifference(saved.folderIds).count
    }

    /// How many chats would be monitored after saving the draft.
    var draftEffectiveCount: Int {
        var ids = draft.chatIds
        for folder in folders where draft.folderIds.contains(folder.id) { ids.formUnion(folder.chatIds) }
        return ids.count
    }

    /// The ticked folder that already covers this chat, if any.
    func coveringFolder(for chatId: String) -> Folder? {
        folders.first { draft.folderIds.contains($0.id) && $0.chatIds.contains(chatId) }
    }

    func isChatTicked(_ chatId: String) -> Bool {
        draft.chatIds.contains(chatId) || coveringFolder(for: chatId) != nil
    }

    func setChat(_ chatId: String, monitored on: Bool) {
        if on { draft.chatIds.insert(chatId) } else { draft.chatIds.remove(chatId) }
    }

    func setFolder(_ folderId: String, monitored on: Bool) {
        if on { draft.folderIds.insert(folderId) } else { draft.folderIds.remove(folderId) }
    }

    func revertDraft() {
        draft = MonitoredDraft(monitored)
    }

    /// Replaces the monitored set (docs/api.md `PUT /v1/admin/monitored-chats`).
    @discardableResult
    func saveDraft() async -> Bool {
        chatsSaving = true
        chatsError = nil
        defer { chatsSaving = false }
        do {
            let saved = try await client.setMonitoredChats(chatIds: draft.chatIds.sorted(), folderIds: draft.folderIds.sorted())
            draft = MonitoredDraft(saved)
            setMonitored(saved)
            if !saved.effectiveChatIds.isEmpty { onboardingDone = true }
            await refresh()
            return true
        } catch {
            chatsError = error.localizedDescription
            return false
        }
    }

    // MARK: Apps

    func loadAccess() async {
        do {
            async let pending = client.accessRequests()
            async let granted = client.grants()
            requests = try await pending
            grants = try await granted
            accessError = nil
        } catch {
            accessError = error.localizedDescription
        }
    }

    func grant(id: String) -> Grant? { grants.first { $0.id == id } }
    func request(id: String) -> AccessRequest? { requests.first { $0.requestId == id } }

    /// Keeps something selected in Apps: the current selection if it still exists, else the
    /// oldest request, else the first app.
    func normalizeAppSelection() {
        switch selectedApp {
        case .request(let id) where request(id: id) != nil: return
        case .grant(let id) where grant(id: id) != nil: return
        default: break
        }
        selectedApp = requests.first.map { .request($0.requestId) } ?? grants.first.map { .grant($0.id) }
    }

    /// Opens the approval screen with the request's chats and permissions pre-ticked.
    func beginApproval(_ request: AccessRequest) {
        let requested = request.requestedChats.chatIds
        let monitoredIds = chats.filter(\.isMonitored).map(\.id)
        approval = ApprovalDraft(
            request: request,
            chatIds: Set(requested.isEmpty ? monitoredIds : requested),
            scopes: Set(request.scopes))
        accessError = nil
    }

    /// The chats offered for a request: the ones it asked for, then (when expanded, or when
    /// it asked for "any") the other monitored chats.
    func approvalChatIds(_ draft: ApprovalDraft) -> [String] {
        let requested = draft.request.requestedChats.chatIds
        let others = chats.filter { $0.isMonitored && !requested.contains($0.id) }.map(\.id)
        return requested + (requested.isEmpty || draft.showOtherChats ? others : [])
    }

    func otherMonitoredCount(_ draft: ApprovalDraft) -> Int {
        let requested = draft.request.requestedChats.chatIds
        return requested.isEmpty ? 0 : chats.filter { $0.isMonitored && !requested.contains($0.id) }.count
    }

    func approvalSummary(_ draft: ApprovalDraft) -> String {
        let permissions = Wording.count(draft.scopes.count, "permission")
        if draft.followFolder {
            let title = folders.first { $0.id == draft.folderId }?.title
            return "\(title.map { "\($0) folder" } ?? "No folder") · \(permissions)"
        }
        return "\(Wording.count(draft.chatIds.count, "chat")) · \(permissions)"
    }

    func canApprove(_ draft: ApprovalDraft) -> Bool {
        guard !draft.scopes.isEmpty else { return false }
        return draft.followFolder ? draft.folderId != nil : !draft.chatIds.isEmpty
    }

    /// Approves the open request. Ticked chats that are not monitored yet are added to the
    /// monitored set first (docs/grants.md: a grant never exceeds the monitored set, and the
    /// app monitors first so the user makes one decision).
    @discardableResult
    func approve() async -> Bool {
        guard let draft = approval, canApprove(draft) else { return false }
        approving = true
        accessError = nil
        defer { approving = false }
        do {
            let selection: GrantChatSelection
            if draft.followFolder, let folderId = draft.folderId {
                selection = .folder(folderId)
            } else {
                let current = try await client.monitoredChats()
                let toMonitor = draft.chatIds.subtracting(current.effectiveChatIds)
                if !toMonitor.isEmpty {
                    let saved = try await client.setMonitoredChats(chatIds: Set(current.chatIds).union(toMonitor).sorted(), folderIds: current.folderIds)
                    setMonitored(saved)
                }
                selection = .chats(draft.chatIds.sorted())
            }
            let scopes = Permission.sorted(draft.request.scopes.filter { draft.scopes.contains($0) })
            let grant = try await client.approve(requestId: draft.request.requestId, selection: selection, scopes: scopes)
            approval = nil
            selectedApp = .grant(grant.id)
            await loadAccess()
            await refresh()
            return true
        } catch {
            accessError = error.localizedDescription
            return false
        }
    }

    func cancelApproval() {
        approval = nil
    }

    func deny(_ request: AccessRequest) async {
        do {
            try await client.deny(requestId: request.requestId, reason: nil)
            if selectedApp == .request(request.requestId) { selectedApp = nil }
            await loadAccess()
        } catch {
            accessError = error.localizedDescription
        }
    }

    func revoke(_ grant: Grant) async {
        do {
            try await client.revoke(grantId: grant.id)
            if selectedApp == .grant(grant.id) { selectedApp = nil }
            await loadAccess()
        } catch {
            accessError = error.localizedDescription
        }
    }

    func resumeWebhook(_ grant: Grant) async {
        do {
            try await client.resumeWebhook(grantId: grant.id)
            await loadAccess()
        } catch {
            accessError = error.localizedDescription
        }
    }
}
