import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

/// What a client needs to mirror the user's Telegram: formatting, reactions, polls, topics,
/// service message text, read state and list position.
@Suite struct MirrorTranslatorTests {
    func translateNew(_ core: Core, _ message: JSONBox) async throws -> Message? {
        guard case .messageNew(let tm) = try await core.translator.translate(update: Fixtures.updateNewMessage(message)).first else { return nil }
        return tm.message
    }

    @Test func formattingEntities() async throws {
        let core = try await Core()
        let text = "Bold italic link code\nlet x = 1\nquote 🙂"
        let message = Fixtures.message(chatId: Fixtures.groupId, id: 1, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent(text, entities: [
            Fixtures.entity("textEntityTypeItalic", offset: 5, length: 6),
            Fixtures.entity("textEntityTypeBold", offset: 0, length: 11),
            Fixtures.entity("textEntityTypeTextUrl", offset: 12, length: 4, extra: ["url": "https://acme.example"]),
            Fixtures.entity("textEntityTypeUnderline", offset: 12, length: 4),
            Fixtures.entity("textEntityTypeStrikethrough", offset: 0, length: 4),
            Fixtures.entity("textEntityTypeSpoiler", offset: 5, length: 6),
            Fixtures.entity("textEntityTypeCode", offset: 17, length: 4),
            Fixtures.entity("textEntityTypePreCode", offset: 22, length: 9, extra: ["language": "swift"]),
            Fixtures.entity("textEntityTypePre", offset: 22, length: 3),
            Fixtures.entity("textEntityTypeExpandableBlockQuote", offset: 32, length: 8),
            Fixtures.entity("textEntityTypeCustomEmoji", offset: 38, length: 2, extra: ["custom_emoji_id": "5368324170671202286"]),
            Fixtures.entity("textEntityTypePhoneNumber", offset: 0, length: 1),
        ]))
        let m = try #require(try await translateNew(core, message))
        // Sorted by offset, the enclosing span first; unmodelled types still dropped.
        #expect(m.entities == [
            Entity(type: .bold, offset: 0, length: 11),
            Entity(type: .strikethrough, offset: 0, length: 4),
            Entity(type: .italic, offset: 5, length: 6),
            Entity(type: .spoiler, offset: 5, length: 6),
            Entity(type: .textLink, offset: 12, length: 4, url: "https://acme.example"),
            Entity(type: .underline, offset: 12, length: 4),
            Entity(type: .code, offset: 17, length: 4),
            Entity(type: .pre, offset: 22, length: 9, language: "swift"),
            Entity(type: .pre, offset: 22, length: 3),
            Entity(type: .blockquote, offset: 32, length: 8),
            Entity(type: .customEmoji, offset: 38, length: 2, customEmojiId: "5368324170671202286"),
        ])
        let json = m.json["entities"]
        #expect(json?[0] == ["type": "bold", "offset": 0, "length": 11])
        #expect(json?[7] == ["type": "pre", "offset": 22, "length": 9, "language": "swift"])
        #expect(json?[8] == ["type": "pre", "offset": 22, "length": 3, "language": nil])
        #expect(json?[10] == ["type": "custom_emoji", "offset": 38, "length": 2, "custom_emoji_id": "5368324170671202286"])
    }

    @Test func utf16FormattingAndLegacyMessageDecode() async throws {
        let core = try await Core()
        let message = Fixtures.message(chatId: Fixtures.groupId, id: 1, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("🙂bold", entities: [
            Fixtures.entity("textEntityTypeBold", offset: 2, length: 4),
            Fixtures.entity("textEntityTypeBlockQuote", offset: 0, length: 6),
        ]))
        let translated = try #require(try await translateNew(core, message))
        #expect(translated.entities.first?.type == .blockquote)
        let bold = try #require(translated.entities.last)
        #expect((translated.text as NSString).substring(with: NSRange(location: bold.offset, length: bold.length)) == "bold")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(translated)) as? [String: Any])
        for key in ["reactions", "topicId", "poll"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.json["reactions"] == .null && decoded.json["topic_id"] == .null && decoded.json["poll"] == .null)
        #expect(decoded.text == "🙂bold")
    }

    @Test func reactionsOnTheMessageAndAsUpdates() async throws {
        let core = try await Core()
        let info = Fixtures.interactionInfo(reactions: [("👍", nil, 5, true), (nil, "5368324170671202286", 2, false)], viewCount: 900, paid: 3)
        let message = Fixtures.message(chatId: Fixtures.channelId, id: 412, sender: Fixtures.chatSender(Fixtures.channelId), content: Fixtures.textContent("v2.4"), interactionInfo: info)
        let m = try #require(try await translateNew(core, message))
        // Paid (Star) reactions retain their count with both identifiers null.
        #expect(m.reactions == [
            Reaction(emoji: "👍", customEmojiId: nil, count: 5, chosen: true),
            Reaction(emoji: nil, customEmojiId: "5368324170671202286", count: 2, chosen: false),
            Reaction(emoji: nil, customEmojiId: nil, count: 3, chosen: false),
        ])
        #expect(m.json["reactions"]?[0] == ["emoji": "👍", "custom_emoji_id": nil, "count": 5, "chosen": true])

        // A view count change alone is not a reactions change.
        let views = Fixtures.interactionInfo(reactions: [("👍", nil, 5, true), (nil, "5368324170671202286", 2, false)], viewCount: 950, paid: 3)
        #expect(try await core.translator.translate(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 412, info: views)).isEmpty)
        let more = Fixtures.interactionInfo(reactions: [("👍", nil, 6, true)], viewCount: 950)
        let changed = try await core.translator.translate(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 412, info: more))
        #expect(changed == [.messageReactions(chatId: Fixtures.channelId, messageId: 412, [Reaction(emoji: "👍", customEmojiId: nil, count: 6, chosen: true)])])
        #expect(try await core.translator.translate(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 412, info: more)).isEmpty)
        // All reactions removed is a change.
        let none = Fixtures.interactionInfo(reactions: [], viewCount: 951)
        #expect(try await core.translator.translate(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 412, info: none)).count == 1)
        // After restart or memo eviction, a client may still have old reactions. Clear them.
        #expect(try await core.translator.translate(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 9999, info: none)) == [.messageReactions(chatId: Fixtures.channelId, messageId: 9999, [])])
        #expect(try await core.translator.translate(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 9999, info: none)).isEmpty)
    }

    @Test func pollsAndVotes() async throws {
        let core = try await Core()
        let content = Fixtures.pollContent(question: "Ship Friday?", options: [("Yes", 3, false), ("No", 1, false)])
        let message = Fixtures.message(chatId: Fixtures.groupId, id: 1600, sender: Fixtures.userSender(Fixtures.adaId), content: content)
        let m = try #require(try await translateNew(core, message))
        let poll = Poll(question: "Ship Friday?", options: [.init(text: "Yes", voterCount: 3, isChosen: false), .init(text: "No", voterCount: 1, isChosen: false)], totalVoterCount: 4, isClosed: false, isAnonymous: true, type: .regular)
        #expect(m.poll == poll && m.text == "" && m.rawContentType == "messagePoll")
        #expect(m.json["poll"] == [
            "question": "Ship Friday?",
            "options": [["text": "Yes", "voter_count": 3, "is_chosen": false], ["text": "No", "voter_count": 1, "is_chosen": false]],
            "total_voter_count": 4, "is_closed": false, "is_anonymous": true, "type": "regular",
        ])
        // The same poll again is nothing; a vote is poll.updated, never message.edited.
        #expect(try await core.translator.translate(update: Fixtures.updateMessageContent(chatId: Fixtures.groupId, id: 1600, content: content)).isEmpty)
        let voted = Fixtures.pollContent(question: "Ship Friday?", options: [("Yes", 4, true), ("No", 1, false)], isClosed: true, isAnonymous: false, quiz: true)
        let result = try await core.translator.translate(update: Fixtures.updateMessageContent(chatId: Fixtures.groupId, id: 1600, content: voted))
        let expected = Poll(question: "Ship Friday?", options: [.init(text: "Yes", voterCount: 4, isChosen: true), .init(text: "No", voterCount: 1, isChosen: false)], totalVoterCount: 5, isClosed: true, isAnonymous: false, type: .quiz)
        #expect(result == [.pollUpdated(chatId: Fixtures.groupId, messageId: 1600, expected)])
        // Messages without a poll carry null.
        let text = try #require(try await translateNew(core, Fixtures.message(chatId: Fixtures.groupId, id: 1601, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("hi"))))
        #expect(text.json["poll"] == .null && text.json["topic_id"] == .null && text.json["reactions"] == [])
    }

    @Test func forumTopics() async throws {
        let core = try await Core()
        let inTopic = Fixtures.message(chatId: Fixtures.groupId, id: 20, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("a"), topic: Fixtures.forumTopic(7))
        #expect(try await translateNew(core, inTopic)?.topicId == 7)
        #expect(try await translateNew(core, inTopic)?.json["topic_id"] == "7")
        // A reply thread is not a forum topic.
        let inThread = Fixtures.message(chatId: Fixtures.groupId, id: 21, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("b"), topic: Fixtures.threadTopic(15))
        #expect(try await translateNew(core, inThread)?.topicId == nil)
    }

    @Test func serviceMessagesGetText() async throws {
        let core = try await Core()
        await core.tdlib.add(user: Fixtures.user(id: 777, first: "Alan", last: "Turing"))
        func text(_ content: JSONObject, chatId: Int64 = Fixtures.groupId, sender: Int64 = Fixtures.adaId, outgoing: Bool = false) async throws -> String? {
            let m = Fixtures.message(chatId: chatId, id: 30, sender: Fixtures.userSender(sender), isOutgoing: outgoing, content: content)
            return try await translateNew(core, m)?.text
        }
        #expect(try await text(Fixtures.serviceContent("messageChatAddMembers", ["member_user_ids": [Int(Fixtures.adaId)]])) == "Ada Lovelace joined the group")
        #expect(try await text(Fixtures.serviceContent("messageChatAddMembers", ["member_user_ids": [777, Int(Fixtures.botId)]])) == "Ada Lovelace added Alan Turing and Acme Bot")
        #expect(try await text(Fixtures.serviceContent("messageChatJoinByLink")) == "Ada Lovelace joined the group via invite link")
        #expect(try await text(Fixtures.serviceContent("messageChatDeleteMember", ["user_id": Int(Fixtures.adaId)])) == "Ada Lovelace left the group")
        #expect(try await text(Fixtures.serviceContent("messageChatDeleteMember", ["user_id": 777])) == "Ada Lovelace removed Alan Turing")
        #expect(try await text(Fixtures.serviceContent("messageChatChangeTitle", ["title": "Acme"])) == "Ada Lovelace changed the group name to \u{201C}Acme\u{201D}")
        #expect(try await text(Fixtures.serviceContent("messagePinMessage", ["message_id": 1])) == "Ada Lovelace pinned a message")
        #expect(try await text(Fixtures.serviceContent("messageChatChangePhoto", ["photo": [:]])) == "Ada Lovelace changed the group photo")
        #expect(try await text(Fixtures.callContent(discardReason: "callDiscardReasonMissed", duration: 0), chatId: Fixtures.privateChatId) == "Missed call")
        #expect(try await text(Fixtures.callContent(isVideo: true, discardReason: "callDiscardReasonMissed", duration: 0), chatId: Fixtures.privateChatId, outgoing: true) == "Cancelled video call")
        #expect(try await text(Fixtures.callContent(discardReason: "callDiscardReasonHungUp", duration: 192), chatId: Fixtures.privateChatId, outgoing: true) == "Outgoing call (3:12)")
        #expect(try await text(Fixtures.callContent(discardReason: "callDiscardReasonHungUp", duration: 3725), chatId: Fixtures.privateChatId) == "Incoming call (1:02:05)")
        #expect(try await text(Fixtures.serviceContent("messageChatChangeTitle", ["title": "News"]), chatId: Fixtures.channelId) == "Ada Lovelace changed the channel name to \u{201C}News\u{201D}")
        // Kinds without a description keep empty text; raw_content_type still names them.
        let unknown = Fixtures.message(chatId: Fixtures.groupId, id: 31, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.serviceContent("messageChatSetTheme"))
        let m = try #require(try await translateNew(core, unknown))
        #expect(m.text == "" && m.rawContentType == "messageChatSetTheme")
    }

    @Test func chatStateFromUpdates() async throws {
        let core = try await Core()
        let chat = Fixtures.withState(
            Fixtures.supergroupChat(id: Fixtures.groupId, supergroupId: Fixtures.groupSupergroupId, title: "Acme Community", isChannel: false),
            unread: 4, mentions: 1, lastReadInbox: 1519, lastReadOutbox: 1500,
            positions: [Fixtures.chatPosition(order: "9221294780217032704", isPinned: true), Fixtures.chatPosition(folderId: 3, order: "5")]
        )
        let announced = try await core.translator.translate(update: Fixtures.updateNewChat(chat))
        let initial = ChatState(unreadCount: 4, unreadMentionCount: 1, lastReadInboxMessageId: 1519, lastReadOutboxMessageId: 1500, isPinned: true, order: "9221294780217032704")
        #expect(announced == [.chatState(chatId: Fixtures.groupId, initial)])
        #expect(try await core.translator.chatInfo(Fixtures.groupId).state == initial)

        var expected = initial
        func step(_ update: JSONBox, _ change: (inout ChatState) -> Void) async throws {
            change(&expected)
            #expect(try await core.translator.translate(update: update) == [.chatState(chatId: Fixtures.groupId, expected)])
        }
        try await step(Fixtures.updateChatReadInbox(chatId: Fixtures.groupId, lastRead: 1523, unread: 0)) { $0.unreadCount = 0; $0.lastReadInboxMessageId = 1523 }
        try await step(Fixtures.updateChatReadOutbox(chatId: Fixtures.groupId, lastRead: 1530)) { $0.lastReadOutboxMessageId = 1530 }
        try await step(Fixtures.updateChatUnreadMentionCount(chatId: Fixtures.groupId, count: 0)) { $0.unreadMentionCount = 0 }
        try await step(Fixtures.updateMessageMentionRead(chatId: Fixtures.groupId, id: 1523, count: 2)) { $0.unreadMentionCount = 2 }
        try await step(Fixtures.updateChatIsMarkedAsUnread(chatId: Fixtures.groupId, true)) { $0.isMarkedAsUnread = true }
        try await step(Fixtures.updateChatPosition(chatId: Fixtures.groupId, Fixtures.chatPosition(order: "9221294780217032705"))) { $0.isPinned = false; $0.order = "9221294780217032705" }
        // Archiving: TDLib removes the main position and adds an archive one.
        try await step(Fixtures.updateChatLastMessage(chatId: Fixtures.groupId, positions: [Fixtures.chatPosition(list: "chatListArchive", order: "77")])) { $0.order = "0"; $0.isArchived = true }
        try await step(Fixtures.updateChatNotificationSettings(chatId: Fixtures.groupId, useDefaultMute: false, muteFor: 3600)) { $0.isMuted = true }
        try await step(Fixtures.updateChatDraftMessage(chatId: Fixtures.groupId, positions: [Fixtures.chatPosition(order: "88")])) { $0.order = "88"; $0.isArchived = false }
        // A folder position or a repeated value changes nothing.
        #expect(try await core.translator.translate(update: Fixtures.updateChatPosition(chatId: Fixtures.groupId, Fixtures.chatPosition(folderId: 3, order: "6"))).isEmpty)
        #expect(try await core.translator.translate(update: Fixtures.updateChatReadOutbox(chatId: Fixtures.groupId, lastRead: 1530)).isEmpty)

        // Chats that follow their scope's default are muted with it.
        try await step(Fixtures.updateChatNotificationSettings(chatId: Fixtures.groupId, useDefaultMute: true, muteFor: 0)) { $0.isMuted = false }
        let scoped = try await core.translator.translate(update: Fixtures.updateScopeNotificationSettings(scope: "notificationSettingsScopeGroupChats", muteFor: 86400))
        expected.isMuted = true
        #expect(scoped == [.chatState(chatId: Fixtures.groupId, expected)])
        #expect(try await core.translator.translate(update: Fixtures.updateScopeNotificationSettings(scope: "notificationSettingsScopeChannelChats", muteFor: 86400)).isEmpty)
        // The memoised chat object carries the current state.
        #expect(try await core.translator.chatInfo(Fixtures.groupId).state == expected)
    }
}

