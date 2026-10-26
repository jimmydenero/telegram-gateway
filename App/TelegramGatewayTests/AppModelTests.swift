import Foundation
import Testing
@testable import TelegramGateway

/// The model's screen decisions and the flows the screens drive, all against the fake.
/// Nothing here reads the Keychain, the real secrets file, launchd or the app's defaults.
@Suite("AppModel over FakeAPIClient")
@MainActor
struct AppModelTests {
    // MARK: Screens and header

    @Test("Screen follows the facts")
    func screens() async {
        let noKey = AppModel.preview(.loggedIn, credentials: false)
        await noKey.refresh()
        #expect(noKey.screen == .connect)

        let firstRunDown = AppModel.preview(.unreachable, onboarded: false)
        await firstRunDown.refresh()
        #expect(firstRunDown.screen == .connect)

        let down = AppModel.preview(.unreachable)
        await down.refresh()
        #expect(down.screen == .gatewayDown)
        #expect(!down.reachable)

        let noToken = AppModel.preview(.loggedIn, token: false)
        await noToken.refresh()
        #expect(noToken.screen == .keyMissing)

        let loggedOut = AppModel.preview(.loggedOut)
        await loggedOut.refresh()
        #expect(loggedOut.screen == .login)

        let ready = AppModel.preview(.loggedIn)
        #expect(ready.screen == .loading)
        await ready.refresh()
        #expect(ready.screen == .main)
        #expect(ready.accountName == "@ada")
        #expect(ready.pendingRequestCount == 1)
        #expect(ready.grants.count == 2)

        ready.editingKey = true
        #expect(ready.screen == .connect)
    }

    @Test("Header: one phrase per state")
    func headlines() async {
        func headline(_ scenario: FakeAPIClient.Scenario, credentials: Bool = true, token: Bool = true, onboarded: Bool = true) async -> AppModel.Headline {
            let model = AppModel.preview(scenario, credentials: credentials, token: token, onboarded: onboarded)
            await model.refresh()
            return model.headline
        }
        #expect(AppModel.preview(.loggedIn).headline == .init(tone: .neutral, phrase: "Connecting…"))
        #expect(await headline(.loggedIn) == .init(tone: .ok, phrase: "Connected as @ada"))
        #expect(await headline(.reconnecting) == .init(tone: .attention, phrase: "Reconnecting to Telegram…"))
        #expect(await headline(.waitingForQR) == .init(tone: .attention, phrase: "Scan the code to sign in"))
        #expect(await headline(.waitingForPassword) == .init(tone: .attention, phrase: "Finish signing in"))
        #expect(await headline(.unreachable) == .init(tone: .failed, phrase: "Gateway not running"))
        #expect(await headline(.unreachable, credentials: false, onboarded: false) == .init(tone: .neutral, phrase: "Not set up yet"))
        #expect(await headline(.loggedIn, token: false) == .init(tone: .failed, phrase: "Gateway needs attention"))
    }

    @Test("Overview hero: calm when fine, says what is wrong and offers one action otherwise")
    func hero() async {
        let fine = AppModel.preview(.loggedIn)
        await fine.refresh()
        #expect(fine.hero == .init(tone: .neutral, title: "Monitoring 3 chats", detail: "37 messages in the last hour · 4,812 total", action: nil))

        let none = AppModel.preview(.loggedInEmpty)
        await none.refresh()
        #expect(none.hero.tone == .attention)
        #expect(none.hero.title == "Not monitoring any chats")
        #expect(none.hero.action == .chooseChats)

        let reconnecting = AppModel.preview(.reconnecting)
        await reconnecting.refresh()
        #expect(reconnecting.hero.tone == .attention)
        #expect(reconnecting.hero.action == nil)

        let down = AppModel.preview(.unreachable)
        await down.refresh()
        #expect(down.hero.tone == .failed)
        #expect(down.hero.title == "Gateway not running")
        #expect(down.hero.action == .startGateway)

        let signedOut = AppModel.preview(.waitingForQR)
        await signedOut.refresh()
        #expect(signedOut.hero.tone == .attention)
        #expect(signedOut.hero.title == "Not signed in")

        let fresh = AppModel.preview(.unreachable, credentials: false, onboarded: false)
        await fresh.refresh()
        #expect(fresh.hero.title == "Not set up yet")

        let noKey = AppModel.preview(.loggedIn, token: false)
        await noKey.refresh()
        #expect(noKey.hero.tone == .failed)
        #expect(noKey.hero.title == "Can't control the gateway")
    }

