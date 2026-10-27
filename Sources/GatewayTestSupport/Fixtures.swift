import Foundation
import GatewayCore
import TDLibClient

/// TDLib objects as its JSON interface produces them, with the field names from
/// vendor/tdlib/src/td/generate/scheme/td_api.tl at the pinned commit. Note the conventions:
/// `int53` fields are JSON numbers, `int64` fields (`media_album_id`) are strings, message
/// ids are the internal form (public id << 20).
public enum Fixtures {
    public static let channelId: Int64 = -1001234567890
    public static let channelSupergroupId: Int64 = 1234567890
    public static let groupId: Int64 = -1009876543210
    public static let groupSupergroupId: Int64 = 9876543210
    public static let adaId: Int64 = 123456789
    public static let botId: Int64 = 555000111
    public static let privateChatId: Int64 = 123456789
    public static let basicGroupChatId: Int64 = -987654321
    public static let basicGroupId: Int64 = 987654321
    /// The account the gateway is signed in to: the sender of messages it sends.
    public static let ownerId: Int64 = 424242424

    // MARK: Users and chats

    public static func user(id: Int64, first: String, last: String = "", username: String? = nil, bot: Bool = false) -> JSONBox {
        var object: JSONObject = [
            "@type": "user", "id": id, "first_name": first, "last_name": last, "phone_number": "",
            "type": ["@type": bot ? "userTypeBot" : "userTypeRegular"],
        ]
        if let username {
            object["usernames"] = ["@type": "usernames", "active_usernames": [username], "disabled_usernames": [], "editable_username": username]
        }
        return JSONBox(object)
    }

    public static func usernames(_ username: String?) -> JSONObject {
        guard let username else { return ["@type": "usernames", "active_usernames": [], "disabled_usernames": [], "editable_username": ""] }
        return ["@type": "usernames", "active_usernames": [username], "disabled_usernames": [], "editable_username": username]
    }

    public static func supergroup(id: Int64, username: String?, memberCount: Int, isChannel: Bool) -> JSONBox {
        JSONBox(["@type": "supergroup", "id": id, "usernames": usernames(username), "member_count": memberCount, "is_channel": isChannel, "date": 1_700_000_000])
    }

    public static func basicGroup(id: Int64, memberCount: Int) -> JSONBox {
        JSONBox(["@type": "basicGroup", "id": id, "member_count": memberCount, "is_active": true])
    }

    public static func supergroupChat(id: Int64, supergroupId: Int64, title: String, isChannel: Bool, photoUniqueId: String? = nil, lastMessageId: Int64? = nil) -> JSONBox {
        var object: JSONObject = [
            "@type": "chat", "id": id, "title": title,
            "type": ["@type": "chatTypeSupergroup", "supergroup_id": supergroupId, "is_channel": isChannel],
        ]
        if let photoUniqueId {
            object["photo"] = [
                "@type": "chatPhotoInfo",
                "small": file(id: 91, remoteId: "small-\(photoUniqueId)", uniqueId: "s\(photoUniqueId)", size: 1024),
                "big": file(id: 92, remoteId: "big-\(photoUniqueId)", uniqueId: photoUniqueId, size: 40960),
            ]
        }
        if let lastMessageId { object["last_message"] = ["@type": "message", "id": lastMessageId, "chat_id": id] }
        return JSONBox(object)
    }

    public static func privateChat(userId: Int64, title: String) -> JSONBox {
        JSONBox(["@type": "chat", "id": userId, "title": title, "type": ["@type": "chatTypePrivate", "user_id": userId]])
    }

    public static func basicGroupChat(id: Int64, basicGroupId: Int64, title: String) -> JSONBox {
        JSONBox(["@type": "chat", "id": id, "title": title, "type": ["@type": "chatTypeBasicGroup", "basic_group_id": basicGroupId]])
    }

    public static func secretChat(id: Int64) -> JSONBox {
        JSONBox(["@type": "chat", "id": id, "title": "secret", "type": ["@type": "chatTypeSecret", "secret_chat_id": 5, "user_id": adaId]])
    }

