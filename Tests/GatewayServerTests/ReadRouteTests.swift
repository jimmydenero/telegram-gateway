import Foundation
import GatewayCore
import GatewayLink
import GatewayServer
import GatewayTestSupport
import HTTPTypes
import HummingbirdTesting
import TDLibClient
import Testing

@Suite struct ReadRouteTests {
    @Test func readAnswersWithTheNewUnreadState() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ReadFixtures.install(app.tdlib)
        let (_, token) = try await app.makeGrant(scopes: [.messagesMarkRead])
        let path = "/v1/chats/\(Fixtures.channelId)/read"
        try await app.application.test(.router) { client in
            let partial = try await client.call(.post, path, token: token, body: ["up_to_message_id": "1529"])
            #expect(partial.status == 200)
            #expect(partial.json["chat"]?["unread_count"] == 1)
            #expect(partial.json["chat"]?["unread_mention_count"] == 2)
            let all = try await client.call(.post, path, token: token, body: ["mentions": true])
            #expect(all.status == 200)
            #expect(all.json["chat"]?["id"] == .id(Fixtures.channelId))
            #expect(all.json["chat"]?["unread_count"] == 0)
            #expect(all.json["chat"]?["unread_mention_count"] == 0)
            #expect(all.json["chat"]?["last_read_inbox_message_id"] == "1530")
        }
        let views = await app.tdlib.requests(ofType: "viewMessages")
        #expect(views.count == 2 && views.allSatisfy { $0.object.bool("force_read") == true })
        #expect(await app.tdlib.requests(ofType: "openChat").isEmpty)
    }

    @Test func refusedWithoutScopeAndForBadBodiesWithoutReading() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ReadFixtures.install(app.tdlib)
        let (_, sender) = try await app.makeGrant(scopes: [.messagesRead, .chatsRead, .messagesSend])
        let path = "/v1/chats/\(Fixtures.channelId)/read"
        try await app.application.test(.router) { client in
            let missing = try await client.call(.post, path, token: sender)
            #expect(missing.status == 403 && missing.json["error"]?["code"] == "insufficient_scope")
            let badId = try await client.call(.post, path, token: App.adminToken, body: ["up_to_message_id": "x"])
            #expect(badId.status == 400)
            let badFlag = try await client.call(.post, path, token: App.adminToken, body: ["mentions": "yes"])
            #expect(badFlag.status == 400)
            let unmonitored = try await client.call(.post, "/v1/chats/\(Fixtures.privateChatId)/read", token: App.adminToken)
            #expect(unmonitored.status == 403)
        }
        #expect(await app.tdlib.requests(ofType: "viewMessages").isEmpty)
    }

    @Test func scopeIsRequestableAndTheAdminHoldsIt() async throws {
        let app = try await App()
        try await app.application.test(.router) { client in
            let request = try await client.call(.post, "/v1/access-requests", body: ["name": "Inbox", "description": "Marks chats read when you open them", "scopes": ["messages:read", "messages:mark_read"], "requested_chats": "any"])
            #expect(request.status == 201)
            let me = try await client.call(.get, "/v1/me", token: App.adminToken)
            #expect(me.json["grant"]?["scopes"]?.arrayValue?.contains("messages:mark_read") == true)
        }
    }

    @Test func linkCanMarkRead() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ReadFixtures.install(app.tdlib)
        let api = InProcessAPI(deps: app.deps, adminToken: App.adminToken)
        let response = await api.perform(LinkHTTPRequest(method: "POST", path: "/v1/chats/\(Fixtures.channelId)/read", body: JSONValue.object([:]).serialized()), maxBodyBytes: LinkPolicy.maxBodyBytes)
        #expect(response.status == 200)
        #expect(await app.tdlib.requests(ofType: "viewMessages").count == 1)
    }
}
