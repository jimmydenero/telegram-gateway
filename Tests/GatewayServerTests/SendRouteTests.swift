import Foundation
import GatewayCore
import GatewayServer
import GatewayTestSupport
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import TDLibClient
import Testing

/// `POST /v1/chats/{chat_id}/messages` against the fake TDLib. The fake answers
/// `sendMessage` with a pending message under `Fixtures.localMessageId(n)` for the n-th send;
/// each test hands the sender Telegram's verdict for it in advance, so the route returns at once.
@Suite struct SendRouteTests {
    func succeed(_ app: App, send n: Int, id: Int64, text: String, chatId: Int64 = Fixtures.channelId, replyTo: Int64? = nil) async -> JSONBox {
        let final = Fixtures.sentMessage(chatId: chatId, id: id, text: text, replyTo: replyTo)
        let update = Fixtures.updateMessageSendSucceeded(final, oldMessageId: Fixtures.localMessageId(n))
        await app.deps.sender.observe(update)
        return update
    }

    @Test func sendAnswers201WithTheSentMessageAndItIsStreamedOnce() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let (_, token) = try await app.makeGrant(scopes: [.messagesRead, .messagesSend])
        let update = await succeed(app, send: 1, id: 1530, text: "Thanks, fixed in 2.4.1", replyTo: 1523)
        try await app.application.test(.router) { client in
            let before = try await client.call(.get, "/v1/events?since=0", token: token).json["head_seq"]?.intValue ?? 0
            let sent = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: token, body: ["text": "Thanks, fixed in 2.4.1", "reply_to": "1523"])
            #expect(sent.status == 201)
            let message = sent.json["message"]
            #expect(message?["id"] == "1530" && message?["chat_id"] == .id(Fixtures.channelId))
            #expect(message?["is_outgoing"] == true && message?["text"] == "Thanks, fixed in 2.4.1")
            #expect(message?["reply_to"] == ["chat_id": .id(Fixtures.channelId), "message_id": "1523"])
            #expect(message?["link"] == "https://t.me/acmeupdates/1530")

            let request = try #require(await app.tdlib.requests(ofType: "sendMessage").first?.object)
            #expect(request.int64("chat_id") == Fixtures.channelId)
            #expect(request.object("input_message_content")?.object("text")?.string("text") == "Thanks, fixed in 2.4.1")
            #expect(request.object("reply_to")?.int64("message_id") == MessageId.toInternal(1523))