    // MARK: The window

    @Test("The window opens by itself when setup or sign-in is needed, once per occurrence")
    func windowOpensWhenNeeded() async {
        let fine = AppModel.preview(.loggedIn)
        await fine.refresh()
        #expect(fine.windowRequests == 0)
        #expect(fine.showsSidebar)

        let firstRun = AppModel.preview(.unreachable, credentials: false, onboarded: false)
        await firstRun.refresh()
        #expect(firstRun.windowRequests == 1)
        #expect(!firstRun.showsSidebar)
        // The user may close it; it does not pop up again for the same need.
        await firstRun.refresh()
        #expect(firstRun.windowRequests == 1)

        let signedOut = AppModel.preview(.loggedOut, has2FA: false)
        await signedOut.refresh()
        #expect(signedOut.windowRequests == 1)
        signedOut.loginMode = .phone
        await signedOut.submitPhone("+15551234567")
        await signedOut.submitCode("12345")
        #expect(signedOut.screen == .main)
        #expect(signedOut.windowRequests == 1)
        // Signed out again later: a new occurrence, so the window comes back.
        await signedOut.logout()
        #expect(signedOut.screen == .login)
        #expect(signedOut.windowRequests == 2)

        // A gateway that is down does not force the window open; the popover says so.
        let down = AppModel.preview(.unreachable)
        await down.refresh()
        #expect(down.windowRequests == 0)
        #expect(down.showsSidebar)
    }

    @Test("A Needs-you row opens the window at the right place")
    func openFromPopover() async throws {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        let paused = try #require(model.grants.first { $0.webhook?.state == .paused })
        model.open(.webhook(paused))
        #expect(model.windowRequests == 1)
        #expect(model.section == .apps)
        #expect(model.selectedApp == .grant(paused.id))

        model.open(.chooseChats)
        #expect(model.section == .chats)
        model.open(.startGateway)
        #expect(model.section == .overview)
        #expect(model.windowRequests == 3)

        let request = model.requests[0]
        model.open(.request(request))
        #expect(model.section == .apps)
        #expect(model.selectedApp == .request(request.requestId))
        // The review sheet opens once the chats are there.
        for _ in 0..<50 where model.approval == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.approval?.request.requestId == request.requestId)