@Suite struct MirrorMonitorTests {
    func events(_ core: Core, _ type: EventType) async throws -> [Event] {
        try await core.store.events(since: 0, limit: 1000, types: [type], chatIds: nil)
    }

    @Test func chatReadIsCoalescedToOnePerSecond() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        await core.monitor.handle(update: Fixtures.updateChatReadInbox(chatId: Fixtures.groupId, lastRead: 1520, unread: 3))
        var read = try await events(core, .chatRead)
        #expect(read.count == 1)
        let json = try #require(read.first?.json())
        #expect(json["unread_count"] == 3 && json["unread_mention_count"] == 0 && json["last_read_inbox_message_id"] == "1520")
        #expect(json["last_read_outbox_message_id"] == .null && json["chat"]?["unread_count"] == 3 && json["chat"]?["order"] == "0")
        #expect(json.objectValue?.keys == [
            "v", "seq", "type", "occurred_at", "recorded_at", "chat", "unread_count", "unread_mention_count",
            "last_read_inbox_message_id", "last_read_outbox_message_id", "is_marked_as_unread",
        ])
        // A burst within the second: one more event, with the last state, once the second has passed.
        await core.monitor.handle(update: Fixtures.updateChatReadInbox(chatId: Fixtures.groupId, lastRead: 1521, unread: 2))
        await core.monitor.handle(update: Fixtures.updateChatReadOutbox(chatId: Fixtures.groupId, lastRead: 1530))
        #expect(try await events(core, .chatRead).count == 1)
        try await core.clock.waitForSleepers(1)
        core.clock.advance(by: .seconds(1))
        await core.monitor.waitForCoalesced()
        read = try await events(core, .chatRead)
        #expect(read.count == 2)
        #expect(read.last?.json()["unread_count"] == 2 && read.last?.json()["last_read_outbox_message_id"] == "1530")
        // After the interval, the next change is emitted at once.
        core.clock.advance(by: .seconds(5))
        await core.monitor.handle(update: Fixtures.updateChatUnreadMentionCount(chatId: Fixtures.groupId, count: 1))
        #expect(try await events(core, .chatRead).count == 3)
        // A change undone within the interval emits nothing.
        await core.monitor.handle(update: Fixtures.updateChatUnreadMentionCount(chatId: Fixtures.groupId, count: 0))
        await core.monitor.handle(update: Fixtures.updateChatUnreadMentionCount(chatId: Fixtures.groupId, count: 1))
        try await core.clock.waitForSleepers(1)
        core.clock.advance(by: .seconds(1))
        await core.monitor.waitForCoalesced()
        #expect(try await events(core, .chatRead).count == 3)
        // The stored chat, and so the API, has the current state.
        #expect(try await core.store.chat(Fixtures.groupId)?.state?.unreadMentionCount == 1)
        // Chats that are not monitored produce nothing.
        await core.monitor.handle(update: Fixtures.updateChatReadInbox(chatId: Fixtures.privateChatId, lastRead: 5, unread: 0))
        #expect(try await events(core, .chatRead).allSatisfy { $0.chatId == Fixtures.groupId })
    }

    @Test func chatPositionPinsAtOnceOrderEveryTenSeconds() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        // Pinning is emitted at once.
        await core.monitor.handle(update: Fixtures.updateChatPosition(chatId: Fixtures.channelId, Fixtures.chatPosition(order: "100", isPinned: true)))
        var position = try await events(core, .chatPosition)
        #expect(position.count == 1)
        let json = try #require(position.first?.json())
        #expect(json["is_pinned"] == true && json["order"] == "100" && json["is_archived"] == false && json["chat"]?["is_pinned"] == true)
        #expect(json.objectValue?.keys == ["v", "seq", "type", "occurred_at", "recorded_at", "chat", "is_pinned", "order", "is_archived"])
        // Order alone, as with every new message: coalesced to one per ten seconds.
        await core.monitor.handle(update: Fixtures.updateChatLastMessage(chatId: Fixtures.channelId, positions: [Fixtures.chatPosition(order: "101", isPinned: true)]))
        await core.monitor.handle(update: Fixtures.updateChatLastMessage(chatId: Fixtures.channelId, positions: [Fixtures.chatPosition(order: "102", isPinned: true)]))
        #expect(try await events(core, .chatPosition).count == 1)
        try await core.clock.waitForSleepers(1)
        core.clock.advance(by: .seconds(9))
        #expect(try await events(core, .chatPosition).count == 1)
        core.clock.advance(by: .seconds(1))
        await core.monitor.waitForCoalesced()
        position = try await events(core, .chatPosition)
        #expect(position.count == 2 && position.last?.json()["order"] == "102")
        // Archiving is emitted at once even within the interval.
        await core.monitor.handle(update: Fixtures.updateChatLastMessage(chatId: Fixtures.channelId, positions: [Fixtures.chatPosition(list: "chatListArchive", order: "50")]))
        position = try await events(core, .chatPosition)
        #expect(position.count == 3 && position.last?.json()["is_archived"] == true && position.last?.json()["order"] == "0" && position.last?.json()["is_pinned"] == false)
        #expect(EventType.chatPosition.requiredScope == .chatsRead && EventType.chatRead.requiredScope == .chatsRead)
    }

    @Test func mutingIsAChatUpdate() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        await core.monitor.handle(update: Fixtures.updateChatNotificationSettings(chatId: Fixtures.channelId, useDefaultMute: false, muteFor: 3600))
        let updated = try await events(core, .chatUpdated)
        #expect(updated.count == 1)
        let json = try #require(updated.first?.json())
        #expect(json["changes"] == ["is_muted"] && json["chat"]?["is_muted"] == true && json["chat"]?["member_count"] == 12840)
        #expect(try await events(core, .chatRead).isEmpty)
        #expect(try await events(core, .chatPosition).isEmpty)
    }

    @Test func reactionsAndPollEvents() async throws {
        let core = try await Core()
        try await core.monitorDefaults()
        let content = Fixtures.pollContent(question: "Ship Friday?", options: [("Yes", 0, false), ("No", 0, false)])
        let message = Fixtures.message(chatId: Fixtures.groupId, id: 1600, sender: Fixtures.userSender(Fixtures.adaId), content: content)
        await core.monitor.handle(update: Fixtures.updateNewMessage(message))
        await core.monitor.handle(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.groupId, id: 1600, info: Fixtures.interactionInfo(reactions: [("🔥", nil, 1, false)])))
        let voted = Fixtures.pollContent(question: "Ship Friday?", options: [("Yes", 1, false), ("No", 0, false)])
        await core.monitor.handle(update: Fixtures.updateMessageContent(chatId: Fixtures.groupId, id: 1600, content: voted))
        // Not monitored: nothing.
        await core.monitor.handle(update: Fixtures.updateMessageInteractionInfo(chatId: Fixtures.privateChatId, id: 5, info: Fixtures.interactionInfo(reactions: [("🔥", nil, 1, false)])))

        let reactions = try await events(core, .messageReactions)
        #expect(reactions.count == 1)
        #expect(reactions.first?.json()["message_id"] == "1600" && reactions.first?.json()["chat"]?["id"] == .id(Fixtures.groupId))
        #expect(reactions.first?.json()["reactions"] == [["emoji": "🔥", "custom_emoji_id": nil, "count": 1, "chosen": false]])
        let polls = try await events(core, .pollUpdated)
        #expect(polls.count == 1)
        #expect(polls.first?.json()["message_id"] == "1600" && polls.first?.json()["poll"]?["total_voter_count"] == 1)
        #expect(polls.first?.json().objectValue?.keys == ["v", "seq", "type", "occurred_at", "recorded_at", "chat", "message_id", "poll"])
        #expect(try await events(core, .messageEdited).isEmpty)
        #expect(EventType.messageReactions.requiredScope == .messagesRead && EventType.pollUpdated.requiredScope == .messagesRead)
    }

    @Test func eventsRecordedBeforeTheseFieldsRenderNull() async throws {
        // A payload as version 1 stored it before read state, reactions, topics and polls.
        let core = try await Core()
        _ = try await core.appendMessageEvent(id: 1)
        var old = try #require(try await core.store.events(since: 0, limit: 1, types: nil, chatIds: nil).first)
        guard case .message(var message) = old.payload else { Issue.record("expected a message"); return }
        message.reactions = nil
        old.payload = .message(message)
        let json = old.json()
        #expect(json["message"]?["reactions"] == .null && json["message"]?["poll"] == .null && json["message"]?["topic_id"] == .null)
        #expect(json["chat"]?["unread_count"] == .null && json["chat"]?["order"] == .null && json["chat"]?["is_muted"] == .null)
        // And the stored JSON of such an event still decodes.
        let legacy = #"{"id":5,"type":"channel","title":"T"}"#
        let summary = try JSONDecoder().decode(ChatSummary.self, from: Data(legacy.utf8))
        #expect(summary.state == nil)
    }

    @Test func storeKeepsStateAcrossUpserts() async throws {
        let core = try await Core()
        let info = ChatInfo(id: Fixtures.groupId, type: .supergroup, title: "Acme Community", username: nil, memberCount: 1, photo: nil, state: ChatState(unreadCount: 2))
        try await core.store.upsertChat(info, now: core.clock.now)
        #expect(try await core.store.chat(Fixtures.groupId)?.state?.unreadCount == 2)
        // Only setChatState changes a stored state.
        var other = info
        other.state = ChatState(unreadCount: 9)
        other.title = "Renamed"
        try await core.store.upsertChat(other, now: core.clock.now)
        let stored = try await core.store.chat(Fixtures.groupId)
        #expect(stored?.state?.unreadCount == 2 && stored?.title == "Renamed")
        try await core.store.setChatState(chatId: Fixtures.groupId, ChatState(unreadCount: 0, isPinned: true))
        #expect(try await core.store.chat(Fixtures.groupId)?.state == ChatState(unreadCount: 0, isPinned: true))
    }
}
