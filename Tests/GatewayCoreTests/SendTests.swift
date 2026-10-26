import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

/// Sending through `MessageSender` against the fake TDLib. Nothing leaves the process: the
/// fake answers `sendMessage` with a pending message, and each test pushes the outcome.
@Suite struct SendTests {
    struct Setup {
        let core: Core
        let telegram: FakeTelegram
        let sender: MessageSender

        init(timeout: Duration = .seconds(30)) async throws {
            core = try await Core()
            try await core.monitorDefaults()
            telegram = FakeTelegram(state: .ready, tdlib: core.tdlib)
            sender = MessageSender(
                grants: core.grants, translator: core.translator, telegram: telegram,
                rateLimiter: RateLimiter(clock: core.clock), clock: core.clock, timeout: timeout
            )
        }

        func sendRequests() async -> [JSONObject] {
            await core.tdlib.requests(ofType: "sendMessage").map(\.object)
        }

        /// Starts a send and waits until it has reached TDLib and is waiting for the verdict.
        func startSend(_ text: String, to chatId: Int64 = Fixtures.channelId, replyTo: Int64? = nil, as principal: Principal) async throws -> Task<Message, any Error> {
            let sender = sender
            let task = Task { try await sender.send(text, to: chatId, replyTo: replyTo, as: principal) }
            let deadline = ContinuousClock.now + .seconds(5)
            while await sender.waitingCount == 0 {
                if ContinuousClock.now > deadline { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            return task
        }
    }

    @Test func sendReachesTDLibAndReturnsTheFinalMessage() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        let task = try await s.startSend("Thanks, fixed in 2.4.1", replyTo: 1523, as: .app(grant))

        let requests = await s.sendRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.int64("chat_id") == Fixtures.channelId)
        let content = try #require(request.object("input_message_content"))
        #expect(content.type == "inputMessageText")
        #expect(content.object("text")?.string("text") == "Thanks, fixed in 2.4.1")
        #expect(content.bool("clear_draft") == false)
        #expect(request.object("reply_to")?.type == "inputMessageReplyToMessage")
        #expect(request.object("reply_to")?.int64("message_id") == MessageId.toInternal(1523))

        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "Thanks, fixed in 2.4.1", replyTo: 1523)
        await s.sender.observe(Fixtures.updateMessageSendSucceeded(final, oldMessageId: Fixtures.localMessageId(1)))
        let message = try await task.value
        #expect(message.id == 1530)
        #expect(message.chatId == Fixtures.channelId)
        #expect(message.isOutgoing)
        #expect(message.text == "Thanks, fixed in 2.4.1")
        #expect(message.replyTo == ReplyTo(chatId: Fixtures.channelId, messageId: 1523))
        #expect(message.sender.id == Fixtures.ownerId)
        #expect(message.link == "https://t.me/acmeupdates/1530")
    }

    @Test func aVerdictThatArrivesBeforeTheResponseIsNotLost() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1531, text: "early")
        await s.sender.observe(Fixtures.updateMessageSendSucceeded(final, oldMessageId: Fixtures.localMessageId(1)))
        let message = try await s.sender.send("early", to: Fixtures.channelId, as: .app(grant))
        #expect(message.id == 1531)
    }

    @Test func withoutTheScopeNothingIsSent() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesRead, .chatsRead])
        let error = await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }
        #expect(error?.code == "insufficient_scope")
        #expect(error?.details["required"] == "messages:send")
        #expect(await s.sendRequests().isEmpty)
    }

    @Test func ungrantedOrUnmonitoredChatsAreRefused() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend], chats: .list([Fixtures.channelId, Fixtures.basicGroupChatId]))
        // Monitored, not granted.
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.groupId, as: .app(grant)) }?.code == "chat_not_granted")
        // Granted, not monitored.
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.basicGroupChatId, as: .app(grant)) }?.code == "chat_not_granted")
        // The admin token (tgw send) reaches monitored chats only.
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.privateChatId, as: .admin) }?.code == "chat_not_granted")
        // Monitoring stops: the chat is out of reach at once.
        try await s.core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId]))
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }?.code == "chat_not_granted")
        #expect(await s.sendRequests().isEmpty)
    }

    @Test func emptyAndOverlongTextAreRefused() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        let empty = await apiError { try await s.sender.send(" \n ", to: Fixtures.channelId, as: .app(grant)) }
        #expect(empty?.code == "invalid_request" && empty?.details["field"] == "text" && empty?.details["reason"] == "empty")
        let long = await apiError { try await s.sender.send(String(repeating: "a", count: 4097), to: Fixtures.channelId, as: .app(grant)) }
        #expect(long?.code == "invalid_request" && long?.details["reason"] == "too_long" && long?.details["max_length"] == 4096)
        // Telegram counts UTF-16 code units: 2048 emoji are 4096 units, one more is too many.
        #expect(throws: Never.self) { try MessageSender.validate(text: String(repeating: "😀", count: 2048)) }
        #expect(throws: APIError.self) { try MessageSender.validate(text: String(repeating: "😀", count: 2049)) }
        #expect(await s.sendRequests().isEmpty)
    }

    @Test func telegramFailureComesBackAsAnError() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        let task = try await s.startSend("hi", as: .app(grant))
        let failed = Fixtures.pendingMessage(chatId: Fixtures.channelId, localId: Fixtures.localMessageId(1), text: "hi")
        await s.sender.observe(Fixtures.updateMessageSendFailed(failed, oldMessageId: Fixtures.localMessageId(1), code: 403, error: "CHAT_WRITE_FORBIDDEN"))
        let error = await apiError { try await task.value }
        #expect(error?.status == 502 && error?.code == "send_failed")
        #expect(error?.details["reason"] == "CHAT_WRITE_FORBIDDEN" && error?.details["telegram_code"] == 403)
    }

    @Test func aRefusedRequestComesBackAsAnError() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        await s.core.tdlib.on("sendMessage") { _ in throw TDLibError(code: 400, message: "Have no write access to the chat") }
        let error = await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }
        #expect(error?.code == "send_failed" && error?.details["telegram_code"] == 400)
        await s.core.tdlib.on("sendMessage") { _ in throw TDLibError(code: 429, message: "Too Many Requests: retry after 17") }
        let flood = await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }
        #expect(flood?.code == "rate_limited" && flood?.details["retry_after"] == 17)
    }

    @Test func noVerdictTimesOut() async throws {
        let s = try await Setup(timeout: .seconds(30))
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        let task = try await s.startSend("hi", as: .app(grant))
        try await s.core.clock.waitForSleepers(1)
        s.core.clock.advance(by: .seconds(31))
        let error = await apiError { try await task.value }
        #expect(error?.status == 504 && error?.code == "send_timeout")
        #expect(await s.sender.waitingCount == 0)
    }

    @Test func revokingStopsSending() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        try await s.core.grants.revoke(grant.id)
        // The principal was resolved before the revocation; the sender checks again.
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }?.code == "token_revoked")
        #expect(await s.sendRequests().isEmpty)
    }

    @Test func sendsAreRateLimitedPerToken() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        // Telegram is signed out, so each send stops after the rate limit with a 503.
        await s.telegram.set(state: .waitPhoneNumber)
        for _ in 0..<MessageSender.sendsPerMinute {
            #expect(await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }?.code == "not_logged_in")
        }
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .app(grant)) }?.code == "rate_limited")
        // Another token has its own budget.
        #expect(await apiError { try await s.sender.send("hi", to: Fixtures.channelId, as: .admin) }?.code == "not_logged_in")
        #expect(await s.sendRequests().isEmpty)
    }

    @Test func theSentMessageIsRecordedOnceAsMessageNew() async throws {
        let s = try await Setup()
        let pending = Fixtures.pendingMessage(chatId: Fixtures.channelId, localId: Fixtures.localMessageId(1), text: "hello")
        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1532, text: "hello")
        let before = try await s.core.eventLog.headSeq()
        // TDLib reports the pending copy, then the final one.
        await s.core.monitor.handle(update: Fixtures.updateNewMessage(pending))
        await s.core.monitor.handle(update: Fixtures.updateMessageSendSucceeded(final, oldMessageId: Fixtures.localMessageId(1)))
        let page = try await s.core.eventLog.page(since: before, limit: 10, types: [.messageNew], chatIds: nil)
        #expect(page.events.count == 1)
        guard case .message(let message) = page.events.first?.payload else {
            Issue.record("expected a message payload")
            return
        }
        #expect(message.id == 1532 && message.isOutgoing && message.text == "hello")
    }
}
