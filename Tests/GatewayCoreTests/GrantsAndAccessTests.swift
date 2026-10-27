import Foundation
import GatewayCore
import GatewayTestSupport
import Testing

@Suite struct GrantsTests {
    @Test func tokensAreTheDocumentedShapeAndOnlyHashesAreStored() async throws {
        let core = try await Core()
        let (grant, token) = try await core.makeGrant()
        #expect(token.hasPrefix("tgw_") && token.count == 47 && Identifiers.looksLikeToken(token))
        #expect(grant.tokenHash == Identifiers.hash(token))
        #expect(!grant.tokenHash.contains(token))
    }

    @Test func authenticateResolvesAdminAppAndFailures() async throws {
        let core = try await Core()
        let (grant, token) = try await core.makeGrant()
        #expect(try await core.grants.authenticate(bearer: Core.adminToken) == .admin)
        let principal = try await core.grants.authenticate(bearer: token)
        #expect(principal.grant?.id == grant.id)
        #expect(try await core.store.grant(grant.id)?.lastSeenAt == core.clock.now)
        #expect(await apiError { try await core.grants.authenticate(bearer: nil) }?.code == "missing_token")
        #expect(await apiError { try await core.grants.authenticate(bearer: "nope") }?.code == "invalid_token")
        #expect(await apiError { try await core.grants.authenticate(bearer: "tgw_" + String(repeating: "B", count: 43)) }?.code == "invalid_token")
        try await core.grants.revoke(grant.id)
        let revoked = await apiError { try await core.grants.authenticate(bearer: token) }
        #expect(revoked?.code == "token_revoked")
        #expect(revoked?.details["revoked_at"] == .date(core.clock.now))
    }

    @Test func effectiveChatsAreGrantedIntersectedWithMonitored() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let (grant, _) = try await core.makeGrant(chats: .list([Fixtures.channelId, Fixtures.privateChatId]))
        #expect(try await core.grants.effectiveChatIds(grant) == [Fixtures.channelId])
        // Un-monitoring the channel empties the effective set; the grant still lists it.
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId]))
        #expect(try await core.grants.effectiveChatIds(grant) == [])
        #expect(try await core.grants.grantedChatIds(grant) == [Fixtures.channelId, Fixtures.privateChatId])
    }

    @Test func folderGrantsFollowTheFolderContents() async throws {
        let core = try await Core()
        try await core.store.upsertFolder(Folder(id: 3, title: "Product", chatIds: [Fixtures.channelId]), now: core.clock.now)
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId], folderIds: [3]))
        let (grant, _) = try await core.makeGrant(chats: .folder(id: 3))
        #expect(try await core.grants.effectiveChatIds(grant) == [Fixtures.channelId])
        try await core.store.upsertFolder(Folder(id: 3, title: "Product", chatIds: [Fixtures.channelId, Fixtures.groupId]), now: core.clock.now)
        #expect(try await core.grants.effectiveChatIds(grant) == [Fixtures.groupId, Fixtures.channelId].sorted())
        let json = try await core.grants.json(grant)
        #expect(json["chats"]?["mode"] == "folder")
        #expect(json["chats"]?["folder_title"] == "Product")
        #expect(json["chats"]?["folder_id"] == "3")
    }

    @Test func scopeGatingAndVisibleTypes() async throws {
        let core = try await Core()
        let (grant, _) = try await core.makeGrant(scopes: [.messagesRead])
        let principal = Principal.app(grant)
        try await core.grants.require(.messagesRead, principal)
        let error = await apiError { try await core.grants.require(.historyRead, principal) }
        #expect(error?.code == "insufficient_scope")
        #expect(error?.details["required"] == "history:read")
        #expect(error?.details["granted"] == ["messages:read"])
        try await core.grants.require(.historyRead, .admin)
        #expect(await core.grants.visibleEventTypes(principal) == [.messageNew, .messageEdited, .messageDeleted, .messageReactions, .pollUpdated])
        #expect(await core.grants.visibleEventTypes(.admin) == nil)
        #expect(Grants.visibleEventTypes(scopes: [.mediaRead]).isEmpty)
    }

    @Test func requireChatNeverDistinguishesUnknownFromUngranted() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let (grant, _) = try await core.makeGrant(chats: .list([Fixtures.channelId]))
        try await core.grants.requireChat(Fixtures.channelId, .app(grant))
        #expect(await apiError { try await core.grants.requireChat(Fixtures.groupId, .app(grant)) }?.code == "chat_not_granted")
        #expect(await apiError { try await core.grants.requireChat(42, .app(grant)) }?.code == "chat_not_granted")
        try await core.grants.requireChat(Fixtures.groupId, .admin)
        #expect(await apiError { try await core.grants.requireChat(42, .admin) }?.code == "chat_not_granted")
    }

    @Test func chatListShowsLostCoverage() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let (grant, _) = try await core.makeGrant(chats: .list([Fixtures.channelId, Fixtures.groupId]))
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.channelId]))
        let chats = try await core.grants.chats(for: .app(grant))
        #expect(chats.map { ($0.chat.id, $0.isMonitored) }.map { "\($0.0):\($0.1)" } == ["\(Fixtures.groupId):false", "\(Fixtures.channelId):true"])
    }

    @Test func grantJSONMatchesTheContract() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let (grant, _) = try await core.makeGrant(chats: .list([Fixtures.channelId]), webhook: "https://x.example/h")
        _ = try await core.appendMessageEvent(id: 1)
        let json = try await core.grants.json(grant)
        #expect(json.objectValue?.keys == ["id", "app", "scopes", "chats", "effective_chat_ids", "webhook", "created_at", "last_seen_at", "revoked_at"])
        #expect(json["effective_chat_ids"] == [.id(Fixtures.channelId)])
        #expect(json["webhook"]?["state"] == "active")
        #expect(json["webhook"]?["pending_events"] == 1)
        #expect(json["webhook"]?["cursor_seq"] == 2) // head when the grant was created
        #expect(json["webhook"]?.objectValue?["secret"] == nil)
        #expect(json["last_seen_at"] == .null)
        let admin = try await core.grants.adminGrantJSON()
        #expect(admin["id"] == "grant_admin")
    }

    @Test func webhookSettingsLifecycle() async throws {
        let core = try await Core()
        let (grant, _) = try await core.makeGrant()
        _ = try await core.appendMessageEvent(id: 1)
        let (webhook, secret) = try await core.grants.setWebhook(grantId: grant.id, url: "https://x.example/h")
        #expect(secret.hasPrefix("whsec_") && secret.count == 49)
        #expect(webhook.cursorSeq == 1) // starts at head
        #expect(await apiError { try await core.grants.resumeWebhook(grantId: grant.id) }?.code == "webhook_not_paused")
        try await core.grants.updateWebhook(grantId: grant.id) { $0.state = .paused; $0.pausedAt = Date() }
        let resumed = try await core.grants.resumeWebhook(grantId: grant.id)
        #expect(resumed.state == .active && resumed.pausedAt == nil)
        let (replaced, newSecret) = try await core.grants.setWebhook(grantId: grant.id, url: "https://y.example/h")
        #expect(newSecret != secret && replaced.cursorSeq == 1)
        try await core.grants.deleteWebhook(grantId: grant.id)
        #expect(await apiError { try await core.grants.deleteWebhook(grantId: grant.id) }?.code == "webhook_not_configured")
    }

    @Test func revocationIsBroadcast() async throws {
        let core = try await Core()
        let (grant, _) = try await core.makeGrant()
        let stream = await core.grants.revocations()
        try await core.grants.revoke(grant.id)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == grant.id)
        #expect(await apiError { try await core.grants.revoke("grant_missing") }?.code == "not_found")
    }
}