        model.requestWindow()
        #expect(model.windowRequests == 5)
    }

    @Test("Apps selection: oldest request first, kept while it exists")
    func appSelection() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadAccess()
        model.normalizeAppSelection()
        #expect(model.selectedApp == .request(model.requests[0].requestId))
        model.selectedApp = .grant(model.grants[1].id)
        model.normalizeAppSelection()
        #expect(model.selectedApp == .grant(model.grants[1].id))
        await model.deny(model.requests[0])
        model.selectedApp = .request("gone")
        model.normalizeAppSelection()
        #expect(model.selectedApp == .grant(model.grants[0].id))
    }

    @Test("Needs you: pending requests and stopped deliveries, nothing when all is fine")
    func needsYou() async {
        let busy = AppModel.preview(.loggedIn)
        await busy.refresh()
        #expect(busy.needsYou.count == 2)
        #expect(busy.needsYou == busy.appNeeds)
        #expect(busy.needsYou.map(\.title) == ["Community Analytics wants access", "Archive: delivery paused"])
        #expect(busy.needsYou[1].detail == "Connection refused")
        guard case .request(let request) = busy.needsYou[0], case .webhook(let grant) = busy.needsYou[1] else {
            Issue.record("expected a request then a webhook")
            return
        }
        #expect(request.name == "Community Analytics")
        #expect(grant.app.name == "Archive")
        #expect(grant.state.tone == .attention)
        #expect(grant.state.text == "Paused")

        let quiet = AppModel.preview(.loggedInQuiet)
        await quiet.refresh()
        #expect(quiet.needsYou.isEmpty)

        // Whatever keeps the gateway from working is itself something that needs the user.
        func needs(_ scenario: FakeAPIClient.Scenario, credentials: Bool = true, token: Bool = true, onboarded: Bool = true) async -> [NeedsItem] {
            let model = AppModel.preview(scenario, credentials: credentials, token: token, onboarded: onboarded)
            await model.refresh()
            return model.needsYou
        }
        #expect(await needs(.unreachable, credentials: false, onboarded: false) == [.setUp])
        #expect(await needs(.unreachable) == [.startGateway])
        #expect(await needs(.loggedIn, token: false) == [.keyMissing])
        #expect(await needs(.waitingForQR) == [.signIn])
        #expect(await needs(.loggedInEmpty) == [.chooseChats])
        #expect(quiet.grants.allSatisfy { $0.state.tone == .ok })
        #expect(quiet.grants[1].summary == "1 chat · new messages")
        #expect(quiet.grants[0].summary == "Product folder · new messages, chat names")
    }

    // MARK: Step 1

    @Test("Continue saves the key and starts the gateway; a gateway that never answers is reported with a reason")
    func connectFailure() async {
        let model = AppModel.preview(.unreachable, credentials: false, token: false, onboarded: false)
        await model.refresh()
        #expect(model.screen == .connect)
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(model.config.hasCredentials)
        // Tried the login-item route, then fell back to running it inside the app.
        #expect(model.daemon.isForegroundRunning)
        #expect(model.daemon.agentState == .notRegistered)
        guard case .failed(let reason) = model.startPhase else {
            Issue.record("expected the start to fail, got \(model.startPhase)")
            return
        }
        #expect(reason == "It didn't answer on port 41414.")
        #expect(model.screen == .connect)
        #expect(model.headline.phrase == "Gateway not running")
    }

    @Test("Continue with a gateway that answers moves on to sign-in")
    func connectSuccess() async {
        let model = AppModel.preview(.loggedOut, credentials: false, onboarded: false)
        await model.refresh()
        #expect(model.screen == .connect)
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(model.startPhase == .idle)
        #expect(model.screen == .login)
    }

    @Test("Continue with a gateway that is already running reloads it and waits for Telegram")
    func connectReloadsRunningGateway() async throws {
        // A gateway installed from the command line, started before there was a key.
        let model = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let fake = try #require(model.client as? FakeAPIClient)
        await model.refresh()
        #expect(model.screen == .connect)
        #expect(model.authState == .unknown)
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(await fake.reloadCalls == 1)
        // Reloaded in place: nothing was restarted, registered or started.
        #expect(model.daemon.restarts.isEmpty)
        #expect(model.daemon.agentState == .notRegistered)
        #expect(!model.daemon.isForegroundRunning)
        #expect(model.startPhase == .idle)
        #expect(model.authState == .waitPhoneNumber)
        #expect(model.screen == .login)
    }

    @Test("A reload that leaves Telegram disabled keeps Connect up with the reason")
    func connectReloadDisabled() async throws {
        let model = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let fake = try #require(model.client as? FakeAPIClient)
        await fake.setReloadMode(.disabled)
        await model.refresh()
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        guard case .failed(let reason) = model.startPhase else {
            Issue.record("expected a failure, got \(model.startPhase)")
            return
        }
        #expect(reason.contains("without the Telegram key"))
        // Not advanced to sign-in, although the key is saved and the gateway answers.
        #expect(model.config.hasCredentials)
        #expect(model.reachable)
        #expect(model.screen == .connect)
        #expect(model.headline == .init(tone: .failed, phrase: "Telegram didn't start"))
        #expect(model.daemon.restarts.isEmpty)
    }

    @Test("Telegram that never comes up after a reload is a failure, not a silent success")
    func connectReloadStuck() async throws {
        let model = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let fake = try #require(model.client as? FakeAPIClient)
        await fake.setReloadMode(.stuck)
        await model.refresh()
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        guard case .failed(let reason) = model.startPhase else {
            Issue.record("expected a failure, got \(model.startPhase)")
            return
        }
        #expect(reason.contains("Telegram didn't start in it"))
        #expect(model.authState == .unknown)
        #expect(model.screen == .connect)
        // Trying again once the gateway behaves moves on.
        await fake.setReloadMode(.works)
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(model.startPhase == .idle)
        #expect(model.screen == .login)
    }

    @Test("An older gateway without the reload endpoint is restarted instead")
    func connectFallsBackToRestart() async throws {
        let model = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let fake = try #require(model.client as? FakeAPIClient)
        await fake.setReloadMode(.missing)
        model.daemon.previewRestartHook = { await fake.simulateRestarted() }
        await model.refresh()
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(await fake.reloadCalls == 1)
        // Not started by this app, so the gateway installed from the command line is the one.
        #expect(model.daemon.restarts == [.commandLineAgent])
        #expect(model.startPhase == .idle)
        #expect(model.screen == .login)
    }

    @Test("A reload already in progress is waited for; a reload the gateway cannot do becomes a restart")
    func connectReloadBusyAndInternal() async throws {
        let busy = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let busyFake = try #require(busy.client as? FakeAPIClient)
        await busyFake.setReloadMode(.busyOnce)
        await busy.refresh()
        await busy.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(await busyFake.reloadCalls == 2)
        #expect(busy.daemon.restarts.isEmpty)
        #expect(busy.screen == .login)

        let broken = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let brokenFake = try #require(broken.client as? FakeAPIClient)
        await brokenFake.setReloadMode(.internalError)
        broken.daemon.previewRestartHook = { await brokenFake.simulateRestarted() }
        await broken.refresh()
        await broken.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(broken.daemon.restarts == [.commandLineAgent])
        #expect(broken.screen == .login)
    }

    @Test("No reload endpoint and no gateway to restart is reported")
    func connectFallbackWithNothingToRestart() async throws {
        let model = AppModel.preview(.telegramDisabled, credentials: false, onboarded: false)
        let fake = try #require(model.client as? FakeAPIClient)
        await fake.setReloadMode(.missing)
        model.daemon.previewCommandLineAgentInstalled = false
        await model.refresh()
        await model.connect(apiId: 12345, apiHash: "0123456789abcdef0123456789abcdef")
        #expect(model.startPhase == .failed("No running gateway was found to restart."))
        #expect(model.daemon.restarts.isEmpty)
        #expect(model.screen == .connect)
        // Cancel leaves the Connect screen; sign-in then explains that Telegram is not running.
        model.cancelConnect()
        #expect(model.startPhase == .idle)
        #expect(model.screen == .login)
    }

    @Test("Restart acts on whichever gateway is running")
    func restartTargets() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        // Neither started nor registered by this app: the one `tgw daemon install` registered.
        await model.restartGatewayAndWait()
        #expect(model.daemon.restarts == [.commandLineAgent])
        #expect(model.lastError == nil)
        // Registered by this app.
        model.daemon.register(config: model.config)
        await model.restartGatewayAndWait()
        #expect(model.daemon.restarts.last == .appAgent)
        // Running inside this app wins over everything else.
        model.daemon.runInForeground(config: model.config)
        await model.restartGatewayAndWait()
        #expect(model.daemon.restarts == [.commandLineAgent, .appAgent, .child])
        // Nothing of the three.
        model.daemon.stopForeground()
        model.daemon.unregister()
        model.daemon.previewCommandLineAgentInstalled = false
        await model.restartGatewayAndWait()
        #expect(model.daemon.restarts.count == 3)
        #expect(model.lastError == "No running gateway was found to restart.")
        #expect(model.reachable)
    }

    // MARK: Step 2

    @Test("QR sign-in: link, rotation, scan, password; first sign-in lands on Chats")
    func qrLogin() async throws {
        let model = AppModel.preview(.loggedOut, has2FA: true, onboarded: false)
        await model.refresh()
        await model.requestQR()
        #expect(model.authState == .waitQRConfirmation)
        let first = try #require(model.auth?.qrLink)
        #expect(LoginLink.isValid(first))
        await model.requestQR()
        let second = try #require(model.auth?.qrLink)
        #expect(LoginLink.changed(from: first, to: second))

        let fake = try #require(model.client as? FakeAPIClient)
        await fake.simulateQRScanned()
        await model.refreshAuth()
        #expect(model.authState == .waitPassword)
        #expect(model.auth?.passwordHint == "pet")

        await model.submitPassword("wrong")
        #expect(model.loginError == "That password isn't right.")
        #expect(model.authState == .waitPassword)
        await model.submitPassword("hunter2")
        #expect(model.loginError == nil)
        #expect(model.screen == .main)
        #expect(model.section == .chats)
        #expect(model.showsSidebar)
        #expect(!model.onboardingDone)
    }

    @Test("Phone sign-in: phone → code → signed in; a returning user stays on Overview")
    func phoneLogin() async {
        let model = AppModel.preview(.loggedOut, has2FA: false)
        await model.refresh()
        model.loginMode = .phone
        await model.submitPhone("12345")
        #expect(model.loginError != nil)
        await model.submitPhone("+15551234567")
        #expect(model.authState == .waitCode)
        #expect(model.auth?.phoneHint == "+15551234567")
        await model.submitCode("00000")
        #expect(model.loginError != nil)
        await model.submitCode("12345")
        #expect(model.screen == .main)
        #expect(model.section == .overview)
        #expect(model.loginMode == .qr)
        await model.logout()
        #expect(model.screen == .login)
    }

    // MARK: Chats

    @Test("Monitored draft: ticks are local until Save; folders cover their chats")
    func monitoredDraft() async {
        let model = AppModel.preview(.loggedInEmpty, onboarded: false)
        await model.refresh()
        await model.loadChats()
        #expect(model.chats.count == Fixtures.chats.count)
        #expect(!model.isDraftDirty)
        #expect(model.draftEffectiveCount == 0)

        model.setChat("-1001111111111", monitored: true)
        model.setFolder("3", monitored: true)
        #expect(model.isDraftDirty)
        #expect(model.draftChangeCount == 2)
        #expect(model.draftEffectiveCount == 3)
        #expect(model.coveringFolder(for: "-1001987654321")?.title == "Product")
        #expect(model.isChatTicked("-1001987654321"))
        #expect(model.coveringFolder(for: "-1001111111111") == nil)
        #expect(model.monitoredCount == 0)

        model.revertDraft()
        #expect(!model.isDraftDirty)
        #expect(model.draftChangeCount == 0)

        model.setChat("-1001111111111", monitored: true)
        model.setFolder("3", monitored: true)
        let saved = await model.saveDraft()
        #expect(saved)
        #expect(!model.isDraftDirty)
        #expect(Set(model.monitored?.effectiveChatIds ?? []) == ["-1001111111111", "-1001234567890", "-1001987654321"])
        #expect(model.chats.first { $0.id == "-1001987654321" }?.isMonitored == true)
        #expect(model.folders.first { $0.id == "3" }?.isMonitored == true)
        // Choosing chats finishes first-run setup.
        #expect(model.onboardingDone)
        #expect(model.hero.title == "Monitoring 3 chats")
    }

    @Test("A rejected save keeps the draft and reports the error")
    func monitoredSaveFailure() async {
        let model = AppModel.preview(.loggedInEmpty)
        await model.refresh()
        await model.loadChats()
        model.setChat("nope", monitored: true)
        let saved = await model.saveDraft()
        #expect(!saved)
        #expect(model.chatsError != nil)
        #expect(model.isDraftDirty)
    }

    // MARK: Apps

    @Test("Approval starts with what the app asked for")
    func approvalDraft() async throws {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        model.beginApproval(model.requests[0])
        let draft = try #require(model.approval)
        #expect(draft.chatIds == ["-1001234567890", "-1001987654321", "-1003333333333"])
        #expect(draft.scopes == ["messages:read", "history:read", "chats:read"])
        #expect(model.approvalChatIds(draft) == ["-1001234567890", "-1001987654321", "-1003333333333"])
        #expect(model.otherMonitoredCount(draft) == 1)
        #expect(model.approvalSummary(draft) == "3 chats · 3 permissions")
        #expect(model.canApprove(draft))

        model.approval?.showOtherChats = true
        #expect(model.approvalChatIds(try #require(model.approval)).last == "-1001111111111")

        model.approval?.scopes = []
        #expect(!model.canApprove(try #require(model.approval)))
        model.approval?.scopes = ["messages:read"]
        model.approval?.chatIds = []
        #expect(!model.canApprove(try #require(model.approval)))

        model.approval?.followFolder = true
        #expect(!model.canApprove(try #require(model.approval)))
        model.approval?.folderId = "3"
        #expect(model.canApprove(try #require(model.approval)))
        #expect(model.approvalSummary(try #require(model.approval)) == "Product folder · 1 permission")

        model.cancelApproval()
        #expect(model.approval == nil)
        #expect(model.requests.count == 1)
    }

    @Test("Approve monitors a ticked chat that was not monitored, narrows permissions, creates the grant")
    func approve() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        model.beginApproval(model.requests[0])
        model.approval?.chatIds.remove("-1001987654321")
        model.approval?.scopes.remove("history:read")
        let ok = await model.approve()
        #expect(ok)
        #expect(model.approval == nil)
        #expect(model.requests.isEmpty)
        #expect(model.grants.count == 3)
        let grant = model.grants.last
        // The new app is what the Apps section shows next.
        #expect(model.selectedApp == grant.map { .grant($0.id) })
        #expect(grant?.scopes == ["messages:read", "chats:read"])
        #expect(Set(grant?.effectiveChatIds ?? []) == ["-1001234567890", "-1003333333333"])
        #expect(grant?.webhook?.url == "https://analytics.example.com/tgw/events")
        #expect(model.monitored?.chatIds.contains("-1003333333333") == true)
        #expect(model.chatsByID["-1003333333333"]?.isMonitored == true)
    }

    @Test("Approve with a folder grants the folder")
    func approveFolder() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadChats()
        await model.loadAccess()
        model.beginApproval(model.requests[0])
        model.approval?.followFolder = true
        model.approval?.folderId = "3"
        #expect(await model.approve())
        #expect(model.grants.last?.chats.isFolder == true)
        #expect(model.grants.last?.summary == "Product folder · 3 permissions")
        // Nothing new was monitored for a folder grant.
        #expect(model.monitored?.chatIds.contains("-1003333333333") != true)
    }

    @Test("A request for any chats offers every monitored chat")
    func approveAny() async throws {
        let model = AppModel.preview(.loggedInQuiet)
        await model.refresh()
        await model.loadChats()
        let request = AccessRequest(
            requestId: "req_any", status: .pending, name: "Anything", description: "d", scopes: ["messages:read", "messages:send"],
            requestedChats: .any, requestedChatsStatus: nil, webhookUrl: nil, createdAt: Date(), expiresAt: Date().addingTimeInterval(900))
        model.beginApproval(request)
        let draft = try #require(model.approval)
        #expect(draft.chatIds.count == 3)
        #expect(model.approvalChatIds(draft).count == 3)
        #expect(model.otherMonitoredCount(draft) == 0)
        // Sending is pre-ticked like every permission asked for; the owner can untick it.
        #expect(draft.scopes == ["messages:read", "messages:send"])
    }

    @Test("Deny, resume delivery, revoke")
    func denyResumeRevoke() async {
        let model = AppModel.preview(.loggedIn)
        await model.refresh()
        await model.loadAccess()
        await model.deny(model.requests[0])
        #expect(model.requests.isEmpty)
        #expect(model.pendingRequestCount == 0)
        let paused = model.grants.first { $0.webhook?.state == .paused }!
        await model.resumeWebhook(paused)
        #expect(model.grant(id: paused.id)?.webhook?.state == .active)
        #expect(model.needsYou.isEmpty)
        model.selectedApp = .grant(paused.id)
        await model.revoke(paused)
        #expect(model.grants.count == 1)
        #expect(model.selectedApp == nil)
    }

    // MARK: Files

    @Test("Config merge keeps unknown keys and the locator reads config first")
    func configMerge() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tgw-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        try Data(#"{"port": 41415, "events_retention_days": null, "custom": {"a": 1}}"#.utf8).write(to: file)
        setenv("TGW_HOME", directory.path, 1)
        defer { unsetenv("TGW_HOME") }
        let merged = try GatewayConfig.merge(["api_id": 12345, "api_hash": "0123456789abcdef0123456789abcdef", "daemon_path": "/tmp/GatewayDaemon"])
        #expect(merged.hasCredentials)
        #expect(merged.port == 41415)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(raw["events_retention_days"] is NSNull)
        #expect((raw["custom"] as? [String: Any])?["a"] as? Int == 1)
        #expect(raw["port"] as? Int == 41415)
        let reloaded = try GatewayConfig.load()
        #expect(reloaded == merged)
        let resolution = DaemonLocator.resolve(config: reloaded, environment: [:])
        #expect(resolution.candidates.first?.source == "config.json daemon_path")
        #expect(resolution.candidates.first?.url.path == "/tmp/GatewayDaemon")
        #expect(resolution.candidates.contains { $0.source == "app bundle" })
    }

    @Test("Admin token comes from secrets.json; Keychain only when config opts in")
    func adminTokenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tgw-secrets-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "secrets.json")
        #expect(try AdminToken.readFile(at: file) == nil)
        try Data(#"{"admin-token": " tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV\n", "other": 1}"#.utf8).write(to: file)
        #expect(try AdminToken.readFile(at: file) == "tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV")
        // The gateway writes base64 of the UTF-8 token.
        let base64 = Data("tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV".utf8).base64EncodedString()
        try Data(#"{"admin-token": "\#(base64)", "tdlib-db-key": "AAAA"}"#.utf8).write(to: file)
        #expect(try AdminToken.readFile(at: file) == "tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV")
        try Data(#"{"other": 1}"#.utf8).write(to: file)
        #expect(try AdminToken.readFile(at: file) == nil)
        try Data("[]".utf8).write(to: file)
        #expect(throws: AdminToken.ReadError.self) { try AdminToken.readFile(at: file) }
        #expect(GatewayConfig().secretsSource == .file)
        #expect(GatewayConfig(raw: ["secrets": "keychain"]).secretsSource == .keychain)
        #expect(GatewayConfig(raw: ["secrets": "vault"]).secretsSource == .file)
        // The model's file path: TGW_HOME points the read at the scratch directory (no SecItem).
        setenv("TGW_HOME", directory.path, 1)
        defer { unsetenv("TGW_HOME") }
        try Data(#"{"admin-token": "tgw_fromfile"}"#.utf8).write(to: file)
        #expect(try AdminToken.read(config: GatewayConfig()) == "tgw_fromfile")
    }

    @Test("Key validation")
    func credentials() {
        #expect(!GatewayConfig(apiId: nil, apiHash: nil).hasCredentials)
        #expect(!GatewayConfig(apiId: 0, apiHash: "0123456789abcdef0123456789abcdef").hasCredentials)
        #expect(!GatewayConfig(apiId: 1, apiHash: "short").hasCredentials)
        #expect(!GatewayConfig(apiId: 1, apiHash: "0123456789abcdef0123456789abcdeg").hasCredentials)
        #expect(GatewayConfig(apiId: 1, apiHash: "0123456789ABCDEF0123456789abcdef").hasCredentials)
        #expect(GatewayConfig(raw: ["api_id": "42", "api_hash": "0123456789abcdef0123456789abcdef"]).apiId == 42)
    }
}
