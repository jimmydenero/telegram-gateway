import GatewayCore
import Synchronization
import TDLibClient

/// `viewMessages` and `readAllChatMentions` for `MessageReader` tests, from the pinned schema.
/// Installed only on FakeTDLib; never contacts Telegram. The channel starts with 3 unread
/// messages (newest 1530) and 2 unread mentions; reads change what `getChat` returns, as
/// TDLib's would.
public enum ReadFixtures {
    public static let newestMessageId: Int64 = 1530

    public static func install(_ tdlib: FakeTDLib) async {
        let state = Mutex((lastRead: Int64(1527), unread: 3, mentions: 2))
        var base = Fixtures.supergroupChat(id: Fixtures.channelId, supergroupId: Fixtures.channelSupergroupId, title: "Acme", isChannel: true, lastMessageId: MessageId.toInternal(newestMessageId)).object
        base["notification_settings"] = ["@type": "chatNotificationSettings", "use_default_mute_for": true, "mute_for": 0]
        let chat = JSONBox(base)
        await tdlib.on("getChat") { request in
            guard request.int64("chat_id") == Fixtures.channelId else { throw TDLibError(code: 400, message: "Chat not found") }
            var object = chat.object
            state.withLock { current in
                object["last_read_inbox_message_id"] = MessageId.toInternal(current.lastRead)
                object["unread_count"] = current.unread
                object["unread_mention_count"] = current.mentions
            }
            return object
        }
        await tdlib.on("viewMessages") { request in
            guard request.bool("force_read") == true else { return ["@type": "ok"] }
            let viewed = (request.array("message_ids") ?? []).compactMap(Translator.int64).map(MessageId.toPublic).max() ?? 0
            state.withLock { current in
                guard viewed > current.lastRead else { return }
                current.unread = max(0, Int(newestMessageId - viewed))
                current.lastRead = viewed
            }
            return ["@type": "ok"]
        }
        await tdlib.on("readAllChatMentions") { _ in
            state.withLock { $0.mentions = 0 }
            return ["@type": "ok"]
        }
    }
}
