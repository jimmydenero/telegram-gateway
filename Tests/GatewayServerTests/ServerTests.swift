import Foundation
import GatewayCore
import GatewayServer
import GatewayTestSupport
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import Logging
import NIOCore
import TDLibClient
import Testing
import WSCore

/// The server over an in-memory store, a fake TDLib and a fake Telegram session.
struct App {
    static let adminToken = "tgw_" + String(repeating: "Z", count: 43)
    let store: Store
    let clock: ManualClock
    let tdlib: FakeTDLib
    let telegram: FakeTelegram
    let deps: Dependencies
    let application: Application<RouterResponder<GatewayRequestContext>>

    init(config: Config = Config(), maxMediaBytes: Int64 = 1 << 30) async throws {
        store = try Store.inMemory()
        clock = ManualClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        tdlib = FakeTDLib()
        await Fixtures.populate(tdlib)
        telegram = FakeTelegram(state: .ready, tdlib: tdlib)
        let translator = Translator(tdlib: tdlib)
        let eventLog = EventLog(store: store, clock: clock)
        let grants = Grants(store: store, adminToken: App.adminToken, clock: clock)
        let monitor = Monitor(store: store, eventLog: eventLog, translator: translator, tdlib: tdlib, clock: clock)
        try await monitor.load()
        var logger = Logger(label: "test")
        logger.logLevel = .error
        deps = Dependencies(
            store: store, eventLog: eventLog, grants: grants,
            accessRequests: AccessRequests(store: store, grants: grants, clock: clock), monitor: monitor, translator: translator,
            mediaCache: MediaCache(store: store, tdlib: tdlib, maxBytes: maxMediaBytes, clock: clock), dispatcher: nil,
            telegram: telegram, rateLimiter: RateLimiter(clock: clock), clock: clock, config: config, startedAt: clock.now, logger: logger
        )
        application = GatewayServer.buildApplication(deps: deps, port: 0, logger: logger)
    }

    func monitorDefaults() async throws {
        try await deps.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.channelId, Fixtures.groupId]))
    }

    func makeGrant(scopes: [Scope] = [.messagesRead, .chatsRead], chats: GrantChats = .list([Fixtures.channelId]), webhook: String? = nil) async throws -> (Grant, String) {
        let issued = try await deps.grants.create(name: "App", description: "Test app", scopes: scopes, chats: chats, webhookUrl: webhook)
        return (issued.grant, issued.token)
    }

    func appendMessage(chatId: Int64 = Fixtures.channelId, id: Int64, text: String = "hi") async throws -> Int64 {
        let chat = ChatSummary(id: chatId, type: .channel, title: "Acme Product Updates", username: "acmeupdates")
        let message = Message(
            id: id, chatId: chatId, sender: Sender(type: .chat, id: chatId, displayName: "Acme Product Updates", username: "acmeupdates", isBot: nil),
            date: clock.now, editDate: nil, isOutgoing: false, text: text, entities: [], replyTo: nil, forwardFrom: nil,
            media: [], mediaGroupId: nil, link: nil, rawContentType: "messageText"
        )
        return try await deps.eventLog.append(Event(type: .messageNew, occurredAt: clock.now, recordedAt: clock.now, chat: chat, payload: .message(message)))
    }
}

struct Reply {
    let status: Int
    let headers: HTTPFields
    let json: JSONValue
    let data: Data

    var code: String? { json["error"]?["code"]?.stringValue }
}

extension TestClientProtocol {
    func call(_ method: HTTPRequest.Method, _ uri: String, token: String? = nil, body: JSONValue? = nil, headers extra: [(HTTPField.Name, String)] = []) async throws -> Reply {
        var headers = HTTPFields()
        if let token { headers[.authorization] = "Bearer \(token)" }
        for (name, value) in extra { headers[name] = value }
        var buffer: ByteBuffer?
        if let body {
            headers[.contentType] = "application/json; charset=utf-8"
            buffer = ByteBuffer(bytes: body.serialized())
        }
        return try await execute(uri: uri, method: method, headers: headers, body: buffer) { response in
            let data = Data(response.body.readableBytesView)
            let json = (try? JSONValue.parse(data)) ?? .null
            return Reply(status: Int(response.status.code), headers: response.headers, json: json, data: data)
        }
    }
}

@Suite struct HealthAndAuthTests {
    @Test func healthIsOpenAndReportsState() async throws {
        let app = try await App()
        try await app.application.test(.router) { client in
            let ok = try await client.call(.get, "/v1/health")
            #expect(ok.status == 200 && ok.json["status"] == "ok" && ok.json["head_seq"] == 0 && ok.json["version"] == "0.1.0")
            #expect(ok.json["tdlib"] == ["auth_state": "ready", "connection_state": "ready"])
            #expect(ok.headers[.requestId] != nil)
            #expect(ok.headers[.contentType] == "application/json; charset=utf-8")
            await app.telegram.set(state: .waitPhoneNumber)
            let degraded = try await client.call(.get, "/v1/health")
            #expect(degraded.status == 200 && degraded.json["status"] == "degraded" && degraded.json["tdlib"]?["auth_state"] == "wait_phone_number")
        }
    }

