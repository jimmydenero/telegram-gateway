import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

@Suite struct MessageReaderTests {
    struct Setup {
        let core: Core
        let reader: MessageReader
        let telegram: FakeTelegram
        init() async throws {
            core = try await Core()
            try await core.monitorDefaults()
            await ReadFixtures.install(core.tdlib)
            telegram = FakeTelegram(state: .ready, tdlib: core.tdlib)
            reader = MessageReader(grants: core.grants, translator: core.translator, telegram: telegram, rateLimiter: RateLimiter(clock: core.clock))
        }

        /// What must never be sent while marking read: opening the chat, going online, typing.
        func forbiddenRequests() async -> [String] {
            await core.tdlib.requests.compactMap { request -> String? in
                let object = request.object
                switch object.type {
                case "openChat", "sendChatAction", "setOption": return object.type
                default: return nil
                }
            }
        }
    }

    @Test func readSendsForceReadForTheNewestMessageWithoutOpeningTheChat() async throws {
        let s = try await Setup()
        let chat = try await s.reader.markRead(chat: Fixtures.channelId, as: .admin)
        let view = try #require(await s.core.tdlib.requests(ofType: "viewMessages").last?.object)
        #expect(view.int64("chat_id") == Fixtures.channelId)
        #expect(view.array("message_ids")?.compactMap(Translator.int64) == [MessageId.toInternal(ReadFixtures.newestMessageId)])
        #expect(view.bool("force_read") == true)
        #expect(view.object("source")?.type == "messageSourceChatHistory")
        #expect(chat.state?.unreadCount == 0)
        #expect(chat.state?.lastReadInboxMessageId == ReadFixtures.newestMessageId)
        #expect(await s.core.tdlib.requests(ofType: "readAllChatMentions").isEmpty)
        #expect(await s.forbiddenRequests().isEmpty)
    }

    @Test func readUpToAMessageAndClearMentions() async throws {
        let s = try await Setup()
        let chat = try await s.reader.markRead(chat: Fixtures.channelId, upTo: 1529, mentions: true, as: .admin)
        let view = try #require(await s.core.tdlib.requests(ofType: "viewMessages").last?.object)
        #expect(view.array("message_ids")?.compactMap(Translator.int64) == [MessageId.toInternal(1529)])
        #expect(await s.core.tdlib.requests(ofType: "readAllChatMentions").count == 1)
        #expect(chat.state?.unreadCount == 1)
        #expect(chat.state?.unreadMentionCount == 0)
        #expect(await s.forbiddenRequests().isEmpty)
    }

    @Test func withoutTheScopeNothingIsSent() async throws {
        let s = try await Setup()
        let (sender, _) = try await s.core.makeGrant(scopes: [.messagesRead, .chatsRead, .messagesSend, .chatsManage])
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .app(sender)) }?.code == "insufficient_scope")
        let (revoked, _) = try await s.core.makeGrant(scopes: [.messagesMarkRead])
        try await s.core.grants.revoke(revoked.id)
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .app(revoked)) }?.code == "token_revoked")
        let (elsewhere, _) = try await s.core.makeGrant(scopes: [.messagesMarkRead], chats: .list([Fixtures.groupId]))
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .app(elsewhere)) }?.code == "chat_not_granted")
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.privateChatId, as: .admin) }?.code == "chat_not_granted")
        #expect(await s.core.tdlib.requests(ofType: "viewMessages").isEmpty)
        #expect(await s.core.tdlib.requests(ofType: "readAllChatMentions").isEmpty)
    }

    @Test func grantedAppCanRead() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesMarkRead])
        _ = try await s.reader.markRead(chat: Fixtures.channelId, mentions: true, as: .app(grant))
        #expect(await s.core.tdlib.requests(ofType: "viewMessages").count == 1)
        #expect(await s.core.tdlib.requests(ofType: "readAllChatMentions").count == 1)
    }

    @Test func rateLimitHoldsAtSixtyAMinutePerToken() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesMarkRead])
        for _ in 0..<MessageReader.readsPerMinute { _ = try await s.reader.markRead(chat: Fixtures.channelId, as: .app(grant)) }
        let limited = await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .app(grant)) }
        #expect(limited?.code == "rate_limited")
        #expect(await s.core.tdlib.requests(ofType: "viewMessages").count == MessageReader.readsPerMinute)
        // The budget is per token: the admin is not held up by the app.
        _ = try await s.reader.markRead(chat: Fixtures.channelId, as: .admin)
        s.core.clock.advance(by: .seconds(61))
        _ = try await s.reader.markRead(chat: Fixtures.channelId, as: .app(grant))
    }

    @Test func needsALiveSessionAndMapsTelegramErrors() async throws {
        let s = try await Setup()
        await s.telegram.set(state: .waitPhoneNumber)
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .admin) }?.code == "not_logged_in")
        await s.telegram.set(state: .ready)
        await s.core.tdlib.on("viewMessages") { _ in throw TDLibError(code: 429, message: "Too Many Requests: retry after 5") }
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .admin) }?.code == "rate_limited")
        await s.core.tdlib.on("viewMessages") { _ in throw TDLibError(code: 400, message: "MESSAGE_ID_INVALID") }
        #expect(await apiError { try await s.reader.markRead(chat: Fixtures.channelId, as: .admin) }?.code == "send_failed")
        #expect(await s.forbiddenRequests().isEmpty)
    }

    @Test func theReadArrivesAsOneChatReadEvent() async throws {
        let s = try await Setup()
        // TDLib announced the chat with 3 unread before the read.
        _ = try await s.core.translator.chatInfo(Fixtures.channelId, refresh: true)
        let before = try await s.core.eventLog.headSeq()
        let chat = try await s.reader.markRead(chat: Fixtures.channelId, as: .admin)
        #expect(chat.state?.unreadCount == 0)
        #expect(try await s.core.eventLog.headSeq() == before)
        let update = Fixtures.updateChatReadInbox(chatId: Fixtures.channelId, lastRead: ReadFixtures.newestMessageId, unread: 0)
        await s.core.monitor.handle(update: update)
        await s.core.monitor.handle(update: update)
        let events = try await s.core.eventLog.page(since: before, limit: 100).events
        #expect(events.filter { $0.type == .chatRead }.count == 1)
    }
}
