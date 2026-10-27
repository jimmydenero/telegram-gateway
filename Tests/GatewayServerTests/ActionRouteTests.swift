import Foundation
import GatewayCore
import GatewayLink
import GatewayServer
import GatewayTestSupport
import HTTPTypes
import HummingbirdTesting
import TDLibClient
import Testing

@Suite struct ActionRouteTests {
    @Test func routesUseActionActorAndGatewayObjects() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ActionFixtures.install(app.tdlib)
        let (_, token) = try await app.makeGrant(scopes: [.messagesSend, .chatsManage])
        let path = "/v1/chats/\(Fixtures.channelId)"
        try await app.application.test(.router) { client in
            let forward = try await client.call(.post, path + "/forward", token: token, body: ["from_chat_id": .id(Fixtures.channelId), "message_ids": ["1530"], "send_copy": true])
            #expect(forward.status == 201 && forward.json["messages"]?[0]?["id"] == "1530")
            let edit = try await client.call(.patch, path + "/messages/1530", token: token, body: ["text": "edited"])
            #expect(edit.status == 200 && edit.json["message"]?["id"] == "1530")
            let delete = try await client.call(.delete, path + "/messages", token: token, body: ["message_ids": ["1530"], "for_everyone": true])
            #expect(delete.status == 204)
            for method in [HTTPRequest.Method.put, .delete] {
                let reaction = try await client.call(method, path + "/messages/1530/reactions", token: token, body: ["emoji": "👍"])
                #expect(reaction.status == 204)
            }
            let vote = try await client.call(.post, path + "/messages/1530/poll", token: token, body: ["option_ids": []])
            #expect(vote.status == 204)
            let settings = try await client.call(.patch, path, token: token, body: ["is_pinned": true, "is_archived": false, "is_muted": false])
            #expect(settings.status == 200 && settings.json["chat"]?["id"] == .id(Fixtures.channelId))
            let start = try await client.call(.post, "/v1/chats", token: token, body: ["username": "acmeupdates"])
            #expect(start.status == 201 && start.json["chat"]?["id"] == .id(Fixtures.channelId))
        }
    }

    @Test func accessRequestAcceptsChatsManageAndAdminIncludesIt() async throws {
        let app = try await App()
        try await app.application.test(.router) { client in
            let request = try await client.call(.post, "/v1/access-requests", body: ["name": "Actions", "description": "Manage selected chats", "scopes": ["messages:send", "chats:manage"], "requested_chats": "any"])
            #expect(request.status == 201)
            let me = try await client.call(.get, "/v1/me", token: App.adminToken)
            #expect(me.json["grant"]?["scopes"]?.arrayValue?.contains("chats:manage") == true)
        }
    }

    @Test func appCannotStartUngrantableChatAndAdminMonitorsPhoneResult() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ActionFixtures.install(app.tdlib)
        let (_, token) = try await app.makeGrant(scopes: [.chatsManage])
        try await app.application.test(.router) { client in
            let refused = try await client.call(.post, "/v1/chats", token: token, body: ["phone": "+15551234567"])
            #expect(refused.status == 403)
            #expect(await app.tdlib.requests(ofType: "createPrivateChat").isEmpty)
            let started = try await client.call(.post, "/v1/chats", token: App.adminToken, body: ["phone": "+15551234567"])
            #expect(started.status == 201)
            #expect(try await app.deps.store.effectiveMonitoredChatIds().contains(Fixtures.privateChatId))
        }
    }

    @Test func deniesScopeUnmonitoredAndBadBodyWithoutMutating() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ActionFixtures.install(app.tdlib)
        let (_, token) = try await app.makeGrant(scopes: [.messagesRead])
        try await app.application.test(.router) { client in
            let missing = try await client.call(.put, "/v1/chats/\(Fixtures.channelId)/messages/1530/reactions", token: token, body: ["emoji": "👍"])
            #expect(missing.status == 403)
            let unmonitored = try await client.call(.patch, "/v1/chats/\(Fixtures.privateChatId)", token: App.adminToken, body: ["is_muted": true])
            #expect(unmonitored.status == 403)
            let bad = try await client.call(.delete, "/v1/chats/\(Fixtures.channelId)/messages", token: App.adminToken, body: ["message_ids": ["9223372036854775807"], "for_everyone": true])
            #expect(bad.status == 400)
        }
        #expect(await app.tdlib.requests(ofType: "addMessageReaction").isEmpty)
        #expect(await app.tdlib.requests(ofType: "deleteMessages").isEmpty)
    }

    @Test func linkCarriesActionAndDeleteBodies() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await ActionFixtures.install(app.tdlib)
        let api = InProcessAPI(deps: app.deps, adminToken: App.adminToken)
        for method in ["PUT", "DELETE"] {
            let response = await api.perform(LinkHTTPRequest(method: method, path: "/v1/chats/\(Fixtures.channelId)/messages/1530/reactions", body: JSONValue.object(["custom_emoji_id": "123"]).serialized()), maxBodyBytes: LinkPolicy.maxBodyBytes)
            #expect(response.status == 204)
        }
        #expect(await app.tdlib.requests(ofType: "removeMessageReaction").count == 1)
    }
}

@Suite struct MediaActionRouteTests {
    @Test func maximumMediaWorksOverHTTPAndLinkAndOversizeIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tgw-upload-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await App(uploadDirectory: directory)
        try await app.monitorDefaults()
        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "upload")
        await app.tdlib.on("sendMessage") { request in
            let path = try #require(request.object("input_message_content")?.object("document")?.object("document")?.string("path"))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.size] as? NSNumber)?.intValue == ActionInput.maxMediaBytes)
            return final.object
        }
        let data = Data(repeating: 65, count: ActionInput.maxMediaBytes)
        let body: JSONValue = ["media": ["kind": "document", "file_name": "fixture.dat", "mime_type": "application/octet-stream", "data_base64": .string(data.base64EncodedString())]]
        let path = "/v1/chats/\(Fixtures.channelId)/messages"
        try await app.application.test(.router) { client in
            let sent = try await client.call(.post, path, token: App.adminToken, body: body)
            #expect(sent.status == 201)
        }
        let api = InProcessAPI(deps: app.deps, adminToken: App.adminToken)
        #expect(await api.perform(LinkHTTPRequest(method: "POST", path: path, body: body.serialized()), maxBodyBytes: LinkPolicy.maxBodyBytes).status == 201)
        let oversized: JSONValue = ["media": ["kind": "document", "file_name": "fixture.dat", "mime_type": "application/octet-stream", "data_base64": .string(Data(repeating: 65, count: ActionInput.maxMediaBytes + 1).base64EncodedString())]]
        #expect(await api.perform(LinkHTTPRequest(method: "POST", path: path, body: oversized.serialized()), maxBodyBytes: LinkPolicy.maxBodyBytes).status == 413)
        #expect(await app.tdlib.requests(ofType: "sendMessage").count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