    /// Registers the standard cast: Ada (user), a bot, the channel, the supergroup, a private
    /// chat and a basic group.
    public static func populate(_ tdlib: FakeTDLib) async {
        await tdlib.add(user: user(id: adaId, first: "Ada", last: "Lovelace", username: "ada"))
        await tdlib.add(user: user(id: botId, first: "Acme Bot", username: "acmebot", bot: true))
        await tdlib.add(user: user(id: ownerId, first: "Grace", last: "Hopper", username: "grace"))
        await tdlib.add(supergroup: supergroup(id: channelSupergroupId, username: "acmeupdates", memberCount: 12840, isChannel: true))
        await tdlib.add(chat: supergroupChat(id: channelId, supergroupId: channelSupergroupId, title: "Acme Product Updates", isChannel: true, photoUniqueId: "AQADchatphoto", lastMessageId: MessageId.toInternal(411)))
        await tdlib.add(supergroup: supergroup(id: groupSupergroupId, username: "acmecommunity", memberCount: 4200, isChannel: false))
        await tdlib.add(chat: supergroupChat(id: groupId, supergroupId: groupSupergroupId, title: "Acme Community", isChannel: false, lastMessageId: MessageId.toInternal(1522)))
        await tdlib.add(chat: privateChat(userId: adaId, title: "Ada Lovelace"))
        await tdlib.add(basicGroup: basicGroup(id: basicGroupId, memberCount: 12))
        await tdlib.add(chat: basicGroupChat(id: basicGroupChatId, basicGroupId: basicGroupId, title: "Family"))
    }

    // MARK: Files and content

    public static func file(id: Int, remoteId: String, uniqueId: String, size: Int64, path: String = "", expectedSize: Int64 = 0) -> JSONObject {
        [
            "@type": "file", "id": id, "size": Int(size), "expected_size": Int(expectedSize),
            "local": [
                "@type": "localFile", "path": path, "can_be_downloaded": true, "can_be_deleted": !path.isEmpty,
                "is_downloading_active": false, "is_downloading_completed": !path.isEmpty, "download_offset": 0,
                "downloaded_prefix_size": path.isEmpty ? 0 : Int(size), "downloaded_size": path.isEmpty ? 0 : Int(size),
            ],
            "remote": ["@type": "remoteFile", "id": remoteId, "unique_id": uniqueId, "is_uploading_active": false, "is_uploading_completed": true, "uploaded_size": Int(size)],
        ]
    }

    public static func formattedText(_ text: String, entities: [JSONObject] = []) -> JSONObject {
        ["@type": "formattedText", "text": text, "entities": entities]
    }

    public static func entity(_ type: String, offset: Int, length: Int, extra: JSONObject = [:]) -> JSONObject {
        var t = extra
        t["@type"] = type
        return ["@type": "textEntity", "offset": offset, "length": length, "type": t]
    }

    public static func textContent(_ text: String, entities: [JSONObject] = []) -> JSONObject {
        ["@type": "messageText", "text": formattedText(text, entities: entities)]
    }

    public static func photoContent(caption: String, uniqueId: String = "AQADphoto1", remoteId: String = "remote-photo-1", fileId: Int = 501) -> JSONObject {
        [
            "@type": "messagePhoto",
            "photo": [
                "@type": "photo", "has_stickers": false,
                "sizes": [
                    ["@type": "photoSize", "type": "m", "photo": file(id: fileId - 1, remoteId: remoteId + "-m", uniqueId: uniqueId + "m", size: 20480), "width": 320, "height": 180, "progressive_sizes": []],
                    ["@type": "photoSize", "type": "x", "photo": file(id: fileId, remoteId: remoteId, uniqueId: uniqueId, size: 184320), "width": 1280, "height": 720, "progressive_sizes": []],
                ],
            ],
            "caption": formattedText(caption, entities: []),
            "show_caption_above_media": false, "has_spoiler": false, "is_secret": false,
        ]
    }

    public static func videoContent(caption: String, uniqueId: String = "AQADvideo1", remoteId: String = "remote-video-1", fileId: Int = 601) -> JSONObject {
        [
            "@type": "messageVideo",
            "video": [
                "@type": "video", "duration": 42, "width": 1920, "height": 1080, "file_name": "demo.mp4", "mime_type": "video/mp4",
                "has_stickers": false, "supports_streaming": true,
                "video": file(id: fileId, remoteId: remoteId, uniqueId: uniqueId, size: 0, expectedSize: 20971520),
            ],
            "caption": formattedText(caption), "show_caption_above_media": false, "has_spoiler": false, "is_secret": false,
        ]
    }

