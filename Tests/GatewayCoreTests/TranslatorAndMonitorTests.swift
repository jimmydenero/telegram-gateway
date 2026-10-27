import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

@Suite struct TranslatorTests {
    let text = "@acmebot the export in v2.3 fails on large files, see https://acme.example/issues/812 #bug"

    func textMessage(id: Int64 = 1523, chatId: Int64 = Fixtures.groupId) -> JSONBox {
        Fixtures.message(
            chatId: chatId, id: id, sender: Fixtures.userSender(Fixtures.adaId), date: 1_790_000_000,
            content: Fixtures.textContent(text, entities: [
                Fixtures.entity("textEntityTypeHashtag", offset: 80, length: 4),
                Fixtures.entity("textEntityTypeMention", offset: 0, length: 8),
                Fixtures.entity("textEntityTypeBold", offset: 9, length: 3),
                Fixtures.entity("textEntityTypeUrl", offset: 49, length: 30),
            ]),
            replyTo: (Fixtures.groupId, 1519)
        )
    }

    @Test func textMessageMatchesTheDocumentedExample() async throws {
        let core = try await Core()
        let result = try await core.translator.translate(update: Fixtures.updateNewMessage(textMessage()))
        guard case .messageNew(let tm) = result.first else { Issue.record("expected messageNew"); return }
        let m = tm.message
        #expect(m.id == 1523 && m.chatId == Fixtures.groupId)
        #expect(m.sender == Sender(type: .user, id: Fixtures.adaId, displayName: "Ada Lovelace", username: "ada", isBot: false))
        #expect(m.date == Date(timeIntervalSince1970: 1_790_000_000) && m.editDate == nil && !m.isOutgoing)
        #expect(m.text == text)
        // Sorted by offset; formatting kept.
        #expect(m.entities == [
            Entity(type: .mention, offset: 0, length: 8), Entity(type: .bold, offset: 9, length: 3),
            Entity(type: .url, offset: 49, length: 30), Entity(type: .hashtag, offset: 80, length: 4),
        ])
        #expect(m.replyTo == ReplyTo(chatId: Fixtures.groupId, messageId: 1519))
        #expect(m.forwardFrom == nil && m.media.isEmpty && m.mediaGroupId == nil)
        #expect(m.link == "https://t.me/acmecommunity/1523" && m.rawContentType == "messageText")
        #expect(tm.chat.summary == ChatSummary(id: Fixtures.groupId, type: .supergroup, title: "Acme Community", username: "acmecommunity", state: ChatState()))
        let json = m.json
        #expect(json["id"] == "1523" && json["chat_id"] == .string(String(Fixtures.groupId)))
        #expect(json["sender"]?["is_bot"] == false && json["edit_date"] == .null && json["media"] == [])
        #expect(json.objectValue?.keys == ["id", "chat_id", "sender", "date", "edit_date", "is_outgoing", "text", "entities", "reply_to", "forward_from", "media", "media_group_id", "link", "raw_content_type", "reactions", "topic_id", "poll"])
    }

    @Test func photoCaptionBecomesTextAndMediaIsStable() async throws {
        let core = try await Core()
        let message = Fixtures.message(chatId: Fixtures.channelId, id: 412, sender: Fixtures.chatSender(Fixtures.channelId), content: Fixtures.photoContent(caption: "v2.4 is out."), albumId: "778899")
        let result = try await core.translator.translate(update: Fixtures.updateNewMessage(message))
        guard case .messageNew(let tm) = result.first else { Issue.record("expected messageNew"); return }
        #expect(tm.message.text == "v2.4 is out." && tm.message.rawContentType == "messagePhoto")
        #expect(tm.message.sender == Sender(type: .chat, id: Fixtures.channelId, displayName: "Acme Product Updates", username: "acmeupdates", isBot: nil))
        #expect(tm.message.sender.json.objectValue?["is_bot"] == nil)
        #expect(tm.message.mediaGroupId == "778899")
        let media = try #require(tm.message.media.first)
        #expect(media.kind == .photo && media.mime == "image/jpeg" && media.size == 184320 && media.width == 1280 && media.height == 720)
        #expect(media.mediaId == Identifiers.mediaId(uniqueId: "AQADphoto1") && media.mediaId.hasPrefix("med_") && media.mediaId.count == 36)
        #expect(tm.media.first?.remoteId == "remote-photo-1")
        // Same unique id in another message → same media id.
        let again = Fixtures.message(chatId: Fixtures.channelId, id: 413, sender: Fixtures.chatSender(Fixtures.channelId), content: Fixtures.photoContent(caption: ""))
        guard case .messageNew(let tm2) = try await core.translator.translate(update: Fixtures.updateNewMessage(again)).first else { return }
        #expect(tm2.message.media.first?.mediaId == media.mediaId)
    }

    @Test func otherMediaKinds() async throws {
        let core = try await Core()
        func media(_ content: JSONObject) async throws -> Media? {
            let m = Fixtures.message(chatId: Fixtures.channelId, id: 9, sender: Fixtures.chatSender(Fixtures.channelId), content: content)
            guard case .messageNew(let tm) = try await core.translator.translate(update: Fixtures.updateNewMessage(m)).first else { return nil }
            return tm.message.media.first
        }
        let video = try await media(Fixtures.videoContent(caption: "c"))
        #expect(video?.kind == .video && video?.size == 20971520 && video?.durationSeconds == 42 && video?.fileName == "demo.mp4" && video?.mime == "video/mp4")
        let document = try await media(Fixtures.documentContent(caption: "c"))
        #expect(document?.kind == .document && document?.fileName == "report.pdf" && document?.width == nil)
        let sticker = try await media(Fixtures.stickerContent())
        #expect(sticker?.kind == .sticker && sticker?.mime == "image/webp" && sticker?.width == 512)
        let poll = Fixtures.message(chatId: Fixtures.channelId, id: 10, sender: Fixtures.chatSender(Fixtures.channelId), content: Fixtures.pollContent())
        guard case .messageNew(let tm) = try await core.translator.translate(update: Fixtures.updateNewMessage(poll)).first else { return }
        #expect(tm.message.text == "" && tm.message.media.isEmpty && tm.message.rawContentType == "messagePoll")
    }

    @Test func forwardOrigins() async throws {
        let core = try await Core()
        func origin(_ forward: JSONObject) async throws -> ForwardOrigin? {
            let m = Fixtures.message(chatId: Fixtures.groupId, id: 5, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("fwd"), forward: forward)
            guard case .messageNew(let tm) = try await core.translator.translate(update: Fixtures.updateNewMessage(m)).first else { return nil }
            return tm.message.forwardFrom
        }
        let channel = try await origin(Fixtures.forwardFromChannel(chatId: Fixtures.channelId, messageId: 88, date: 1_789_000_000))
        #expect(channel == ForwardOrigin(type: .chat, id: Fixtures.channelId, displayName: "Acme Product Updates", username: "acmeupdates", messageId: 88, date: Date(timeIntervalSince1970: 1_789_000_000)))
        let hidden = try await origin(Fixtures.forwardFromHiddenUser(name: "Someone", date: 1))
        #expect(hidden?.type == .hiddenUser && hidden?.displayName == "Someone" && hidden?.id == nil)
        #expect(hidden?.json["id"] == .null && hidden?.json["message_id"] == .null)
        let user = try await origin(Fixtures.forwardFromUser(userId: Fixtures.botId, date: 1))
        #expect(user?.type == .user && user?.displayName == "Acme Bot" && user?.username == "acmebot")
    }

    @Test func unknownSenderFallsBackToDeletedAccount() async throws {
        let core = try await Core()
        let m = Fixtures.message(chatId: Fixtures.groupId, id: 6, sender: Fixtures.userSender(42), content: Fixtures.textContent("x"))
        guard case .messageNew(let tm) = try await core.translator.translate(update: Fixtures.updateNewMessage(m)).first else { return }
        #expect(tm.message.sender.displayName == "Deleted Account" && tm.message.sender.id == 42)
    }

    @Test func outgoingMessagesStillBeingSentAreSkippedUntilSendSucceeded() async throws {
        let core = try await Core()
        let pending = Fixtures.message(chatId: Fixtures.groupId, id: 0, sender: Fixtures.userSender(Fixtures.adaId), isOutgoing: true, content: Fixtures.textContent("mine"), sendingState: ["@type": "messageSendingStatePending", "sending_id": 0])
        #expect(try await core.translator.translate(update: Fixtures.updateNewMessage(pending)).isEmpty)
        let sent = Fixtures.message(chatId: Fixtures.groupId, id: 1600, sender: Fixtures.userSender(Fixtures.adaId), isOutgoing: true, content: Fixtures.textContent("mine"))
        guard case .messageNew(let tm) = try await core.translator.translate(update: Fixtures.updateMessageSendSucceeded(sent, oldMessageId: 7)).first else { Issue.record("expected messageNew"); return }
        #expect(tm.message.isOutgoing && tm.message.id == 1600)
    }

    @Test func editsAreEmittedOncePerEditDate() async throws {
        let core = try await Core()
        let edited = Fixtures.message(chatId: Fixtures.groupId, id: 1523, sender: Fixtures.userSender(Fixtures.adaId), editDate: 1_790_000_115, content: Fixtures.textContent("new text"))
        await core.tdlib.add(message: edited)
        // Content update first, then the edited update: exactly one event, occurred_at = edit date.
        let first = try await core.translator.translate(update: Fixtures.updateMessageContent(chatId: Fixtures.groupId, id: 1523, content: Fixtures.textContent("new text")))
        guard case .messageEdited(let tm) = first.first else { Issue.record("expected messageEdited"); return }
        #expect(tm.message.text == "new text" && tm.message.editDate == Date(timeIntervalSince1970: 1_790_000_115))
        #expect(try await core.translator.translate(update: Fixtures.updateMessageEdited(chatId: Fixtures.groupId, id: 1523, editDate: 1_790_000_115)).isEmpty)
        // A later edit is a new event.
        let again = Fixtures.message(chatId: Fixtures.groupId, id: 1523, sender: Fixtures.userSender(Fixtures.adaId), editDate: 1_790_000_200, content: Fixtures.textContent("newer"))
        await core.tdlib.add(message: again)
        #expect(try await core.translator.translate(update: Fixtures.updateMessageEdited(chatId: Fixtures.groupId, id: 1523, editDate: 1_790_000_200)).count == 1)
        // A content change on a never-edited message (a link preview loading) is not an edit.
        let unedited = Fixtures.message(chatId: Fixtures.groupId, id: 1524, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("see https://acme.example"))
        await core.tdlib.add(message: unedited)
        #expect(try await core.translator.translate(update: Fixtures.updateMessageContent(chatId: Fixtures.groupId, id: 1524, content: Fixtures.textContent("see https://acme.example"))).isEmpty)
    }

    @Test func onlyPermanentDeletionsCount() async throws {
        let core = try await Core()
        let permanent = try await core.translator.translate(update: Fixtures.updateDeleteMessages(chatId: Fixtures.groupId, ids: [1520, 1521], permanent: true, fromCache: false))
        #expect(permanent == [.messageDeleted(chatId: Fixtures.groupId, messageIds: [1520, 1521])])
        #expect(try await core.translator.translate(update: Fixtures.updateDeleteMessages(chatId: Fixtures.groupId, ids: [1], permanent: false, fromCache: false)).isEmpty)
        #expect(try await core.translator.translate(update: Fixtures.updateDeleteMessages(chatId: Fixtures.groupId, ids: [1], permanent: true, fromCache: true)).isEmpty)
    }

    @Test func chatUpdatesResolveToChatIds() async throws {
        let core = try await Core()
        #expect(try await core.translator.translate(update: Fixtures.updateChatTitle(chatId: Fixtures.groupId, title: "New")) == [.chatChanged(chatId: Fixtures.groupId)])
        #expect(try await core.translator.translate(update: Fixtures.updateChatPhoto(chatId: Fixtures.groupId)) == [.chatChanged(chatId: Fixtures.groupId)])
        #expect(try await core.translator.translate(update: Fixtures.updateSupergroupFullInfo(supergroupId: Fixtures.groupSupergroupId, memberCount: 5)) == [.chatChanged(chatId: Fixtures.groupId)])
        #expect(try await core.translator.translate(update: Fixtures.updateSupergroup(Fixtures.supergroup(id: Fixtures.channelSupergroupId, username: "x", memberCount: 1, isChannel: true))) == [.chatChanged(chatId: Fixtures.channelId)])
        #expect(ChatIdArithmetic.chatId(supergroupId: 1234567890) == -1001234567890)
        #expect(ChatIdArithmetic.chatId(basicGroupId: 987654321) == -987654321)
        #expect(try await core.translator.translate(update: Fixtures.updateConnectionState("connectionStateReady")) == [.connectionState(.ready)])
        #expect(try await core.translator.translate(update: Fixtures.updateChatFolders([(3, "Product")])) == [.foldersChanged([(3, "Product")])])
        #expect(try await core.translator.translate(update: Fixtures.updateChatAddedToFolder(chatId: Fixtures.groupId, folderId: 3)) == [.folderMembership(folderId: 3, chatId: Fixtures.groupId, added: true)])
        #expect(try await core.translator.translate(update: JSONBox(["@type": "updateChatReadInbox", "chat_id": 1])).isEmpty)
    }

    @Test func chatInfoForEveryChatType() async throws {
        let core = try await Core()
        let channel = try await core.translator.chatInfo(Fixtures.channelId)
        #expect(channel == ChatInfo(id: Fixtures.channelId, type: .channel, title: "Acme Product Updates", username: "acmeupdates", memberCount: 12840, photo: ChatPhoto(mediaId: Identifiers.mediaId(uniqueId: "AQADchatphoto"), width: 640, height: 640), state: ChatState()))
        let group = try await core.translator.chatInfo(Fixtures.groupId)
        #expect(group.type == .supergroup && group.memberCount == 4200 && group.photo == nil)
        let priv = try await core.translator.chatInfo(Fixtures.privateChatId)
        #expect(priv == ChatInfo(id: Fixtures.privateChatId, type: .private, title: "Ada Lovelace", username: "ada", memberCount: nil, photo: nil, state: ChatState()))
        let basic = try await core.translator.chatInfo(Fixtures.basicGroupChatId)
        #expect(basic.type == .basicGroup && basic.memberCount == 12 && basic.username == nil)
        await core.tdlib.add(chat: Fixtures.secretChat(id: 77))
        #expect(await apiError { try await core.translator.chatInfo(77) }?.code == "chat_not_monitorable")
        #expect(await apiError { try await core.translator.chatInfo(404) }?.code == "chat_not_monitorable")
        let photo = try #require(try await core.translator.chatPhotoRecord(Fixtures.channelId))
        #expect(photo.remoteId == "big-AQADchatphoto" && photo.media.kind == .photo && photo.media.size == 40960)
        #expect(try await core.translator.lastMessageId(Fixtures.channelId) == MessageId.toInternal(411))
        #expect(channel.json(isMonitored: true).objectValue?.keys == [
            "id", "type", "title", "username", "member_count", "is_monitored", "photo", "unread_count", "unread_mention_count",
            "last_read_inbox_message_id", "last_read_outbox_message_id", "is_marked_as_unread", "is_pinned", "order", "is_archived", "is_muted",
        ])
    }

    @Test func historyIsNewestFirst() async throws {
        let core = try await Core()
        for id in [1, 2, 3] as [Int64] {
            await core.tdlib.add(message: Fixtures.message(chatId: Fixtures.groupId, id: id, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("m\(id)")))
        }
        let page = try await core.translator.history(chatId: Fixtures.groupId, fromInternalId: 0, offset: 0, limit: 10)
        #expect(page.map { $0.message.id } == [3, 2, 1])
    }
}