@Suite struct AccessRequestsTests {
    func submission(scopes: [Scope] = [.messagesRead, .chatsRead], chats: [Int64]? = [Fixtures.channelId], webhook: String? = nil) -> AccessRequests.Submission {
        AccessRequests.Submission(name: "Community Analytics", description: "Counts topics.", scopes: scopes, requestedChats: chats, webhookUrl: webhook)
    }

    @Test func validation() async throws {
        let core = try await Core()
        let ar = core.accessRequests
        #expect(await apiError { try await ar.create(AccessRequests.Submission(name: "", description: "d", scopes: [.chatsRead], requestedChats: nil, webhookUrl: nil)) }?.details["field"] == "name")
        #expect(await apiError { try await ar.create(AccessRequests.Submission(name: "n", description: String(repeating: "x", count: 281), scopes: [.chatsRead], requestedChats: nil, webhookUrl: nil)) }?.details["field"] == "description")
        #expect(await apiError { try await ar.create(submission(scopes: [])) }?.details["field"] == "scopes")
        // messages:send is grantable: the request is accepted like any other.
        let send = try await ar.create(submission(scopes: [.messagesRead, .messagesSend]))
        #expect(send.scopes == [.messagesRead, .messagesSend])
        #expect(await apiError { try await ar.create(submission(webhook: "http://example.com/h")) }?.details["field"] == "webhook.url")
        #expect(await apiError { try await ar.create(submission(webhook: "ftp://example.com/h")) }?.code == "invalid_request")
        _ = try await ar.create(submission(webhook: "http://localhost:9000/h"))
        _ = try await ar.create(submission(webhook: "http://127.0.0.1:9000/h"))
        _ = try await ar.create(submission(webhook: "https://analytics.example.com/tgw/events"))
    }