    public static func documentContent(caption: String, fileName: String = "report.pdf", mime: String = "application/pdf", uniqueId: String = "AQADdoc1", remoteId: String = "remote-doc-1", fileId: Int = 701) -> JSONObject {
        [
            "@type": "messageDocument",
            "document": ["@type": "document", "file_name": fileName, "mime_type": mime, "document": file(id: fileId, remoteId: remoteId, uniqueId: uniqueId, size: 4096)],
            "caption": formattedText(caption),
        ]
    }

    public static func stickerContent() -> JSONObject {
        [
            "@type": "messageSticker",
            "sticker": [
                "@type": "sticker", "id": "1", "set_id": "2", "width": 512, "height": 512, "emoji": "😀",
                "format": ["@type": "stickerFormatWebp"], "full_type": ["@type": "stickerFullTypeRegular"],
                "sticker": file(id: 801, remoteId: "remote-sticker-1", uniqueId: "AQADsticker1", size: 30000),
            ],
            "is_premium": false,
        ]
    }

    public static func pollContent() -> JSONObject {
        ["@type": "messagePoll", "poll": ["@type": "poll", "id": "77", "question": formattedText("Which?"), "options": []]]
    }

    /// A poll as TDLib reports it: `options` are (text, voter count, chosen by the user).
    public static func pollContent(
        question: String, options: [(String, Int, Bool)], isClosed: Bool = false, isAnonymous: Bool = true, quiz: Bool = false
    ) -> JSONObject {
        let optionObjects: [JSONObject] = options.enumerated().map { index, option in
            [
                "@type": "pollOption", "id": String(index), "text": formattedText(option.0), "voter_count": option.1,
                "vote_percentage": 0, "recent_voter_ids": [], "is_chosen": option.2, "is_being_chosen": false, "addition_date": 0,
            ]
        }
        let type: JSONObject = quiz
            ? ["@type": "pollTypeQuiz", "correct_option_ids": [0], "explanation": formattedText("")]
            : ["@type": "pollTypeRegular"]
        return [
            "@type": "messagePoll",
            "poll": [
                "@type": "poll", "id": "78", "question": formattedText(question), "options": optionObjects,
                "total_voter_count": options.reduce(0) { $0 + $1.1 }, "recent_voter_ids": [], "is_anonymous": isAnonymous,
                "allows_multiple_answers": false, "allows_revoting": true, "type": type, "open_period": 0, "close_date": 0, "is_closed": isClosed,
            ],
            "description": formattedText(""), "can_add_option": false,
        ]
    }

    /// Service message contents (joins, leaves, title changes, pins, calls).
    public static func serviceContent(_ type: String, _ fields: JSONObject = [:]) -> JSONObject {
        var object = fields
        object["@type"] = type
        return object
    }

    public static func callContent(isVideo: Bool = false, discardReason: String, duration: Int) -> JSONObject {
        ["@type": "messageCall", "unique_id": "1", "is_video": isVideo, "discard_reason": ["@type": discardReason], "duration": duration]
    }

    // MARK: Reactions

    /// A `messageInteractionInfo`. Each reaction is (emoji or nil, custom emoji id or nil,
    /// total count, chosen by the user); `paid` adds a Telegram Star reaction.
    public static func interactionInfo(reactions: [(String?, String?, Int, Bool)], viewCount: Int = 0, paid: Int = 0) -> JSONObject {
        var list: [JSONObject] = reactions.map { emoji, customId, count, chosen in
            let type: JSONObject = emoji.map { ["@type": "reactionTypeEmoji", "emoji": $0] }
                ?? ["@type": "reactionTypeCustomEmoji", "custom_emoji_id": customId ?? "0"]
            return ["@type": "messageReaction", "type": type, "total_count": count, "is_chosen": chosen, "recent_sender_ids": []]
        }
        if paid > 0 {
            list.append(["@type": "messageReaction", "type": ["@type": "reactionTypePaid"], "total_count": paid, "is_chosen": false, "recent_sender_ids": []])
        }
        return [
            "@type": "messageInteractionInfo", "view_count": viewCount, "forward_count": 0,
            "reactions": ["@type": "messageReactions", "reactions": list, "are_tags": false, "paid_reactors": [], "can_get_added_reactions": false],
        ]
    }