    @Test func authenticationErrors() async throws {
        let app = try await App()
        let (grant, token) = try await app.makeGrant()
        try await app.application.test(.router) { client in
            #expect(try await client.call(.get, "/v1/me").code == "missing_token")
            #expect(try await client.call(.get, "/v1/me", headers: [(.authorization, "Basic abc")]).code == "missing_token")
            #expect(try await client.call(.get, "/v1/me", token: "tgw_short").code == "invalid_token")
            #expect(try await client.call(.get, "/v1/me", token: "tgw_" + String(repeating: "Q", count: 43)).code == "invalid_token")
            let admin = try await client.call(.get, "/v1/admin/status", token: token)
            #expect(admin.status == 403 && admin.code == "admin_only")
            let me = try await client.call(.get, "/v1/me", token: token)
            #expect(me.status == 200 && me.json["grant"]?["id"] == .string(grant.id))
            #expect(me.headers[.rateLimitLimit] == "600" && me.headers[.rateLimitRemaining] == "598")
            let adminMe = try await client.call(.get, "/v1/me", token: App.adminToken)
            #expect(adminMe.json["grant"]?["id"] == "grant_admin")
            try await app.deps.grants.revoke(grant.id)
            let revoked = try await client.call(.get, "/v1/me", token: token)
            #expect(revoked.status == 401 && revoked.code == "token_revoked" && revoked.json["error"]?["details"]?["revoked_at"] != nil)
            let missing = try await client.call(.get, "/v1/nope", token: App.adminToken)
            #expect(missing.status == 404 && missing.code == "not_found")
            let big = try await client.call(.post, "/v1/access-requests", body: ["name": .string(String(repeating: "x", count: 70_000))])
            #expect(big.status == 413 && big.code == "payload_too_large")
        }
    }

    @Test func perTokenRateLimit() async throws {
        let app = try await App()
        let (_, token) = try await app.makeGrant()
        try await app.application.test(.router) { client in
            for _ in 0..<600 { _ = try await client.call(.get, "/v1/me", token: token) }
            let limited = try await client.call(.get, "/v1/me", token: token)
            #expect(limited.status == 429 && limited.code == "rate_limited")
            #expect(limited.headers[.retryAfter] == "60" && limited.json["error"]?["details"]?["retry_after"] == 60)
            #expect(limited.headers[.rateLimitRemaining] == "0")
            app.clock.advance(by: .seconds(60))
            #expect(try await client.call(.get, "/v1/me", token: token).status == 200)
        }
    }
}

