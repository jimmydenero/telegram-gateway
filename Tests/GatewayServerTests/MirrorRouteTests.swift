import Foundation
import GatewayCore
import GatewayServer
import GatewayTestSupport
import Hummingbird
import HummingbirdTesting
import Testing
import TDLibClient

@Suite struct MirrorRouteTests {
    /// Read state and position appear on the chat object of every chat endpoint, current from
    /// TDLib's updates.
    @Test func chatEndpointsCarryReadStateAndPosition() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        await app.deps.monitor.handle(update: Fixtures.updateChatReadInbox(chatId: Fixtures.channelId, lastRead: 410, unread: 1))
        await app.deps.monitor.handle(update: Fixtures.updateChatPosition(chatId: Fixtures.channelId, Fixtures.chatPosition(order: "9000", isPinned: true)))
        let (_, token) = try await app.makeGrant(scopes: [.chatsRead, .messagesRead])
        try await app.application.test(.router) { client in
            let admin = try await client.call(.get, "/v1/admin/chats", token: App.adminToken)
            let channel = admin.json["chats"]?.arrayValue?.first { $0["id"] == .id(Fixtures.channelId) }
            #expect(channel?["unread_count"] == 1 && channel?["last_read_inbox_message_id"] == "410" && channel?["is_pinned"] == true)
            #expect(channel?["order"] == "9000" && channel?["is_archived"] == false && channel?["is_muted"] == false && channel?["unread_mention_count"] == 0)
            #expect(channel?["last_read_outbox_message_id"] == .null)

            let list = try await client.call(.get, "/v1/chats", token: token)
            #expect(list.json["chats"]?[0]?["unread_count"] == 1 && list.json["chats"]?[0]?["order"] == "9000")
            let one = try await client.call(.get, "/v1/chats/\(Fixtures.channelId)", token: token)
            #expect(one.json["chat"]?["is_pinned"] == true)

            // The new event types are delivered to apps with the right scopes, and filterable.
            let events = try await client.call(.get, "/v1/events?since=0&types=chat.read,chat.position", token: token)
            let types = events.json["events"]?.arrayValue?.compactMap { $0["type"]?.stringValue }
            #expect(types == ["chat.read", "chat.position"])
        }
        // Without chats:read an app sees neither.
        let (_, messagesOnly) = try await app.makeGrant(scopes: [.messagesRead])
        try await app.application.test(.router) { client in
            let events = try await client.call(.get, "/v1/events?since=0", token: messagesOnly)
            let types = events.json["events"]?.arrayValue?.compactMap { $0["type"]?.stringValue } ?? []
            #expect(!types.contains("chat.read") && !types.contains("chat.position"))
        }
    }
    @Test func archiveDiscoveryAndUnmonitoredState() async throws {
        let app = try await App()
        await app.tdlib.on("getChats") { request in
            let archived = request.object("chat_list")?.type == "chatListArchive"
            return ["@type": "chats", "chat_ids": archived ? [Fixtures.groupId] : [Fixtures.channelId]]
        }
        await app.deps.monitor.handle(update: Fixtures.updateChatLastMessage(chatId: Fixtures.groupId, positions: [Fixtures.chatPosition(list: "chatListArchive", order: "80")]))
        try await app.application.test(.router) { client in
            let archive = try await client.call(.get, "/v1/admin/chats?all=true&list=archive", token: App.adminToken)
            #expect(archive.status == 200)
            #expect(archive.json["chats"]?[0]?["id"] == .id(Fixtures.groupId))
            #expect(archive.json["chats"]?[0]?["is_archived"] == true)
            #expect(archive.json["chats"]?[0]?["is_monitored"] == false)
            let main = try await client.call(.get, "/v1/admin/chats?all=true", token: App.adminToken)
            #expect(main.json["chats"]?[0]?["id"] == .id(Fixtures.channelId))
            let invalid = try await client.call(.get, "/v1/admin/chats?all=true&list=wrong", token: App.adminToken)
            #expect(invalid.status == 400)
        }
        let loads = await app.tdlib.requests(ofType: "loadChats")
        #expect(loads.contains { $0.object.object("chat_list")?.type == "chatListArchive" })
        #expect(try await app.store.events(since: 0, limit: 100, types: nil, chatIds: nil).isEmpty)
    }

    @Test func reactionAndPollScopesAndHistory() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let poll = Fixtures.pollContent()
        let message = Fixtures.message(chatId: Fixtures.channelId, id: 990, sender: Fixtures.chatSender(Fixtures.channelId), content: poll, topic: Fixtures.forumTopic(7))
        await app.tdlib.add(message: message)
        await app.deps.monitor.handle(update: Fixtures.updateMessageContent(chatId: Fixtures.channelId, id: 990, content: poll))
        await app.deps.monitor.handle(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 990, info: Fixtures.interactionInfo(reactions: [("👍", nil, 2, true)])))
        let (_, chatsOnly) = try await app.makeGrant(scopes: [.chatsRead])
        let (_, messagesOnly) = try await app.makeGrant(scopes: [.messagesRead, .historyRead])
        try await app.application.test(.router) { client in
            let hidden = try await client.call(.get, "/v1/events?types=message.reactions,poll.updated", token: chatsOnly)
            #expect(hidden.json["events"] == [])
            let visible = try await client.call(.get, "/v1/events?types=message.reactions,poll.updated", token: messagesOnly)
            #expect(visible.json["events"]?.arrayValue?.count == 2)
            let history = try await client.call(.get, "/v1/chats/\(Fixtures.channelId)/messages", token: messagesOnly)
            #expect(history.status == 200)
            #expect(history.json["messages"]?[0]?["topic_id"] == "7")
            #expect(history.json["messages"]?[0]?["poll"]?["type"] == "regular")
        }
    }

}
