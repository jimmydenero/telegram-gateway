import GatewayCore
import TDLibClient

/// Responses from the pinned schema. Installed only on FakeTDLib; never contacts Telegram.
public enum ActionFixtures {
    public static func install(_ tdlib: FakeTDLib) async {
        let message = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "edited")
        await tdlib.add(message: message)
        for type in ["addMessageReaction", "removeMessageReaction", "setPollAnswer", "deleteMessages", "toggleChatIsPinned", "addChatToList", "setChatNotificationSettings"] {
            await tdlib.on(type) { _ in ["@type": "ok"] }
        }
        await tdlib.on("getMessageProperties") { _ in ["@type": "messageProperties", "can_be_deleted_for_all_users": true, "can_be_deleted_only_for_self": true, "can_be_edited": true] }
        for type in ["editMessageText", "editMessageCaption"] { await tdlib.on(type) { _ in message.object } }
        await tdlib.on("forwardMessages") { _ in ["@type": "messages", "total_count": 1, "messages": [message.object]] }
        var chatObject = Fixtures.supergroupChat(id: Fixtures.channelId, supergroupId: Fixtures.channelSupergroupId, title: "Acme", isChannel: true).object
        chatObject["notification_settings"] = ["@type": "chatNotificationSettings", "use_default_mute_for": true, "mute_for": 0, "use_default_sound": true, "use_default_show_preview": true]
        let chat = JSONBox(chatObject)
        await tdlib.add(chat: chat)
        await tdlib.on("searchPublicChat") { _ in chat.object }
        await tdlib.on("searchUserByPhoneNumber") { _ in ["@type": "user", "id": Fixtures.privateChatId] }
        await tdlib.on("createPrivateChat") { _ in Fixtures.privateChat(userId: Fixtures.privateChatId, title: "Ada").object }
    }
}