@Suite struct MonitorTests {
    @Test func monitoringChangesEmitStartedAndStopped() async throws {
        let core = try await Core()
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.channelId]))
        var page = try await core.eventLog.page(since: 0, limit: 10)
        #expect(page.events.map(\.type) == [.monitoringStarted])
        #expect(page.events[0].chat.title == "Acme Product Updates")
        #expect(page.events[0].payload == .monitoring(MonitoringInfo(source: .chat, folderId: nil, folderTitle: nil)))
        // The cursor starts at the chat's last message so nothing earlier is backfilled.
        #expect(try await core.store.cursor(chatId: Fixtures.channelId) == MessageId.toInternal(411))
        #expect(try await core.store.chat(Fixtures.channelId)?.title == "Acme Product Updates")

        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId]))
        page = try await core.eventLog.page(since: 1, limit: 10)
        #expect(page.events.map(\.type) == [.monitoringStopped, .monitoringStarted])
        #expect(page.events[0].chat.id == Fixtures.channelId && page.events[1].chat.id == Fixtures.groupId)
        #expect(try await core.store.cursor(chatId: Fixtures.channelId) == nil)
        #expect(await core.monitor.monitoredChatIds == [Fixtures.groupId])

        #expect(await apiError { try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [404])) }?.code == "chat_not_monitorable")
        #expect(await apiError { try await core.monitor.setMonitoredSet(MonitoredSet(folderIds: [9])) }?.code == "invalid_request")
    }

    @Test func messagesInMonitoredChatsAreRecordedOthersDropped() async throws {
        let core = try await Core()
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.channelId]))
        let photo = Fixtures.message(chatId: Fixtures.channelId, id: 412, sender: Fixtures.chatSender(Fixtures.channelId), content: Fixtures.photoContent(caption: "v2.4"))
        await core.monitor.handle(update: Fixtures.updateNewMessage(photo))
        let other = Fixtures.message(chatId: Fixtures.groupId, id: 1, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("private-ish"))
        await core.monitor.handle(update: Fixtures.updateNewMessage(other))
        let page = try await core.eventLog.page(since: 1, limit: 10)
        #expect(page.events.map(\.type) == [.messageNew])
        #expect(page.events[0].messageId == 412 && page.events[0].occurredAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try await core.store.cursor(chatId: Fixtures.channelId) == MessageId.toInternal(412))
        let mediaId = Identifiers.mediaId(uniqueId: "AQADphoto1")
        #expect(try await core.store.media(mediaId)?.remoteId == "remote-photo-1")
        #expect(try await core.store.mediaChatIds(mediaId) == [Fixtures.channelId])
        // The same message again (a duplicate update) is not recorded twice.
        await core.monitor.handle(update: Fixtures.updateNewMessage(photo))
        #expect(try await core.eventLog.headSeq() == 2)
    }

    @Test func editsAndDeletes() async throws {
        let core = try await Core()
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId]))
        let edited = Fixtures.message(chatId: Fixtures.groupId, id: 1523, sender: Fixtures.userSender(Fixtures.adaId), editDate: 1_790_000_115, content: Fixtures.textContent("fixed"))
        await core.tdlib.add(message: edited)
        await core.monitor.handle(update: Fixtures.updateMessageEdited(chatId: Fixtures.groupId, id: 1523, editDate: 1_790_000_115))
        await core.monitor.handle(update: Fixtures.updateDeleteMessages(chatId: Fixtures.groupId, ids: [1520, 1521], permanent: true, fromCache: false))
        let page = try await core.eventLog.page(since: 1, limit: 10)
        #expect(page.events.map(\.type) == [.messageEdited, .messageDeleted])
        #expect(page.events[0].occurredAt == Date(timeIntervalSince1970: 1_790_000_115))
        #expect(page.events[1].payload == .messageIds([1520, 1521]))
        #expect(page.events[1].json()["message_ids"] == ["1520", "1521"])
    }

    @Test func chatUpdatedWithChangesAndMemberCountCoalescing() async throws {
        let core = try await Core()
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId]))
        // Title change.
        await core.tdlib.add(chat: Fixtures.supergroupChat(id: Fixtures.groupId, supergroupId: Fixtures.groupSupergroupId, title: "Acme Community (official)", isChannel: false))
        await core.monitor.handle(update: Fixtures.updateChatTitle(chatId: Fixtures.groupId, title: "Acme Community (official)"))
        var page = try await core.eventLog.page(since: 1, limit: 10)
        #expect(page.events.count == 1)
        guard case .chat(let info, let changes) = page.events[0].payload else { Issue.record("payload"); return }
        #expect(changes == ["title"] && info.title == "Acme Community (official)")
        #expect(page.events[0].json()["chat"]?["is_monitored"] == true)
        // Member count: first change emits, second within 05:00 is coalesced, after 05:00 emits.
        await core.tdlib.add(supergroup: Fixtures.supergroup(id: Fixtures.groupSupergroupId, username: "acmecommunity", memberCount: 4201, isChannel: false))
        await core.monitor.handle(update: Fixtures.updateSupergroupFullInfo(supergroupId: Fixtures.groupSupergroupId, memberCount: 4201))
        await core.tdlib.add(supergroup: Fixtures.supergroup(id: Fixtures.groupSupergroupId, username: "acmecommunity", memberCount: 4202, isChannel: false))
        await core.monitor.handle(update: Fixtures.updateSupergroupFullInfo(supergroupId: Fixtures.groupSupergroupId, memberCount: 4202))
        page = try await core.eventLog.page(since: 2, limit: 10)
        #expect(page.events.count == 1)
        #expect(try await core.store.chat(Fixtures.groupId)?.memberCount == 4202)
        core.clock.advance(by: .seconds(5 * 60))
        await core.tdlib.add(supergroup: Fixtures.supergroup(id: Fixtures.groupSupergroupId, username: "acmecommunity", memberCount: 4203, isChannel: false))
        await core.monitor.handle(update: Fixtures.updateSupergroupFullInfo(supergroupId: Fixtures.groupSupergroupId, memberCount: 4203))
        page = try await core.eventLog.page(since: 3, limit: 10)
        #expect(page.events.count == 1)
        // Unmonitored chats produce nothing.
        await core.monitor.handle(update: Fixtures.updateChatTitle(chatId: Fixtures.channelId, title: "x"))
        #expect(try await core.eventLog.headSeq() == 4)
    }

    @Test func foldersDriveMonitoringAndGrants() async throws {
        let core = try await Core()
        await core.tdlib.setFolder(3, chatIds: [Fixtures.channelId])
        await core.monitor.handle(update: Fixtures.updateChatFolders([(3, "Product")]))
        #expect(try await core.store.folders() == [Folder(id: 3, title: "Product", chatIds: [Fixtures.channelId])])
        try await core.monitor.setMonitoredSet(MonitoredSet(folderIds: [3]))
        var page = try await core.eventLog.page(since: 0, limit: 10)
        #expect(page.events.map(\.type) == [.monitoringStarted])
        #expect(page.events[0].payload == .monitoring(MonitoringInfo(source: .folder, folderId: 3, folderTitle: "Product")))
        // The user drags the community group into the folder on the phone.
        await core.monitor.handle(update: Fixtures.updateChatAddedToFolder(chatId: Fixtures.groupId, folderId: 3))
        page = try await core.eventLog.page(since: 1, limit: 10)
        #expect(page.events.map(\.type) == [.monitoringStarted] && page.events[0].chat.id == Fixtures.groupId)
        await core.monitor.handle(update: Fixtures.updateChatRemovedFromFolder(chatId: Fixtures.channelId, folderId: 3))
        page = try await core.eventLog.page(since: 2, limit: 10)
        #expect(page.events.map(\.type) == [.monitoringStopped] && page.events[0].chat.id == Fixtures.channelId)
        // Folder deleted on the phone → everything in it stops.
        await core.monitor.handle(update: Fixtures.updateChatFolders([]))
        page = try await core.eventLog.page(since: 3, limit: 10)
        #expect(page.events.map(\.type) == [.monitoringStopped])
        #expect(await core.monitor.monitoredChatIds.isEmpty)
    }

    @Test func backfillAfterReconnectFillsTheGapWithoutDuplicates() async throws {
        let core = try await Core()
        try await core.monitor.setMonitoredSet(MonitoredSet(chatIds: [Fixtures.groupId]))
        await core.monitor.handle(update: Fixtures.updateConnectionState("connectionStateReady"))
        await core.monitor.waitForBackfill()
        // Cursor is at 1522. The connection drops; messages 1523…1526 are sent meanwhile. On
        // reconnect TDLib pushes 1524 as a live update before we get to backfill.
        await core.monitor.handle(update: Fixtures.updateConnectionState("connectionStateConnecting"))
        for id in [1500, 1522, 1523, 1524, 1525, 1526] as [Int64] {
            await core.tdlib.add(message: Fixtures.message(chatId: Fixtures.groupId, id: id, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("m\(id)")))
        }
        await core.monitor.handle(update: Fixtures.updateNewMessage(Fixtures.message(chatId: Fixtures.groupId, id: 1524, sender: Fixtures.userSender(Fixtures.adaId), content: Fixtures.textContent("m1524"))))
        await core.monitor.handle(update: Fixtures.updateConnectionState("connectionStateUpdating"))
        await core.monitor.handle(update: Fixtures.updateConnectionState("connectionStateReady"))
        await core.monitor.waitForBackfill()
        let page = try await core.eventLog.page(since: 1, limit: 10, types: [.messageNew])
        #expect(page.events.compactMap(\.messageId) == [1524, 1523, 1525, 1526])
        #expect(try await core.store.cursor(chatId: Fixtures.groupId) == MessageId.toInternal(1526))
        #expect(await core.monitor.backfill == Monitor.BackfillStatus())
        let history = await core.tdlib.requests(ofType: "getChatHistory")
        #expect(history.first?.object.int("offset") == -99 && history.first?.object.bool("only_local") == false)
        let viewed = await core.tdlib.requests(ofType: "viewMessages")
        let opened = await core.tdlib.requests(ofType: "openChat")
        #expect(viewed.isEmpty && opened.isEmpty)
    }
}