@Suite struct AccessRequestFlowTests {
    @Test func endToEnd() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        try await app.application.test(.router) { client in
            let body: JSONValue = [
                "name": "Community Analytics", "description": "Counts topics.",
                "scopes": ["messages:read", "history:read", "chats:read"],
                "requested_chats": [.id(Fixtures.channelId), .id(Fixtures.privateChatId)],
                "webhook": ["url": "https://analytics.example.com/tgw/events"],
            ]
            let created = try await client.call(.post, "/v1/access-requests", body: body)
            #expect(created.status == 201 && created.json["status"] == "pending")
            let id = try #require(created.json["request_id"]?.stringValue)
            #expect(created.json["poll_url"] == .string("http://127.0.0.1:41414/v1/access-requests/\(id)"))

            let pending = try await client.call(.get, "/v1/access-requests/\(id)")
            #expect(pending.status == 200 && pending.json["status"] == "pending")
            let tooFast = try await client.call(.get, "/v1/access-requests/\(id)")
            #expect(tooFast.status == 429 && tooFast.headers[.retryAfter] == "2")
            app.clock.advance(by: .seconds(3))

            let list = try await client.call(.get, "/v1/admin/access-requests", token: App.adminToken)
            #expect(list.json["access_requests"]?[0]?["request_id"] == .string(id))
            #expect(list.json["access_requests"]?[0]?["requested_chats_status"]?[1]?["is_monitored"] == false)

            let bad = try await client.call(.post, "/v1/admin/access-requests/\(id)/approve", token: App.adminToken, body: ["chat_ids": [.id(Fixtures.privateChatId)]])
            #expect(bad.status == 400 && bad.code == "chat_not_monitored" && bad.json["error"]?["details"]?["chat_id"] == .id(Fixtures.privateChatId))
            let both = try await client.call(.post, "/v1/admin/access-requests/\(id)/approve", token: App.adminToken, body: ["chat_ids": [], "folder_id": "3"])
            #expect(both.status == 400 && both.code == "invalid_request")
            let approved = try await client.call(.post, "/v1/admin/access-requests/\(id)/approve", token: App.adminToken, body: ["chat_ids": [.id(Fixtures.channelId)], "scopes": ["messages:read", "chats:read"]])
            #expect(approved.status == 200 && approved.json["scopes"] == ["chats:read", "messages:read"])
            #expect(approved.json.objectValue?["token"] == nil)
            let grantId = try #require(approved.json["id"]?.stringValue)

            let poll = try await client.call(.get, "/v1/access-requests/\(id)")
            #expect(poll.json["status"] == "approved" && poll.json["grant"]?["id"] == .string(grantId))
            let token = try #require(poll.json["token"]?.stringValue)
            #expect(poll.json["webhook"]?["secret"]?.stringValue?.hasPrefix("whsec_") == true)

            let me = try await client.call(.get, "/v1/me", token: token)
            #expect(me.json["grant"]?["effective_chat_ids"] == [.id(Fixtures.channelId)])
            #expect(me.json["grant"]?["webhook"]?["state"] == "active")
            let chats = try await client.call(.get, "/v1/chats", token: token)
            #expect(chats.json["chats"]?[0]?["id"] == .id(Fixtures.channelId) && chats.json["chats"]?[0]?["is_monitored"] == true)
            let history = try await client.call(.get, "/v1/chats/\(Fixtures.channelId)/messages", token: token)
            #expect(history.status == 403 && history.code == "insufficient_scope" && history.json["error"]?["details"]?["required"] == "history:read")
            let other = try await client.call(.get, "/v1/chats/\(Fixtures.groupId)", token: token)
            #expect(other.status == 403 && other.code == "chat_not_granted")

            let again = try await client.call(.post, "/v1/admin/access-requests/\(id)/deny", token: App.adminToken, body: [:])
            #expect(again.status == 409 && again.code == "already_resolved")
            app.clock.advance(by: .seconds(10 * 60))
            #expect(try await client.call(.get, "/v1/access-requests/\(id)").status == 404)

            let denied = try await client.call(.post, "/v1/access-requests", body: ["name": "X", "description": "Y", "scopes": ["chats:read"]])
            let deniedId = try #require(denied.json["request_id"]?.stringValue)
            let deny = try await client.call(.post, "/v1/admin/access-requests/\(deniedId)/deny", token: App.adminToken, body: ["reason": "Not now."])
            #expect(deny.json == ["status": "denied"])
            app.clock.advance(by: .seconds(3))
            let deniedPoll = try await client.call(.get, "/v1/access-requests/\(deniedId)")
            #expect(deniedPoll.json["status"] == "denied" && deniedPoll.json["reason"] == "Not now.")

            let send = try await client.call(.post, "/v1/access-requests", body: ["name": "X", "description": "Y", "scopes": ["messages:send"]])
            #expect(send.status == 201 && send.json["status"] == "pending")
            let invalid = try await client.call(.post, "/v1/access-requests", body: ["name": "X", "description": "Y", "scopes": ["nope"]])
            #expect(invalid.status == 400 && invalid.code == "invalid_request" && invalid.json["error"]?["details"]?["field"] == "scopes")
        }
    }

    @Test func unauthenticatedPostIsRateLimited() async throws {
        let app = try await App()
        try await app.application.test(.router) { client in
            for _ in 0..<10 {
                _ = try await client.call(.post, "/v1/access-requests", body: ["name": "X", "description": "Y", "scopes": ["chats:read"]])
            }
            let limited = try await client.call(.post, "/v1/access-requests", body: ["name": "X", "description": "Y", "scopes": ["chats:read"]])
            #expect(limited.status == 429)
        }
    }
}

@Suite struct EventsAndWebhookRouteTests {
    @Test func pagingFiltersAndPruned() async throws {
        let app = try await App()
        try await app.monitorDefaults() // seq 1, 2: monitoring.started
        let (_, token) = try await app.makeGrant(scopes: [.messagesRead])
        for i in 1...3 { _ = try await app.appendMessage(id: Int64(i)) } // seq 3, 4, 5
        _ = try await app.appendMessage(chatId: Fixtures.groupId, id: 9) // seq 6, not granted
        try await app.application.test(.router) { client in
            let page = try await client.call(.get, "/v1/events?limit=2", token: token)
            #expect(page.status == 200)
            #expect(page.json["events"]?.arrayValue?.map { $0["seq"] } == [3, 4])
            #expect(page.json["has_more"] == true && page.json["next_since"] == 4 && page.json["head_seq"] == 6)
            let rest = try await client.call(.get, "/v1/events?since=4", token: token)
            #expect(rest.json["events"]?.arrayValue?.map { $0["seq"] } == [5] && rest.json["has_more"] == false && rest.json["next_since"] == 5)
            let admin = try await client.call(.get, "/v1/events?types=monitoring.started&chat_id=\(Fixtures.groupId)", token: App.adminToken)
            #expect(admin.json["events"]?.arrayValue?.count == 1)
            let badLimit = try await client.call(.get, "/v1/events?limit=5000", token: token)
            #expect(badLimit.status == 400 && badLimit.json["error"]?["details"]?["field"] == "limit")
            let badType = try await client.call(.get, "/v1/events?types=nope", token: token)
            #expect(badType.status == 400)
            _ = try await client.call(.post, "/v1/admin/events/prune", token: App.adminToken, body: ["before_seq": 4])
            let pruned = try await client.call(.get, "/v1/events?since=1", token: token)
            #expect(pruned.status == 410 && pruned.code == "history_pruned" && pruned.json["error"]?["details"]?["oldest_seq"] == 4)
            #expect(try await client.call(.get, "/v1/events?since=0", token: token).status == 200)
        }
    }

