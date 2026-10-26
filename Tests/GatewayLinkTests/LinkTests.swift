import Foundation
import GatewayCore
@testable import GatewayLink
import GatewayServer
import GatewayTestSupport
import Logging
import TDLibClient
import Testing

/// A gateway without a socket: store, event log, the fake Telegram, and the API router that
/// link requests run through.
struct Gateway {
    static let adminToken = "tgw_" + String(repeating: "A", count: 43)
    static let linkToken = "vgl_" + String(repeating: "b", count: 43)
    static let timing: LinkTiming = {
        var timing = LinkTiming()
        timing.initialBackoff = .milliseconds(50)
        timing.maxBackoff = .milliseconds(200)
        timing.stableAfter = .seconds(30)
        timing.authPollInterval = .milliseconds(50)
        return timing
    }()

    let store: Store
    let clock: ManualClock
    let telegram: FakeTelegram
    let deps: Dependencies
    let api: InProcessAPI

    init(state: AuthState? = .ready) async throws {
        store = try Store.inMemory()
        clock = ManualClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        let tdlib = FakeTDLib()
        await Fixtures.populate(tdlib)
        telegram = FakeTelegram(state: state, tdlib: tdlib)
        await telegram.set(account: AccountInfo(userId: 987_654_321, displayName: "Ada Lovelace", username: "ada", phoneLast4: "4567", phoneNumber: "+15551234567"))
        let translator = Translator(tdlib: tdlib)
        let eventLog = EventLog(store: store, clock: clock)
        let grants = Grants(store: store, adminToken: Gateway.adminToken, clock: clock)
        let monitor = Monitor(store: store, eventLog: eventLog, translator: translator, tdlib: tdlib, clock: clock)
        try await monitor.load()
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        deps = Dependencies(
            store: store, eventLog: eventLog, grants: grants,
            accessRequests: AccessRequests(store: store, grants: grants, clock: clock), monitor: monitor, translator: translator,
            mediaCache: MediaCache(store: store, tdlib: tdlib, maxBytes: 1 << 30, clock: clock), dispatcher: nil,
            telegram: telegram, rateLimiter: RateLimiter(clock: clock), clock: clock, config: Config(), startedAt: clock.now, logger: logger
        )
        api = InProcessAPI(deps: deps, adminToken: Gateway.adminToken)
    }

    func client(_ volgenic: FakeVolgenic, token: String = Gateway.linkToken) throws -> GatewayLinkClient {
        try client(baseURL: volgenic.baseURL, token: token)
    }

    func client(baseURL: String, token: String = Gateway.linkToken) throws -> GatewayLinkClient {
        var logger = Logger(label: "link")
        logger.logLevel = .critical
        return try GatewayLinkClient(
            baseURL: baseURL, token: token, transport: URLSessionLinkTransport(), handler: api, eventLog: deps.eventLog,
            telegram: telegram, version: "0.1.0", timing: Gateway.timing, logger: logger
        )
    }

    @discardableResult
    func append(id: Int64, text: String = "hi") async throws -> Int64 {
        let chat = ChatSummary(id: Fixtures.channelId, type: .channel, title: "Acme Product Updates", username: "acmeupdates")
        let message = Message(
            id: id, chatId: Fixtures.channelId, sender: Sender(type: .chat, id: Fixtures.channelId, displayName: "Acme Product Updates", username: "acmeupdates", isBot: nil),
            date: clock.now, editDate: nil, isOutgoing: false, text: text, entities: [], replyTo: nil, forwardFrom: nil,
            media: [], mediaGroupId: nil, link: nil, rawContentType: "messageText"
        )
        return try await deps.eventLog.append(Event(type: .messageNew, occurredAt: clock.now, recordedAt: clock.now, chat: chat, payload: .message(message)))
    }
}