    public static func updateMessageInteractionInfo(chatId: Int64, id: Int64, info: JSONObject) -> JSONBox {
        JSONBox(["@type": "updateMessageInteractionInfo", "chat_id": chatId, "message_id": MessageId.toInternal(id), "interaction_info": info])
    }

    // MARK: Read state and positions

    /// A `chatPosition`. `list` is `chatListMain`, `chatListArchive` or a folder id.
    public static func chatPosition(list: String = "chatListMain", folderId: Int64? = nil, order: String, isPinned: Bool = false) -> JSONObject {
        var listObject: JSONObject = ["@type": list]
        if let folderId { listObject = ["@type": "chatListFolder", "chat_folder_id": Int(folderId)] }
        return ["@type": "chatPosition", "list": listObject, "order": order, "is_pinned": isPinned]
    }

    /// Adds TDLib's read state, positions and notification settings to a `chat` object.
    /// Message ids are public; the fixture shifts them into TDLib's form.
    public static func withState(
        _ chat: JSONBox, unread: Int = 0, mentions: Int = 0, lastReadInbox: Int64 = 0, lastReadOutbox: Int64 = 0,
        positions: [JSONObject] = [], useDefaultMute: Bool = true, muteFor: Int = 0
    ) -> JSONBox {
        var object = chat.object
        object["unread_count"] = unread
        object["unread_mention_count"] = mentions
        object["last_read_inbox_message_id"] = MessageId.toInternal(lastReadInbox)
        object["last_read_outbox_message_id"] = MessageId.toInternal(lastReadOutbox)
        object["is_marked_as_unread"] = false
        object["positions"] = positions
        object["notification_settings"] = notificationSettings(useDefaultMute: useDefaultMute, muteFor: muteFor)
        return JSONBox(object)
    }

    public static func notificationSettings(useDefaultMute: Bool, muteFor: Int) -> JSONObject {
        ["@type": "chatNotificationSettings", "use_default_mute_for": useDefaultMute, "mute_for": muteFor, "use_default_sound": true, "use_default_show_preview": true]
    }

    public static func updateNewChat(_ chat: JSONBox) -> JSONBox {
        JSONBox(["@type": "updateNewChat", "chat": chat.object])
    }

    public static func updateChatReadInbox(chatId: Int64, lastRead: Int64, unread: Int) -> JSONBox {
        JSONBox(["@type": "updateChatReadInbox", "chat_id": chatId, "last_read_inbox_message_id": MessageId.toInternal(lastRead), "unread_count": unread])
    }

    public static func updateChatReadOutbox(chatId: Int64, lastRead: Int64) -> JSONBox {
        JSONBox(["@type": "updateChatReadOutbox", "chat_id": chatId, "last_read_outbox_message_id": MessageId.toInternal(lastRead)])
    }

    public static func updateChatUnreadMentionCount(chatId: Int64, count: Int) -> JSONBox {
        JSONBox(["@type": "updateChatUnreadMentionCount", "chat_id": chatId, "unread_mention_count": count])
    }

    public static func updateMessageMentionRead(chatId: Int64, id: Int64, count: Int) -> JSONBox {
        JSONBox(["@type": "updateMessageMentionRead", "chat_id": chatId, "message_id": MessageId.toInternal(id), "unread_mention_count": count])
    }

    public static func updateChatIsMarkedAsUnread(chatId: Int64, _ marked: Bool) -> JSONBox {
        JSONBox(["@type": "updateChatIsMarkedAsUnread", "chat_id": chatId, "is_marked_as_unread": marked])
    }

    public static func updateChatPosition(chatId: Int64, _ position: JSONObject) -> JSONBox {
        JSONBox(["@type": "updateChatPosition", "chat_id": chatId, "position": position])
    }

    /// `updateChatLastMessage` carries the chat's full set of positions.
    public static func updateChatDraftMessage(chatId: Int64, positions: [JSONObject]) -> JSONBox {
        JSONBox(["@type": "updateChatDraftMessage", "chat_id": chatId, "positions": positions])
    }

    public static func updateChatLastMessage(chatId: Int64, positions: [JSONObject]) -> JSONBox {
        JSONBox(["@type": "updateChatLastMessage", "chat_id": chatId, "positions": positions])
    }