    @Test func pruneRefusesWhenAWebhookCursorIsBehind() async throws {
        let app = try await App()
        let (grant, _) = try await app.makeGrant(webhook: "https://x.example/h")
        for i in 1...5 { _ = try await app.appendMessage(id: Int64(i)) }
        try await app.application.test(.router) { client in
            let refused = try await client.call(.post, "/v1/admin/events/prune", token: App.adminToken, body: ["before_seq": 4])
            #expect(refused.status == 409 && refused.code == "cursor_behind" && refused.json["error"]?["details"]?["grant_id"] == .string(grant.id))
            let forced = try await client.call(.post, "/v1/admin/events/prune", token: App.adminToken, body: ["before_seq": 4, "force": true])
            #expect(forced.json == ["deleted": 3, "oldest_seq": 4])
            #expect(try await app.store.grant(grant.id)?.webhook?.cursorSeq == 3)
            let behind = try await client.call(.post, "/v1/admin/events/prune", token: App.adminToken, body: ["older_than": .date(app.clock.now.addingTimeInterval(60))])
            #expect(behind.status == 409)
            let older = try await client.call(.post, "/v1/admin/events/prune", token: App.adminToken, body: ["older_than": .date(app.clock.now.addingTimeInterval(60)), "force": true])
            #expect(older.json["deleted"] == 2)
        }
    }

    @Test func webhookSettings() async throws {
        let app = try await App()
        let (_, token) = try await app.makeGrant()
        try await app.application.test(.router) { client in
            let none = try await client.call(.get, "/v1/me/webhook", token: token)
            #expect(none.status == 404 && none.code == "webhook_not_configured")
            let set = try await client.call(.put, "/v1/me/webhook", token: token, body: ["url": "https://x.example/h"])
            #expect(set.status == 200 && set.json["state"] == "active" && set.json["secret"]?.stringValue?.hasPrefix("whsec_") == true)
            let insecure = try await client.call(.put, "/v1/me/webhook", token: token, body: ["url": "http://x.example/h"])
            #expect(insecure.status == 400)
            let get = try await client.call(.get, "/v1/me/webhook", token: token)
            #expect(get.json["url"] == "https://x.example/h" && get.json.objectValue?["secret"] == nil)
            let notPaused = try await client.call(.post, "/v1/me/webhook/resume", token: token)
            #expect(notPaused.status == 409 && notPaused.code == "webhook_not_paused")
            #expect(try await client.call(.delete, "/v1/me/webhook", token: token).status == 204)
            let adminNone = try await client.call(.put, "/v1/me/webhook", token: App.adminToken, body: ["url": "https://x.example/h"])
            #expect(adminNone.status == 409 && adminNone.code == "webhook_not_configured")
        }
    }
}