    @Test func pendingRequestExpiresAfterFifteenMinutesAndIsPurgedTenLater() async throws {
        let core = try await Core()
        let request = try await core.accessRequests.create(submission())
        #expect(request.id.hasPrefix("req_") && request.id.count == 47)
        #expect(request.expiresAt == core.clock.now.addingTimeInterval(15 * 60))
        core.clock.advance(by: .seconds(15 * 60 - 1))
        #expect(try await core.accessRequests.get(request.id)?.status == .pending)
        core.clock.advance(by: .seconds(1))
        let expired = try await core.accessRequests.get(request.id)
        #expect(expired?.status == .expired)
        #expect(try await core.accessRequests.pollJSON(expired!)["status"] == "expired")
        core.clock.advance(by: .seconds(10 * 60))
        #expect(try await core.accessRequests.get(request.id) == nil)
        #expect(await apiError { try await core.accessRequests.approve(request.id, .init(chats: .list([Fixtures.channelId]))) }?.code == "not_found")
    }

    @Test func approveEndToEnd() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let request = try await core.accessRequests.create(submission(scopes: [.messagesRead, .historyRead, .chatsRead], webhook: "https://analytics.example.com/tgw/events"))
        #expect(await apiError { try await core.accessRequests.approve(request.id, .init(chats: .list([Fixtures.privateChatId]))) }?.code == "chat_not_monitored")
        #expect(await apiError { try await core.accessRequests.approve(request.id, .init(chats: .folder(id: 9))) }?.code == "folder_not_monitored")
        #expect(await apiError { try await core.accessRequests.approve(request.id, .init(chats: .list([Fixtures.channelId]), scopes: [.mediaRead])) }?.code == "scope_not_requested")
        #expect(await apiError { try await core.accessRequests.approve(request.id, .init(chats: .list([]))) }?.code == "invalid_request")

        let grant = try await core.accessRequests.approve(request.id, .init(chats: .list([Fixtures.channelId]), scopes: [.messagesRead, .chatsRead]))
        #expect(grant.scopes == [.chatsRead, .messagesRead])
        #expect(grant.chats == .list([Fixtures.channelId]))
        #expect(grant.webhook?.url == "https://analytics.example.com/tgw/events")

        let approved = try #require(try await core.accessRequests.get(request.id))
        let poll = try await core.accessRequests.pollJSON(approved)
        #expect(poll["status"] == "approved")
        let token = try #require(poll["token"]?.stringValue)
        #expect(Identifiers.looksLikeToken(token))
        #expect(poll["webhook"]?["secret"]?.stringValue?.hasPrefix("whsec_") == true)
        #expect(poll["grant"]?["id"] == .string(grant.id))
        #expect(poll["grant"]?["effective_chat_ids"] == [.id(Fixtures.channelId)])
        #expect(try await core.grants.authenticate(bearer: token).grant?.id == grant.id)

        #expect(await apiError { try await core.accessRequests.approve(request.id, .init(chats: .list([Fixtures.channelId]))) }?.code == "already_resolved")
        #expect(await apiError { try await core.accessRequests.deny(request.id, reason: nil) }?.details["status"] == "approved")

        // Token visible for 10:00, then the request is gone (404) and the token with it.
        core.clock.advance(by: .seconds(10 * 60 - 1))
        #expect(try await core.accessRequests.get(request.id) != nil)
        core.clock.advance(by: .seconds(1))
        #expect(try await core.accessRequests.get(request.id) == nil)
        #expect(try await core.store.accessRequest(request.id) == nil)
    }

    @Test func denyAndAdminView() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let request = try await core.accessRequests.create(submission(chats: [Fixtures.channelId, Fixtures.privateChatId]))
        let admin = try await core.accessRequests.adminJSON(request)
        #expect(admin["requested_chats_status"] == [
            ["chat_id": .id(Fixtures.channelId), "title": "Acme Product Updates", "is_monitored": true],
            ["chat_id": .id(Fixtures.privateChatId), "title": .null, "is_monitored": false],
        ])
        #expect(try await core.accessRequests.list(all: false).map(\.id) == [request.id])
        try await core.accessRequests.deny(request.id, reason: "Not now.")
        let denied = try #require(try await core.accessRequests.get(request.id))
        #expect(try await core.accessRequests.pollJSON(denied) == ["request_id": .string(request.id), "status": "denied", "denied_at": .date(core.clock.now), "reason": "Not now."])
        #expect(try await core.accessRequests.list(all: false).isEmpty)
        #expect(try await core.accessRequests.list(all: true).count == 1)
        let any = try await core.accessRequests.create(submission(chats: nil))
        #expect(try await core.accessRequests.adminJSON(any)["requested_chats"] == "any")
        #expect(try await core.accessRequests.adminJSON(any)["requested_chats_status"] == .null)
    }
}