/// Waits (real time, bounded) until `condition` holds.
func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now > deadline { throw FakeError("timed out waiting until \(what)") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Runs `body` with a fake Volgenic and a link to it, and tears both down.
func withLink(
    _ gateway: Gateway, _ body: (FakeVolgenic, GatewayLinkClient) async throws -> Void
) async throws {
    let volgenic = try await FakeVolgenic(token: Gateway.linkToken)
    let client = try gateway.client(volgenic)
    await client.start()
    do {
        try await body(volgenic, client)
    } catch {
        await client.stop()
        await volgenic.stop()
        throw error
    }
    await client.stop()
    await volgenic.stop()
}

@Suite("Link to Volgenic")
struct LinkTests {
    @Test func helloOnConnect() async throws {
        let gateway = try await Gateway()
        try await gateway.append(id: 1)
        try await withLink(gateway) { volgenic, client in
            let connection = try await volgenic.connection(0)
            #expect(connection.authorization == "Bearer \(Gateway.linkToken)")
            let hello = try await connection.next()
            #expect(hello["type"] == "hello")
            #expect(hello["protocol"] == 1)
            #expect(hello["gateway_version"] == "0.1.0")
            #expect(hello["auth_state"] == "ready")
            #expect(hello["head_seq"] == 1)
            #expect(hello["account"] == ["id": "987654321", "name": "Ada Lovelace", "username": "ada", "phone": "+15551234567"])
            try await eventually("connected") { await client.currentStatus().state == .connected }
        }
    }

    @Test func helloBeforeSignInHasNoAccount() async throws {
        let gateway = try await Gateway(state: .waitPhoneNumber)
        try await withLink(gateway) { volgenic, _ in
            let hello = try await volgenic.connection(0).next()
            #expect(hello["auth_state"] == "wait_phone_number")
            #expect(hello["account"] == .null)
        }
    }

    @Test func requestIsAnsweredWithTheAdminAPIsStatusAndBody() async throws {
        let gateway = try await Gateway(state: .waitPhoneNumber)
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")

            try await connection.send(["type": "request", "id": "r-1", "method": "POST", "path": "/v1/admin/auth/phone", "body": ["phone_number": "+15551234567"]])
            let signIn = try await connection.next(ofType: "response")
            #expect(signIn["id"] == "r-1")
            #expect(signIn["status"] == 200)
            #expect(signIn["body"]?["auth_state"] == "wait_code")
            #expect(await gateway.telegram.calls.contains("phone:+15551234567"))

            // The same call, in process, gives the same answer.
            let direct = await gateway.api.perform(LinkHTTPRequest(method: "GET", path: "/v1/admin/monitored-chats"), maxBodyBytes: 1 << 20)
            try await connection.send(["type": "request", "id": "r-2", "method": "GET", "path": "/v1/admin/monitored-chats"])
            let monitored = try await connection.next(ofType: "response")
            #expect(monitored["status"] == .number(Double(direct.status)))
            #expect(monitored["body"] == (try JSONValue.parse(direct.body)))

            // Errors pass through with their status and body.
            try await connection.send(["type": "request", "id": "r-3", "method": "POST", "path": "/v1/admin/auth/code", "body": ["code": "000"]])
            let wrong = try await connection.next(ofType: "response")
            #expect(wrong["status"] == 400)
            #expect(wrong["body"]?["error"]?["reason"] == nil)
            #expect(wrong["body"]?["error"]?["details"]?["reason"] == "wrong_code")

            // Query parameters reach the route.
            try await connection.send(["type": "request", "id": "r-4", "method": "GET", "path": "/v1/events", "query": ["since": "0", "limit": "5000"]])
            let invalid = try await connection.next(ofType: "response")
            #expect(invalid["status"] == 400)
            #expect(invalid["body"]?["error"]?["details"]?["field"] == "limit")
        }
    }

    @Test func requestsRunConcurrentlyAndAreCorrelatedById() async throws {
        let gateway = try await Gateway()
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            for i in 0..<10 {
                try await connection.send(["type": "request", "id": .string("r-\(i)"), "method": "GET", "path": "/v1/admin/auth"])
            }
            var ids: Set<String> = []
            for _ in 0..<10 {
                let response = try await connection.next(ofType: "response")
                #expect(response["status"] == 200)
                ids.insert(response["id"]?.stringValue ?? "")
            }
            #expect(ids == Set((0..<10).map { "r-\($0)" }))
        }
    }

    @Test func forbiddenPathsAreRefused() async throws {
        let gateway = try await Gateway()
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            let paths = [
                "/health", "/v2/admin/status", "/v1/admin/secrets", "/v1/admin/secrets/admin-token", "/v1/admin/tokens",
                "/v1/admin/tokens/regenerate", "/v1/admin/links", "/v1/../v1/admin/secrets", "/v1/admin/%73ecrets", "/v1/admin/status?x=1",
            ]
            for (i, path) in paths.enumerated() {
                try await connection.send(["type": "request", "id": .string("f-\(i)"), "method": "GET", "path": .string(path)])
                let response = try await connection.next(ofType: "response")
                #expect(response["id"] == .string("f-\(i)"))
                #expect(response["status"] == 403, "\(path)")
                #expect(response["body"]?["error"]?["code"] == "forbidden_over_link", "\(path)")
            }
        }
    }

    @Test func policyAllowsTheEndpointsVolgenicUses() {
        for path in ["/v1/admin/auth", "/v1/admin/auth/qr", "/v1/admin/chats", "/v1/admin/folders", "/v1/admin/monitored-chats", "/v1/chats/-1001234567890/messages", "/v1/media/med_abc", "/v1/admin/status"] {
            #expect(LinkPolicy.check(method: "GET", path: path) == nil, "\(path)")
        }
        #expect(LinkPolicy.check(method: "GET", path: "/v1/events/stream")?.code == "invalid_request")
        #expect(LinkPolicy.check(method: "TRACE", path: "/v1/admin/auth")?.code == "invalid_request")
    }

    @Test func largeAndBinaryBodies() async throws {
        let gateway = try await Gateway()
        let tooLarge = await gateway.api.perform(LinkHTTPRequest(method: "GET", path: "/v1/admin/status"), maxBodyBytes: 16)
        #expect(tooLarge.status == 413)
        #expect(try JSONValue.parse(tooLarge.body)["error"]?["code"] == "too_large")

        let binary = LinkHTTPResponse(status: 200, contentType: "image/jpeg", body: Data([0xFF, 0xD8, 0xFF]))
        let frame = LinkFrames.response(id: "m-1", binary)
        #expect(frame["content_type"] == "image/jpeg")
        #expect(frame["body_base64"] == "/9j/")
        #expect(frame["body"] == nil)
        #expect(LinkFrames.response(id: "n", LinkHTTPResponse(status: 204, contentType: nil, body: Data()))["body"] == .null)
    }

    @Test func subscribeStreamsTheBacklogThenLive() async throws {
        let gateway = try await Gateway()
        for id in 1...3 { try await gateway.append(id: Int64(id)) }
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            try await connection.send(["type": "subscribe", "since": 1])
            #expect(try await connection.next(ofType: "event")["event"]?["seq"] == 2)
            #expect(try await connection.next(ofType: "event")["event"]?["seq"] == 3)
            try await gateway.append(id: 4, text: "live")
            let live = try await connection.next(ofType: "event")
            #expect(live["event"]?["seq"] == 4)
            #expect(live["event"]?["message"]?["text"] == "live")
        }
    }

    @Test func subscribeBelowTheRetainedLogSendsGapFirst() async throws {
        let gateway = try await Gateway()
        for id in 1...5 { try await gateway.append(id: Int64(id)) }
        _ = try await gateway.deps.eventLog.prune(beforeSeq: 4)
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            try await connection.send(["type": "subscribe", "since": 1])
            let gap = try await connection.next()
            #expect(gap == ["type": "gap", "oldest_seq": 4])
            #expect(try await connection.next()["event"]?["seq"] == 4)
            #expect(try await connection.next()["event"]?["seq"] == 5)
        }
    }

    @Test func aNewSubscribeReplacesTheOldOne() async throws {
        let gateway = try await Gateway()
        for id in 1...3 { try await gateway.append(id: Int64(id)) }
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            try await connection.send(["type": "subscribe", "since": 2])
            #expect(try await connection.next(ofType: "event")["event"]?["seq"] == 3)
            try await connection.send(["type": "subscribe", "since": 0])
            for seq in 1...3 { #expect(try await connection.next(ofType: "event")["event"]?["seq"] == .number(Double(seq))) }
            try await gateway.append(id: 4)
            #expect(try await connection.next(ofType: "event")["event"]?["seq"] == 4)
            try await Task.sleep(for: .milliseconds(200))
            #expect(connection.unread.isEmpty, "each event once, from the current subscription only")
        }
    }

    @Test func authStateIsPushedWhenItChanges() async throws {
        let gateway = try await Gateway(state: .waitPhoneNumber)
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            await gateway.telegram.set(state: .waitCode)
            #expect(try await connection.next(ofType: "auth_state") == ["type": "auth_state", "auth_state": "wait_code", "account": nil])
            await gateway.telegram.set(state: .ready)
            let ready = try await connection.next(ofType: "auth_state")
            #expect(ready["auth_state"] == "ready")
            #expect(ready["account"]?["username"] == "ada")
        }
    }

    @Test func unauthorizedStopsRetrying() async throws {
        let gateway = try await Gateway()
        let volgenic = try await RefusingVolgenic()
        let client = try gateway.client(baseURL: volgenic.baseURL)
        await client.start()
        try await eventually("refused") { await client.currentStatus().state == .unauthorized }
        #expect(volgenic.attempts == 1)
        try await Task.sleep(for: .milliseconds(500)) // several backoff periods
        #expect(volgenic.attempts == 1)
        #expect(await client.currentStatus().lastError?.contains("401") == true)
        await client.stop()
        await volgenic.stop()
    }

    @Test func closeCode4401StopsRetrying() async throws {
        let gateway = try await Gateway()
        try await withLink(gateway) { volgenic, client in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            try await connection.close(code: 4401)
            try await eventually("revoked") { await client.currentStatus().state == .unauthorized }
            try await Task.sleep(for: .milliseconds(500))
            #expect(volgenic.connectionCount == 1)
            #expect(await client.currentStatus().lastError?.contains("4401") == true)
        }
    }

    @Test func reconnectsAfterADropAndResubscribesFromVolgenicsSince() async throws {
        let gateway = try await Gateway()
        for id in 1...3 { try await gateway.append(id: Int64(id)) }
        try await withLink(gateway) { volgenic, client in
            let first = try await volgenic.connection(0)
            _ = try await first.next(ofType: "hello")
            try await first.send(["type": "subscribe", "since": 0])
            for seq in 1...3 { #expect(try await first.next(ofType: "event")["event"]?["seq"] == .number(Double(seq))) }

            try await first.close(code: 1001) // Volgenic restarts
            try await gateway.append(id: 4) // recorded while the link is down
            let second = try await volgenic.connection(1)
            let hello = try await second.next()
            #expect(hello["type"] == "hello")
            #expect(hello["head_seq"] == 4)
            try await eventually("connected again") { await client.currentStatus().state == .connected }
            #expect(await client.currentStatus().lastError != nil)

            // Volgenic processed up to 2 before the drop, so it subscribes from 2.
            try await second.send(["type": "subscribe", "since": 2])
            #expect(try await second.next(ofType: "event")["event"]?["seq"] == 3)
            #expect(try await second.next(ofType: "event")["event"]?["seq"] == 4)
            try await gateway.append(id: 5)
            #expect(try await second.next(ofType: "event")["event"]?["seq"] == 5)
            #expect(first.unread.allSatisfy { $0["event"]?["seq"] != 5 })
        }
    }

    @Test func retriesWhileVolgenicIsUnreachable() async throws {
        let gateway = try await Gateway()
        let volgenic = try await FakeVolgenic(token: Gateway.linkToken)
        let client = try gateway.client(volgenic)
        await volgenic.stop() // nothing listens on the port now
        await client.start()
        try await eventually("waiting to retry") {
            let status = await client.currentStatus()
            return status.state == .waiting && status.lastError != nil && status.retryAt != nil
        }
        await client.stop()
        #expect(await client.currentStatus().state == .stopped)
    }

    @Test func malformedFramesGetAnErrorFrame() async throws {
        let gateway = try await Gateway()
        try await withLink(gateway) { volgenic, _ in
            let connection = try await volgenic.connection(0)
            _ = try await connection.next(ofType: "hello")
            try await connection.send(["type": "subscribe"])
            #expect(try await connection.next(ofType: "error")["code"] == "invalid_request")
            try await connection.send(["type": "request", "method": "GET", "path": "/v1/admin/auth"])
            #expect(try await connection.next(ofType: "error")["code"] == "invalid_request")
            try await connection.send(["type": "something_new"]) // ignored
            try await connection.send(["type": "request", "id": "ok", "method": "GET", "path": "/v1/admin/auth"])
            #expect(try await connection.next(ofType: "response")["id"] == "ok")
        }
    }
}