@Suite struct AdminRouteTests {
    @Test func monitoredSetFoldersAndGrants() async throws {
        let app = try await App()
        await app.tdlib.setFolder(3, chatIds: [Fixtures.groupId])
        await app.deps.monitor.handle(update: Fixtures.updateChatFolders([(3, "Product")]))
        try await app.application.test(.router) { client in
            let empty = try await client.call(.get, "/v1/admin/monitored-chats", token: App.adminToken)
            #expect(empty.json == ["chat_ids": [], "folder_ids": [], "effective_chat_ids": []])
            let put = try await client.call(.put, "/v1/admin/monitored-chats", token: App.adminToken, body: ["chat_ids": [.id(Fixtures.channelId)], "folder_ids": ["3"]])
            #expect(put.status == 200)
            let expectedEffective: JSONValue = .array([Fixtures.groupId, Fixtures.channelId].sorted().map { .id($0) })
            #expect(put.json["effective_chat_ids"] == expectedEffective)
            let missing = try await client.call(.put, "/v1/admin/monitored-chats", token: App.adminToken, body: ["chat_ids": []])
            #expect(missing.status == 400 && missing.json["error"]?["details"]?["field"] == "folder_ids")
            let unknown = try await client.call(.put, "/v1/admin/monitored-chats", token: App.adminToken, body: ["chat_ids": ["404"], "folder_ids": []])
            #expect(unknown.status == 400 && unknown.code == "chat_not_monitorable")
            let folders = try await client.call(.get, "/v1/admin/folders", token: App.adminToken)
            #expect(folders.json["folders"]?[0] == ["id": "3", "title": "Product", "chat_ids": [.id(Fixtures.groupId)], "is_monitored": true])
            let chats = try await client.call(.get, "/v1/admin/chats", token: App.adminToken)
            #expect(chats.json["chats"]?.arrayValue?.count == 2)
            let all = try await client.call(.get, "/v1/admin/chats?all=true&limit=1", token: App.adminToken)
            #expect(all.status == 200 && all.json["has_more"] == false)

            let issued = try await app.deps.grants.create(name: "A", description: "D", scopes: [.chatsRead], chats: .folder(id: 3), webhookUrl: nil)
            let list = try await client.call(.get, "/v1/admin/grants", token: App.adminToken)
            #expect(list.json["grants"]?[0]?["chats"] == ["mode": "folder", "folder_id": "3", "folder_title": "Product"])
            let one = try await client.call(.get, "/v1/admin/grants/\(issued.grant.id)", token: App.adminToken)
            #expect(one.json["stats"] == ["events_delivered_24h": 0, "websocket_connections": 0])
            let deliveries = try await client.call(.get, "/v1/admin/grants/\(issued.grant.id)/deliveries", token: App.adminToken)
            #expect(deliveries.json == ["deliveries": [], "has_more": false])
            #expect(try await client.call(.delete, "/v1/admin/grants/\(issued.grant.id)", token: App.adminToken).status == 204)
            #expect(try await client.call(.get, "/v1/admin/grants", token: App.adminToken).json["grants"] == [])
            #expect(try await client.call(.get, "/v1/admin/grants?include_revoked=true", token: App.adminToken).json["grants"]?.arrayValue?.count == 1)
            #expect(try await client.call(.get, "/v1/me", token: issued.token).code == "token_revoked")
            #expect(try await client.call(.delete, "/v1/admin/grants/grant_missing", token: App.adminToken).status == 404)
            let status = try await client.call(.get, "/v1/admin/status", token: App.adminToken)
            #expect(status.json["monitored_chat_count"] == 2 && status.json["grant_count"] == 0 && status.json["backfill"] == ["in_progress": false, "chats_pending": 0])
            #expect(status.json["events_today"] == status.json["head_seq"] && status.json["events_last_hour"] == status.json["head_seq"])
        }
    }

    @Test func loginFlow() async throws {
        let app = try await App()
        await app.telegram.set(state: .waitPhoneNumber)
        try await app.application.test(.router) { client in
            let start = try await client.call(.get, "/v1/admin/auth", token: App.adminToken)
            #expect(start.json["auth_state"] == "wait_phone_number" && start.json["qr_link"] == .null)
            let qr = try await client.call(.post, "/v1/admin/auth/qr", token: App.adminToken)
            #expect(qr.json["auth_state"] == "wait_qr_confirmation" && qr.json["qr_link"] == "tg://login?token=FAKE")
            let badPhone = try await client.call(.post, "/v1/admin/auth/phone", token: App.adminToken, body: ["phone_number": "555"])
            #expect(badPhone.status == 400 && badPhone.json["error"]?["details"]?["field"] == "phone_number")
            let phone = try await client.call(.post, "/v1/admin/auth/phone", token: App.adminToken, body: ["phone_number": "+15551234567"])
            #expect(phone.json["auth_state"] == "wait_code" && phone.json["code_type"] == "sms" && phone.json["phone_hint"] == "+15551234567")
            let wrongCode = try await client.call(.post, "/v1/admin/auth/code", token: App.adminToken, body: ["code": "00000"])
            #expect(wrongCode.status == 400 && wrongCode.json["error"]?["details"]?["reason"] == "wrong_code")
            let code = try await client.call(.post, "/v1/admin/auth/code", token: App.adminToken, body: ["code": "12345"])
            #expect(code.json["auth_state"] == "wait_password" && code.json["password_hint"] == "pet")
            let wrongPassword = try await client.call(.post, "/v1/admin/auth/password", token: App.adminToken, body: ["password": "nope"])
            #expect(wrongPassword.status == 400 && wrongPassword.json["error"]?["details"]?["reason"] == "wrong_password" && wrongPassword.json["error"]?["details"]?["password_hint"] == "pet")
            let password = try await client.call(.post, "/v1/admin/auth/password", token: App.adminToken, body: ["password": "hunter2"])
            #expect(password.json["auth_state"] == "ready")
            let logout = try await client.call(.post, "/v1/admin/auth/logout", token: App.adminToken)
            #expect(logout.json["auth_state"] == "wait_phone_number" && logout.json["code_type"] == .null)
            await app.telegram.set(state: .waitEmailAddress)
            #expect(try await client.call(.get, "/v1/admin/auth", token: App.adminToken).json["auth_state"] == "wait_email_address")
            let email = try await client.call(.post, "/v1/admin/auth/email", token: App.adminToken, body: ["email_address": "me@example.com"])
            #expect(email.json["auth_state"] == "wait_email_code")
            let wrongEmailCode = try await client.call(.post, "/v1/admin/auth/email_code", token: App.adminToken, body: ["code": "000"])
            #expect(wrongEmailCode.status == 400 && wrongEmailCode.json["error"]?["details"]?["reason"] == "wrong_code")
            #expect(try await client.call(.post, "/v1/admin/auth/email_code", token: App.adminToken, body: ["code": "777"]).json["auth_state"] == "wait_password")
            #expect(await app.telegram.calls == ["qr", "phone:555", "phone:+15551234567", "code:00000", "code:12345", "password", "password", "logout", "email:me@example.com", "emailcode:000", "emailcode:777"])
        }
    }
}