            // The daemon hands every update to the monitor too: the pending copy is skipped and
            // the final one becomes the one and only message.new.
            let pending = Fixtures.pendingMessage(chatId: Fixtures.channelId, localId: Fixtures.localMessageId(1), text: "Thanks, fixed in 2.4.1", replyTo: 1523)
            await app.deps.monitor.handle(update: Fixtures.updateNewMessage(pending))
            await app.deps.monitor.handle(update: update)
            let events = try await client.call(.get, "/v1/events?since=\(before)&types=message.new", token: token)
            let new = events.json["events"]?.arrayValue ?? []
            #expect(new.count == 1)
            #expect(new.first?["message"]?["id"] == "1530" && new.first?["message"]?["is_outgoing"] == true)
        }
    }

    @Test func theAdminTokenSendsToMonitoredChats() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        _ = await succeed(app, send: 1, id: 1600, text: "from tgw", chatId: Fixtures.groupId)
        try await app.application.test(.router) { client in
            let sent = try await client.call(.post, "/v1/chats/\(Fixtures.groupId)/messages", token: App.adminToken, body: ["text": "from tgw"])
            #expect(sent.status == 201 && sent.json["message"]?["id"] == "1600")
            let unmonitored = try await client.call(.post, "/v1/chats/\(Fixtures.privateChatId)/messages", token: App.adminToken, body: ["text": "hi"])
            #expect(unmonitored.status == 403 && unmonitored.code == "chat_not_granted")
            let me = try await client.call(.get, "/v1/me", token: App.adminToken)
            #expect(me.json["grant"]?["scopes"]?.arrayValue?.contains("messages:send") == true)
        }
        #expect(await app.tdlib.requests(ofType: "sendMessage").count == 1)
    }

    @Test func refusalsSendNothing() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let (_, reader) = try await app.makeGrant(scopes: [.messagesRead, .chatsRead])
        let (_, sender) = try await app.makeGrant(scopes: [.messagesSend], chats: .list([Fixtures.channelId, Fixtures.basicGroupChatId]))
        let path = "/v1/chats/\(Fixtures.channelId)/messages"
        try await app.application.test(.router) { client in
            let noScope = try await client.call(.post, path, token: reader, body: ["text": "hi"])
            #expect(noScope.status == 403 && noScope.code == "insufficient_scope" && noScope.json["error"]?["details"]?["required"] == "messages:send")
            let notGranted = try await client.call(.post, "/v1/chats/\(Fixtures.groupId)/messages", token: sender, body: ["text": "hi"])
            #expect(notGranted.status == 403 && notGranted.code == "chat_not_granted")
            let notMonitored = try await client.call(.post, "/v1/chats/\(Fixtures.basicGroupChatId)/messages", token: sender, body: ["text": "hi"])
            #expect(notMonitored.status == 403 && notMonitored.code == "chat_not_granted")
            let missing = try await client.call(.post, path, token: sender, body: [:])
            #expect(missing.status == 400 && missing.json["error"]?["details"]?["field"] == "text")
            let empty = try await client.call(.post, path, token: sender, body: ["text": "   "])
            #expect(empty.status == 400 && empty.json["error"]?["details"]?["reason"] == "empty")
            let long = try await client.call(.post, path, token: sender, body: ["text": .string(String(repeating: "x", count: 4097))])
            #expect(long.status == 400 && long.json["error"]?["details"]?["reason"] == "too_long")
            let badReply = try await client.call(.post, path, token: sender, body: ["text": "hi", "reply_to": "abc"])
            #expect(badReply.status == 400 && badReply.json["error"]?["details"]?["field"] == "reply_to")
            let numericReply = try await client.call(.post, path, token: sender, body: ["text": "hi", "reply_to": 5])
            #expect(numericReply.status == 400 && numericReply.json["error"]?["details"]?["field"] == "reply_to")
            await app.telegram.set(state: .waitPhoneNumber)
            let signedOut = try await client.call(.post, path, token: sender, body: ["text": "hi"])
            #expect(signedOut.status == 503 && signedOut.code == "not_logged_in")
            await app.telegram.set(state: .ready)
            await app.telegram.set(connection: .connecting)
            let offline = try await client.call(.post, path, token: sender, body: ["text": "hi"])
            #expect(offline.status == 503 && offline.code == "telegram_unavailable")
        }
        #expect(await app.tdlib.requests(ofType: "sendMessage").isEmpty)
    }

    @Test func sendsAreRateLimited() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let (_, token) = try await app.makeGrant(scopes: [.messagesSend])
        await app.telegram.set(state: .waitPhoneNumber)
        try await app.application.test(.router) { client in
            for _ in 0..<MessageSender.sendsPerMinute {
                let reply = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: token, body: ["text": "hi"])
                #expect(reply.code == "not_logged_in")
            }
            let limited = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: token, body: ["text": "hi"])
            #expect(limited.status == 429 && limited.code == "rate_limited" && limited.headers[.retryAfter] != nil)
            app.clock.advance(by: .seconds(61))
            let later = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: token, body: ["text": "hi"])
            #expect(later.code == "not_logged_in")
        }
    }

    @Test func revokingStopsSendingAtOnce() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        let (grant, token) = try await app.makeGrant(scopes: [.messagesSend])
        _ = await succeed(app, send: 1, id: 1700, text: "one")
        try await app.application.test(.router) { client in
            let first = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: token, body: ["text": "one"])
            #expect(first.status == 201)
            let revoke = try await client.call(.delete, "/v1/admin/grants/\(grant.id)", token: App.adminToken)
            #expect(revoke.status == 204)
            let second = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: token, body: ["text": "two"])
            #expect(second.status == 401 && second.code == "token_revoked")
        }
        #expect(await app.tdlib.requests(ofType: "sendMessage").count == 1)
    }

    @Test func anAccessRequestForSendingIsApprovedOrNarrowed() async throws {
        let app = try await App()
        try await app.monitorDefaults()
        try await app.application.test(.router) { client in
            let body: JSONValue = ["name": "Volgenic", "description": "Replies to customers.", "scopes": ["messages:read", "messages:send"], "requested_chats": [.id(Fixtures.channelId)]]
            // The owner unticks sending: the grant can read but not send.
            let narrowed = try await client.call(.post, "/v1/access-requests", body: body)
            let narrowedId = try #require(narrowed.json["request_id"]?.stringValue)
            let list = try await client.call(.get, "/v1/admin/access-requests", token: App.adminToken)
            #expect(list.json["access_requests"]?[0]?["scopes"] == ["messages:read", "messages:send"])
            let readOnly = try await client.call(.post, "/v1/admin/access-requests/\(narrowedId)/approve", token: App.adminToken, body: ["chat_ids": [.id(Fixtures.channelId)], "scopes": ["messages:read"]])
            #expect(readOnly.json["scopes"] == ["messages:read"])
            app.clock.advance(by: .seconds(3))
            let readToken = try #require(try await client.call(.get, "/v1/access-requests/\(narrowedId)").json["token"]?.stringValue)
            let refused = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: readToken, body: ["text": "hi"])
            #expect(refused.status == 403 && refused.code == "insufficient_scope")

            // The owner keeps it: the grant can send.
            let full = try await client.call(.post, "/v1/access-requests", body: body)
            let fullId = try #require(full.json["request_id"]?.stringValue)
            let approved = try await client.call(.post, "/v1/admin/access-requests/\(fullId)/approve", token: App.adminToken, body: ["chat_ids": [.id(Fixtures.channelId)]])
            #expect(approved.json["scopes"] == ["messages:read", "messages:send"])
            app.clock.advance(by: .seconds(3))
            let sendToken = try #require(try await client.call(.get, "/v1/access-requests/\(fullId)").json["token"]?.stringValue)
            _ = await succeed(app, send: 1, id: 1800, text: "hello")
            let sent = try await client.call(.post, "/v1/chats/\(Fixtures.channelId)/messages", token: sendToken, body: ["text": "hello"])
            #expect(sent.status == 201 && sent.json["message"]?["id"] == "1800")
        }
    }
}