    public static func updateChatNotificationSettings(chatId: Int64, useDefaultMute: Bool, muteFor: Int) -> JSONBox {
        JSONBox(["@type": "updateChatNotificationSettings", "chat_id": chatId, "notification_settings": notificationSettings(useDefaultMute: useDefaultMute, muteFor: muteFor)])
    }

    /// `scope` is `notificationSettingsScopePrivateChats`, `…GroupChats` or `…ChannelChats`.
    public static func updateScopeNotificationSettings(scope: String, muteFor: Int) -> JSONBox {
        JSONBox(["@type": "updateScopeNotificationSettings", "scope": ["@type": scope], "notification_settings": ["@type": "scopeNotificationSettings", "mute_for": muteFor, "show_preview": true]])
    }

    // MARK: Messages

    /// A `message` object. `id` is the public id; the fixture shifts it into TDLib's form.
    public static func message(
        chatId: Int64, id: Int64, sender: JSONObject, date: Int = 1_790_000_000, editDate: Int = 0, isOutgoing: Bool = false,
        content: JSONObject, replyTo: (chatId: Int64, messageId: Int64)? = nil, forward: JSONObject? = nil, albumId: String = "0",
        sendingState: JSONObject? = nil, interactionInfo: JSONObject? = nil, topic: JSONObject? = nil
    ) -> JSONBox {
        var object: JSONObject = [
            "@type": "message", "id": MessageId.toInternal(id), "sender_id": sender, "chat_id": chatId,
            "is_outgoing": isOutgoing, "is_pinned": false, "date": date, "edit_date": editDate, "media_album_id": albumId,
            "content": content,
        ]
        if let replyTo {
            object["reply_to"] = ["@type": "messageReplyToMessage", "chat_id": replyTo.chatId, "message_id": MessageId.toInternal(replyTo.messageId)]
        }
        if let forward { object["forward_info"] = forward }
        if let sendingState { object["sending_state"] = sendingState }
        if let interactionInfo { object["interaction_info"] = interactionInfo }
        if let topic { object["topic_id"] = topic }
        return JSONBox(object)
    }

    /// `message.topic_id` for a forum topic, and for a reply thread (which is not a topic).
    public static func forumTopic(_ id: Int) -> JSONObject { ["@type": "messageTopicForum", "forum_topic_id": id] }
    public static func threadTopic(_ id: Int64) -> JSONObject { ["@type": "messageTopicThread", "message_thread_id": MessageId.toInternal(id)] }

    public static func userSender(_ id: Int64) -> JSONObject { ["@type": "messageSenderUser", "user_id": id] }
    public static func chatSender(_ id: Int64) -> JSONObject { ["@type": "messageSenderChat", "chat_id": id] }

    public static func forwardFromChannel(chatId: Int64, messageId: Int64, date: Int) -> JSONObject {
        ["@type": "messageForwardInfo", "origin": ["@type": "messageOriginChannel", "chat_id": chatId, "message_id": MessageId.toInternal(messageId), "author_signature": ""], "date": date]
    }

    public static func forwardFromHiddenUser(name: String, date: Int) -> JSONObject {
        ["@type": "messageForwardInfo", "origin": ["@type": "messageOriginHiddenUser", "sender_name": name], "date": date]
    }

    public static func forwardFromUser(userId: Int64, date: Int) -> JSONObject {
        ["@type": "messageForwardInfo", "origin": ["@type": "messageOriginUser", "sender_user_id": userId], "date": date]
    }

    // MARK: Sending

    /// The temporary id TDLib gives the `n`-th message this client sends, before the server
    /// assigns the final one. Not a valid public id.
    public static func localMessageId(_ n: Int) -> Int64 {
        MessageId.toInternal(2_000_000 + Int64(n)) + 1
    }

    /// The message `sendMessage` returns at once: a local id and a pending `sending_state`.
    public static func pendingMessage(chatId: Int64, localId: Int64, text: String, replyTo: Int64? = nil) -> JSONBox {
        var object = message(
            chatId: chatId, id: 0, sender: userSender(ownerId), isOutgoing: true, content: textContent(text),
            replyTo: replyTo.map { (chatId, $0) }, sendingState: ["@type": "messageSendingStatePending", "sending_id": 0]
        ).object
        object["id"] = localId
        return JSONBox(object)
    }