@Suite struct MediaRouteTests {
    @Test func headGetRangeAndAccessChecks() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let dir = FileManager.default.temporaryDirectory.appending(path: "tgw-media-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "demo.bin").path
        try Data((0..<100).map { UInt8($0) }).write(to: URL(filePath: path))
        let media = Media(mediaId: "med_demo", kind: .document, mime: "application/octet-stream", size: 100, width: nil, height: nil, durationSeconds: nil, fileName: "demo.bin")
        try await app.store.recordMedia(MediaRecord(media: media, remoteId: "r-demo", uniqueId: "u-demo"), chatId: Fixtures.channelId)
        await app.tdlib.add(file: JSONBox(Fixtures.file(id: 11, remoteId: "r-demo", uniqueId: "u-demo", size: 100)), completedPath: path)
        let (_, reader) = try await app.makeGrant(scopes: [.mediaRead, .messagesRead])
        let (_, noScope) = try await app.makeGrant(scopes: [.messagesRead])
        let (_, otherChat) = try await app.makeGrant(scopes: [.mediaRead], chats: .list([Fixtures.groupId]))
        try await app.application.test(.router) { client in
            let head = try await client.call(.head, "/v1/media/med_demo", token: reader)
            #expect(head.status == 200 && head.headers[.cached] == "false" && head.headers[.contentLength] == "100")
            #expect(head.headers[.eTag] == "\"med_demo\"" && head.headers[.contentDisposition] == "inline; filename=\"demo.bin\"")
            let forbidden = try await client.call(.get, "/v1/media/med_demo", token: noScope)
            #expect(forbidden.status == 403 && forbidden.code == "insufficient_scope")
            let notGranted = try await client.call(.get, "/v1/media/med_demo", token: otherChat)
            #expect(notGranted.status == 403 && notGranted.code == "chat_not_granted")
            #expect(try await client.call(.get, "/v1/media/med_unknown", token: reader).code == "chat_not_granted")
            let full = try await client.call(.get, "/v1/media/med_demo", token: reader)
            #expect(full.status == 200 && full.data.count == 100 && full.headers[.cacheControl] == "private, max-age=31536000, immutable")
            #expect(try await client.call(.head, "/v1/media/med_demo", token: reader).headers[.cached] == "true")
            let range = try await client.call(.get, "/v1/media/med_demo", token: reader, headers: [(.range, "bytes=10-19")])
            #expect(range.status == 206 && range.data == Data((10..<20).map { UInt8($0) }) && range.headers[.contentRange] == "bytes 10-19/100")
            await app.telegram.set(state: .waitPhoneNumber)
            #expect(try await client.call(.get, "/v1/media/med_demo", token: reader).status == 200) // cached: no Telegram needed
        }
    }
}

@Suite struct WebSocketTests {
    typealias Messages = WebSocketInboundMessageStream.AsyncIterator

    /// Reads frames until `predicate` matches (or the stream ends). One iterator per connection.
    static func frames(_ messages: inout Messages, until predicate: (JSONValue) -> Bool) async throws -> [JSONValue] {
        var frames: [JSONValue] = []
        while let message = try await messages.next() {
            guard case .text(let text) = message else { continue }
            let frame = try JSONValue.parse(text)
            frames.append(frame)
            if predicate(frame) { break }
        }
        return frames
    }

    static func drain(_ messages: inout Messages) async {
        while (try? await messages.next()) != nil {}
    }