@Suite("Link settings and manager")
struct LinkSettingsTests {
    func temporaryPaths() throws -> Paths {
        let home = FileManager.default.temporaryDirectory.appending(path: "tgw-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return Paths(home: home)
    }

    @Test func normalisesBaseURLsAndBuildsTheEndpoint() throws {
        #expect(try LinkSettings.normalize("HTTPS://Volgenic.com/") == "https://volgenic.com")
        #expect(try LinkSettings.normalize(" http://localhost:4100 ") == "http://localhost:4100")
        #expect(try LinkSettings.endpoint(for: "https://volgenic.com").absoluteString == "wss://volgenic.com/messages/telegram/link")
        #expect(try LinkSettings.endpoint(for: "http://localhost:4100").absoluteString == "ws://localhost:4100/messages/telegram/link")
        #expect(try LinkSettings.endpoint(for: "https://example.com/app/").absoluteString == "wss://example.com/app/messages/telegram/link")
        #expect(throws: GatewayError.self) { try LinkSettings.normalize("ftp://volgenic.com") }
        #expect(throws: GatewayError.self) { try LinkSettings.normalize("https://volgenic.com/?x=1") }
        #expect(throws: GatewayError.self) { try LinkSettings.normalize("volgenic.com") }
        #expect(LinkSettings.isValidToken(Gateway.linkToken))
        #expect(!LinkSettings.isValidToken("vgl_short"))
        #expect(!LinkSettings.isValidToken(Gateway.adminToken))
    }

    @Test func addAndRemoveKeepOtherConfigKeys() throws {
        let paths = try temporaryPaths()
        try #"{"port": 41499, "daemon_path": "/x/GatewayDaemon", "api_id": 1, "api_hash": "abc"}"#.write(to: paths.config, atomically: true, encoding: .utf8)
        let secrets = InMemorySecretStore()
        let added = try LinkSettings.add(baseURL: "https://Volgenic.com/", token: Gateway.linkToken, paths: paths, secrets: secrets)
        #expect(added == ("https://volgenic.com", false) )
        #expect(try LinkSettings.add(baseURL: "https://volgenic.com", token: Gateway.linkToken, paths: paths, secrets: secrets).replaced)
        try LinkSettings.add(baseURL: "http://localhost:4100", token: Gateway.linkToken, paths: paths, secrets: secrets)
        var config = try Config.load(paths: paths, environment: [:])
        #expect(config.links == [LinkConfig(baseURL: "https://volgenic.com"), LinkConfig(baseURL: "http://localhost:4100")])
        #expect(config.port == 41499 && config.apiHash == "abc")
        #expect(try LinkSettings.token(for: "https://volgenic.com", secrets: secrets) == Gateway.linkToken)
        let raw = try JSONValue.parse(Data(contentsOf: paths.config))
        #expect(raw["daemon_path"] == "/x/GatewayDaemon")

        #expect(try LinkSettings.remove(baseURL: "https://volgenic.com", paths: paths, secrets: secrets))
        #expect(try !LinkSettings.remove(baseURL: "https://volgenic.com", paths: paths, secrets: secrets))
        config = try Config.load(paths: paths, environment: [:])
        #expect(config.links == [LinkConfig(baseURL: "http://localhost:4100")])
        #expect(try LinkSettings.token(for: "https://volgenic.com", secrets: secrets) == nil)
        #expect(throws: GatewayError.self) { try LinkSettings.add(baseURL: "https://volgenic.com", token: "nope", paths: paths, secrets: secrets) }
    }

    @Test func managerRunsIndependentLinksAndReloadsInPlace() async throws {
        let gateway = try await Gateway()
        let one = try await FakeVolgenic(token: Gateway.linkToken)
        let otherToken = "vgl_" + String(repeating: "c", count: 43)
        let newToken = "vgl_" + String(repeating: "d", count: 43)
        let two = try await FakeVolgenic(tokens: [otherToken, newToken])
        let secrets = InMemorySecretStore()
        try secrets.write(LinkSettings.secretAccount(for: one.baseURL), Data(Gateway.linkToken.utf8))
        try secrets.write(LinkSettings.secretAccount(for: two.baseURL), Data(otherToken.utf8))
        var logger = Logger(label: "link")
        logger.logLevel = .critical
        let manager = LinkManager(secrets: secrets, eventLog: gateway.deps.eventLog, telegram: gateway.telegram, version: "0.1.0", timing: Gateway.timing, logger: logger)
        await manager.setHandler(gateway.api)

        let missing = "http://127.0.0.1:9"
        let summary = await manager.apply([LinkConfig(baseURL: one.baseURL), LinkConfig(baseURL: two.baseURL), LinkConfig(baseURL: missing)])
        #expect(summary.started == [one.baseURL, two.baseURL])
        _ = try await one.connection(0).next(ofType: "hello")
        _ = try await two.connection(0).next(ofType: "hello")
        let statuses = await manager.statuses()
        #expect(statuses.map(\.baseURL) == [one.baseURL, two.baseURL, missing])
        #expect(statuses.last?.state == .noToken)

        // The same configuration again changes nothing.
        #expect(await manager.apply([LinkConfig(baseURL: one.baseURL), LinkConfig(baseURL: two.baseURL)]).unchanged == [one.baseURL, two.baseURL])

        // Dropping one link leaves the other connected.
        let after = await manager.apply([LinkConfig(baseURL: two.baseURL)])
        #expect(after.stopped == [one.baseURL])
        try await eventually("link one closed") { try await one.connection(0).isClosed }
        let connection = try await two.connection(0)
        try await connection.send(["type": "request", "id": "still", "method": "GET", "path": "/v1/admin/auth"])
        #expect(try await connection.next(ofType: "response")["status"] == 200)
        #expect(two.connectionCount == 1)

        // A new token restarts that link, which connects again with it.
        try secrets.write(LinkSettings.secretAccount(for: two.baseURL), Data(newToken.utf8))
        #expect(await manager.apply([LinkConfig(baseURL: two.baseURL)]).restarted == [two.baseURL])
        let again = try await two.connection(1)
        #expect(again.authorization == "Bearer \(newToken)")
        _ = try await again.next(ofType: "hello")

        await manager.shutdown()
        await one.stop()
        await two.stop()
    }

    @Test func reloadAppliesLinksFromConfig() async throws {
        let paths = try temporaryPaths()
        let gateway = try await Gateway()
        let volgenic = try await FakeVolgenic(token: Gateway.linkToken)
        let secrets = InMemorySecretStore()
        var logger = Logger(label: "link")
        logger.logLevel = .critical
        let manager = LinkManager(secrets: secrets, eventLog: gateway.deps.eventLog, telegram: gateway.telegram, version: "0.1.0", timing: Gateway.timing, logger: logger)
        await manager.setHandler(gateway.api)
        let host = TelegramHost(factory: FakeSessionLedger().factory())
        let reloader = ConfigReloader(paths: paths, running: Config(), host: host, links: manager, environment: [:])

        try LinkSettings.add(baseURL: volgenic.baseURL, token: Gateway.linkToken, paths: paths, secrets: secrets)
        let result = try await reloader.reload()
        #expect(result.links?.started == [volgenic.baseURL])
        #expect(result.restartRequired.isEmpty)
        #expect(result.json["links"]?["started"] == [.string(volgenic.baseURL)])
        _ = try await volgenic.connection(0).next(ofType: "hello")

        try LinkSettings.remove(baseURL: volgenic.baseURL, paths: paths, secrets: secrets)
        #expect(try await reloader.reload().links?.stopped == [volgenic.baseURL])
        #expect(await manager.statuses().isEmpty)
        await manager.shutdown()
        await host.shutdown()
        await volgenic.stop()
    }
}