    /// The same message as the server stored it, with its final public `id`.
    public static func sentMessage(chatId: Int64, id: Int64, text: String, replyTo: Int64? = nil, date: Int = 1_790_000_000) -> JSONBox {
        message(chatId: chatId, id: id, sender: userSender(ownerId), date: date, isOutgoing: true, content: textContent(text), replyTo: replyTo.map { (chatId, $0) })
    }

    public static func updateMessageSendFailed(_ message: JSONBox, oldMessageId: Int64, code: Int, error: String) -> JSONBox {
        JSONBox(["@type": "updateMessageSendFailed", "message": message.object, "old_message_id": oldMessageId, "error": ["@type": "error", "code": code, "message": error]])
    }

    // MARK: Updates

    public static func updateNewMessage(_ message: JSONBox) -> JSONBox {
        JSONBox(["@type": "updateNewMessage", "message": message.object])
    }

    public static func updateMessageSendSucceeded(_ message: JSONBox, oldMessageId: Int64) -> JSONBox {
        JSONBox(["@type": "updateMessageSendSucceeded", "message": message.object, "old_message_id": oldMessageId])
    }

    public static func updateMessageEdited(chatId: Int64, id: Int64, editDate: Int) -> JSONBox {
        JSONBox(["@type": "updateMessageEdited", "chat_id": chatId, "message_id": MessageId.toInternal(id), "edit_date": editDate])
    }

    public static func updateMessageContent(chatId: Int64, id: Int64, content: JSONObject) -> JSONBox {
        JSONBox(["@type": "updateMessageContent", "chat_id": chatId, "message_id": MessageId.toInternal(id), "new_content": content])
    }

    public static func updateDeleteMessages(chatId: Int64, ids: [Int64], permanent: Bool, fromCache: Bool) -> JSONBox {
        JSONBox(["@type": "updateDeleteMessages", "chat_id": chatId, "message_ids": ids.map { Int(MessageId.toInternal($0)) }, "is_permanent": permanent, "from_cache": fromCache])
    }

    public static func updateChatTitle(chatId: Int64, title: String) -> JSONBox {
        JSONBox(["@type": "updateChatTitle", "chat_id": chatId, "title": title])
    }

    public static func updateChatPhoto(chatId: Int64) -> JSONBox {
        JSONBox(["@type": "updateChatPhoto", "chat_id": chatId, "photo": ["@type": "chatPhotoInfo"]])
    }

    public static func updateSupergroupFullInfo(supergroupId: Int64, memberCount: Int) -> JSONBox {
        JSONBox(["@type": "updateSupergroupFullInfo", "supergroup_id": supergroupId, "supergroup_full_info": ["@type": "supergroupFullInfo", "member_count": memberCount]])
    }

    public static func updateSupergroup(_ supergroup: JSONBox) -> JSONBox {
        JSONBox(["@type": "updateSupergroup", "supergroup": supergroup.object])
    }

    public static func updateConnectionState(_ type: String) -> JSONBox {
        JSONBox(["@type": "updateConnectionState", "state": ["@type": type]])
    }

    public static func updateChatFolders(_ folders: [(id: Int64, title: String)]) -> JSONBox {
        JSONBox([
            "@type": "updateChatFolders",
            "chat_folders": folders.map { ["@type": "chatFolderInfo", "id": Int($0.id), "name": ["@type": "chatFolderName", "text": formattedText($0.title)], "icon": ["@type": "chatFolderIcon", "name": ""]] },
            "main_chat_list_position": 0, "are_tags_enabled": false,
        ])
    }

    public static func updateChatAddedToFolder(chatId: Int64, folderId: Int64) -> JSONBox {
        JSONBox(["@type": "updateChatAddedToList", "chat_id": chatId, "chat_list": ["@type": "chatListFolder", "chat_folder_id": Int(folderId)]])
    }

    public static func updateChatRemovedFromFolder(chatId: Int64, folderId: Int64) -> JSONBox {
        JSONBox(["@type": "updateChatRemovedFromList", "chat_id": chatId, "chat_list": ["@type": "chatListFolder", "chat_folder_id": Int(folderId)]])
    }
}