    @Test func resumeWithSinceThenLive() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let (_, token) = try await app.makeGrant(scopes: [.messagesRead])
        for i in 1...3 { _ = try await app.appendMessage(id: Int64(i)) } // seq 3, 4, 5
        let deps = app.deps
        try await app.application.test(.live) { client in
            let close = try await client.ws("/v1/events/stream?since=3", configuration: .init(additionalHeaders: [.authorization: "Bearer \(token)"])) { inbound, outbound, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                let backlog = try await WebSocketTests.frames(&messages) { $0["type"] == "caught_up" }
                #expect(backlog.map { $0["type"] } == ["event", "event", "caught_up"])
                #expect(backlog[0]["event"]?["seq"] == 4 && backlog[1]["event"]?["seq"] == 5 && backlog[2]["seq"] == 5)
                // Live: a message in a granted chat arrives, one in another chat does not.
                let chat = ChatSummary(id: Fixtures.groupId, type: .supergroup, title: "g", username: nil)
                let now = Date()
                let message = Message(id: 99, chatId: Fixtures.groupId, sender: Sender(type: .chat, id: Fixtures.groupId, displayName: "g", username: nil, isBot: nil), date: now, editDate: nil, isOutgoing: false, text: "x", entities: [], replyTo: nil, forwardFrom: nil, media: [], mediaGroupId: nil, link: nil, rawContentType: "messageText")
                _ = try await deps.eventLog.append(Event(type: .messageNew, occurredAt: now, recordedAt: now, chat: chat, payload: .message(message)))
                _ = try await app.appendMessage(id: 4, text: "live")
                let live = try await WebSocketTests.frames(&messages) { $0["type"] == "event" }
                #expect(live.count == 1 && live[0]["event"]?["seq"] == 7 && live[0]["event"]?["message"]?["text"] == "live")
                try await outbound.close(.normalClosure, reason: nil)
            }
            #expect(close?.closeCode == .normalClosure)
        }
    }

    @Test func liveOnlyWithoutSinceAndHeartbeat() async throws {
        let app = try await App()
        let (_, token) = try await app.makeGrant()
        _ = try await app.appendMessage(id: 1)
        let clock = app.clock
        try await app.application.test(.live) { client in
            _ = try await client.ws("/v1/events/stream", configuration: .init(additionalHeaders: [.authorization: "Bearer \(token)"])) { inbound, outbound, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                let first = try await WebSocketTests.frames(&messages) { _ in true }
                #expect(first == [["type": "caught_up", "seq": 1]])
                try await clock.waitForSleepers(1)
                clock.advance(by: .seconds(30))
                let heartbeat = try await WebSocketTests.frames(&messages) { _ in true }
                #expect(heartbeat[0]["type"] == "heartbeat" && heartbeat[0]["seq"] == 1 && heartbeat[0]["time"] == .date(clock.now))
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }

    @Test func closeCodes() async throws {
        let app = try await App()
        let (mediaOnly, mediaToken) = try await app.makeGrant(scopes: [.mediaRead])
        _ = mediaOnly
        let (grant, token) = try await app.makeGrant()
        for i in 1...5 { _ = try await app.appendMessage(id: Int64(i)) }
        _ = try await app.deps.eventLog.prune(beforeSeq: 4)
        let deps = app.deps
        try await app.application.test(.live) { client in
            let unauthenticated = try await client.ws("/v1/events/stream") { inbound, _, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                let frames = try await WebSocketTests.frames(&messages) { $0["type"] == "error" }
                #expect(frames.last?["code"] == "missing_token")
                await WebSocketTests.drain(&messages)
            }
            #expect(unauthenticated?.closeCode == .unknown(4401))
            let plain = try await client.execute(uri: "/v1/events/stream", method: .get)
            #expect(plain.status == .badRequest)
            let nothing = try await client.ws("/v1/events/stream", configuration: .init(additionalHeaders: [.authorization: "Bearer \(mediaToken)"])) { inbound, _, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                await WebSocketTests.drain(&messages)
            }
            #expect(nothing?.closeCode == .unknown(4403))
            let pruned = try await client.ws("/v1/events/stream?since=1", configuration: .init(additionalHeaders: [.authorization: "Bearer \(token)"])) { inbound, _, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                let frames = try await WebSocketTests.frames(&messages) { $0["type"] == "error" }
                #expect(frames.last?["code"] == "history_pruned" && frames.last?["details"]?["oldest_seq"] == 4)
                await WebSocketTests.drain(&messages)
            }
            #expect(pruned?.closeCode == .unknown(4410))
            let revoked = try await client.ws("/v1/events/stream", configuration: .init(additionalHeaders: [.authorization: "Bearer \(token)"])) { inbound, _, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                _ = try await WebSocketTests.frames(&messages) { $0["type"] == "caught_up" }
                try await deps.grants.revoke(grant.id)
                await WebSocketTests.drain(&messages)
            }
            #expect(revoked?.closeCode == .unknown(4499))
        }
    }

    @Test func shutdownClosesWithGoingAway() async throws {
        let app = try await App()
        let (_, token) = try await app.makeGrant()
        let deps = app.deps
        try await app.application.test(.live) { client in
            let close = try await client.ws("/v1/events/stream", configuration: .init(additionalHeaders: [.authorization: "Bearer \(token)"])) { inbound, _, _ in
                var messages = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                _ = try await WebSocketTests.frames(&messages) { $0["type"] == "caught_up" }
                await deps.shutdown.trigger()
                await WebSocketTests.drain(&messages)
            }
            #expect(close?.closeCode == .goingAway)
        }
    }
}

@Suite struct ReloadRouteTests {
    /// The server with a `TelegramHost` over fake sessions and a real config.json in a
    /// temporary data directory.
    struct Harness {
        let home: URL
        let paths: Paths
        let ledger = FakeSessionLedger()
        let host: TelegramHost
        let application: Application<RouterResponder<GatewayRequestContext>>
        let deps: Dependencies

        init() async throws {
            home = FileManager.default.temporaryDirectory.appending(path: "tgw-reload-route-\(UUID().uuidString)")
            paths = Paths(home: home)
            try paths.prepare()
            let store = try Store.inMemory()
            let clock = ManualClock()
            let host = TelegramHost(factory: ledger.factory())
            self.host = host
            let translator = Translator(tdlib: host)
            let eventLog = EventLog(store: store, clock: clock)
            let grants = Grants(store: store, adminToken: App.adminToken, clock: clock)
            let monitor = Monitor(store: store, eventLog: eventLog, translator: translator, tdlib: host, clock: clock)
            var logger = Logger(label: "test")
            logger.logLevel = .error
            deps = Dependencies(
                store: store, eventLog: eventLog, grants: grants, accessRequests: AccessRequests(store: store, grants: grants, clock: clock),
                monitor: monitor, translator: translator, mediaCache: MediaCache(store: store, tdlib: host, maxBytes: 1 << 20, clock: clock),
                dispatcher: nil, telegram: host, reloader: ConfigReloader(paths: paths, running: Config(), host: host, environment: [:]),
                rateLimiter: RateLimiter(clock: clock), clock: clock, config: Config(), startedAt: clock.now, logger: logger
            )
            application = GatewayServer.buildApplication(deps: deps, port: 0, logger: logger)
        }

        func write(_ config: String) throws {
            try Data(config.utf8).write(to: paths.config)
        }
    }

    @Test func credentialsSavedWhileRunningTakeEffectOnReload() async throws {
        let h = try await Harness()
        defer { try? FileManager.default.removeItem(at: h.home) }
        let (_, appToken) = try await { () async throws -> (Grant, String) in
            let issued = try await h.deps.grants.create(name: "A", description: "D", scopes: [.chatsRead], chats: .list([1]), webhookUrl: nil)
            return (issued.grant, issued.token)
        }()
        _ = try await h.deps.eventLog.headSeq()
        try await h.application.test(.router) { client in
            // Started without credentials: Telegram is disabled.
            #expect(try await client.call(.get, "/v1/health").json["tdlib"]?["auth_state"] == "unknown")
            #expect(try await client.call(.post, "/v1/admin/auth/qr", token: App.adminToken).status == 503)
            #expect(try await client.call(.post, "/v1/admin/reload", token: App.adminToken).json == ["reloaded": true, "telegram": "disabled", "restart_required": []])

            // The app saves the credentials, then asks for a reload.
            try h.write(#"{"api_id": 12345, "api_hash": "aaaa"}"#)
            let started = try await client.call(.post, "/v1/admin/reload", token: App.adminToken)
            #expect(started.status == 200 && started.json == ["reloaded": true, "telegram": "started", "restart_required": []])
            #expect(try await client.call(.get, "/v1/health").json["tdlib"]?["auth_state"] == "wait_phone_number")
            #expect(try await client.call(.post, "/v1/admin/auth/qr", token: App.adminToken).json["auth_state"] == "wait_qr_confirmation")

            // Nothing changed.
            #expect(try await client.call(.post, "/v1/admin/reload", token: App.adminToken).json["telegram"] == "unchanged")
            #expect(h.ledger.created.count == 1)

            // New credentials and a new port: the session is replaced, the port waits for a restart.
            try h.write(#"{"api_id": 12345, "api_hash": "bbbb", "port": 5000}"#)
            let restarted = try await client.call(.post, "/v1/admin/reload", token: App.adminToken)
            #expect(restarted.json == ["reloaded": true, "telegram": "restarted", "restart_required": ["port"]])
            #expect(h.ledger.created.count == 2 && h.ledger.live == 1 && h.ledger.maxLive == 1)
            #expect(try await client.call(.get, "/v1/admin/auth", token: App.adminToken).json["auth_state"] == "wait_phone_number")

            // Credentials removed.
            try h.write(#"{"port": 5000}"#)
            #expect(try await client.call(.post, "/v1/admin/reload", token: App.adminToken).json["telegram"] == "disabled")
            #expect(h.ledger.live == 0)

            // Errors: app tokens may not reload; a broken config.json changes nothing.
            let forbidden = try await client.call(.post, "/v1/admin/reload", token: appToken)
            #expect(forbidden.status == 403 && forbidden.code == "admin_only")
            try h.write("{ not json")
            let broken = try await client.call(.post, "/v1/admin/reload", token: App.adminToken)
            #expect(broken.status == 400 && broken.code == "invalid_request" && broken.json["error"]?["details"]?["field"] == "config.json")
            // Grants and the event log were never touched.
            #expect(try await client.call(.get, "/v1/me", token: appToken).status == 200)
        }
    }

    @Test func reloadIsNotFoundWhereItIsNotWired() async throws {
        let app = try await App()
        try await app.application.test(.router) { client in
            let reply = try await client.call(.post, "/v1/admin/reload", token: App.adminToken)
            #expect(reply.status == 404)
        }
    }
}
