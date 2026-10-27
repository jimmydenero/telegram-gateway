import Foundation
import TDLibClient

extension MessageSender {
    /// All mutations share sending's scope, revocation, monitored/granted chat, rate and
    /// live-session checks. No action marks a message read or sends a chat action.
    func authorize(_ scope: Scope, chats: [Int64], as principal: Principal) async throws -> any TDLibRequesting {
        try await checkAccess(scope, chats: chats, as: principal)
        return try await limitAndRequireLive(principal)
    }

    /// The shared per-token action budget (the same one as sending), then a live session.
    func limitAndRequireLive(_ principal: Principal) async throws -> any TDLibRequesting {
        let decision = await rateLimiter.hit("send:\(principal.rateLimitKey)", limit: Self.sendsPerMinute)
        guard decision.allowed else { throw APIError.rateLimited(retryAfter: decision.retryAfter) }
        return try await telegram.requireLive()
    }

    func checkAccess(_ scope: Scope, chats: [Int64], as principal: Principal) async throws {
        try await grants.require(scope, principal)
        if let grant = principal.grant {
            guard let fresh = try await grants.grant(grant.id) else { throw APIError.invalidToken }
            if let revoked = fresh.revokedAt { throw APIError.tokenRevoked(at: revoked) }
            try await grants.require(scope, .app(fresh))
        }
        for chat in chats { try await grants.requireChat(chat, principal) }
    }

    func perform(_ type: String, _ fields: JSONObject, using tdlib: any TDLibRequesting) async throws -> JSONBox {
        do { var request = fields; request["@type"] = type; return try await tdlib.request(JSONBox(request)) }
        catch let error as TDLibError { throw Self.apiError(code: error.code, message: error.message) }
    }

    public func forward(_ body: JSONObjectValue, to chat: Int64, as principal: Principal) async throws -> [Message] {
        let source = try ActionInput.id(body, "from_chat_id")
        let ids = try ActionInput.ids(body)
        let copy = try ActionInput.bool(body, "send_copy")
        let tdlib = try await authorize(.messagesSend, chats: [chat, source], as: principal)
        let result = try await perform("forwardMessages", ["chat_id": chat, "from_chat_id": source, "message_ids": ids, "send_copy": copy, "remove_caption": false], using: tdlib)
        guard let pending = result.object.array("messages"), pending.count == ids.count else { throw APIError.internalError("forwardMessages returned an incomplete result") }
        let boxes = try pending.map { raw -> JSONBox in
            guard let object = raw as? JSONObject else { throw APIError.sendFailed(reason: "A message could not be forwarded", telegramCode: 400) }
            return JSONBox(object)
        }
        // Register each wait concurrently, so a large batch doesn't lose early verdicts.
        return try await withThrowingTaskGroup(of: (Int, Message).self) { group in
            for (index, box) in boxes.enumerated() {
                group.addTask { (index, try await self.settle(box, chatId: chat)) }
            }
            var messages: [(Int, Message)] = []
            for try await message in group { messages.append(message) }
            return messages.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func edit(_ body: JSONObjectValue, chat: Int64, message: Int64, as principal: Principal) async throws -> Message {
        let id = try ActionInput.id(["message_id": .id(message)], "message_id", message: true)
        let tdlib = try await authorize(.messagesSend, chats: [chat], as: principal)
        let fields: JSONObject = ["chat_id": chat, "message_id": MessageId.toInternal(id)]
        let original = try await perform("getMessage", fields, using: tdlib)
        guard original.object.bool("is_outgoing") == true else { throw APIError.invalidRequest("message_id", "only your own messages can be edited") }
        let text = try ActionInput.string(body, "text")
        let isText = original.object.object("content")?.type == "messageText"
        if isText { try Self.validate(text: text) }
        let formatted = try ActionInput.formatted(text, entities: body["entities"], limit: isText ? 4096 : 1024)
        var request = fields
        if isText { request["input_message_content"] = ["@type": "inputMessageText", "text": formatted, "clear_draft": false] as JSONObject }
        else { request["caption"] = formatted }
        try await checkAccess(.messagesSend, chats: [chat], as: principal)
        let result = try await perform(isText ? "editMessageText" : "editMessageCaption", request, using: tdlib)
        return try await translator.translateMessage(result).message
    }

    public func delete(_ body: JSONObjectValue, chat: Int64, as principal: Principal) async throws {
        let ids = try ActionInput.ids(body)
        guard body["for_everyone"] != nil else { throw APIError.invalidRequest("for_everyone", "required") }
        let everyone = try ActionInput.bool(body, "for_everyone")
        let tdlib = try await authorize(.messagesSend, chats: [chat], as: principal)
        // Validate the whole batch before deleting anything. messages:send permits own messages.
        for id in ids {
            let fields: JSONObject = ["chat_id": chat, "message_id": id]
            let message = try await perform("getMessage", fields, using: tdlib)
            guard message.object.bool("is_outgoing") == true else { throw APIError.invalidRequest("message_ids", "only your own messages can be deleted") }
            let properties = try await perform("getMessageProperties", fields, using: tdlib)
            let allowed = properties.object.bool(everyone ? "can_be_deleted_for_all_users" : "can_be_deleted_only_for_self") == true
            guard allowed else { throw APIError.invalidRequest("for_everyone", "Telegram does not permit this deletion") }
        }
        try await checkAccess(.messagesSend, chats: [chat], as: principal)
        _ = try await perform("deleteMessages", ["chat_id": chat, "message_ids": ids, "revoke": everyone], using: tdlib)
    }

    public func react(_ body: JSONObjectValue, chat: Int64, message: Int64, remove: Bool = false, as principal: Principal) async throws {
        let id = try ActionInput.id(["message_id": .id(message)], "message_id", message: true)
        guard (body["emoji"] != nil) != (body["custom_emoji_id"] != nil) else { throw APIError.invalidRequest("reaction", "provide exactly one of emoji and custom_emoji_id") }
        let reaction: JSONObject
        if body["emoji"] != nil {
            let emoji = try ActionInput.string(body, "emoji")
            guard !emoji.isEmpty, emoji.utf16.count <= 64 else { throw APIError.invalidRequest("emoji", "invalid emoji") }
            reaction = ["@type": "reactionTypeEmoji", "emoji": emoji]
        } else { reaction = ["@type": "reactionTypeCustomEmoji", "custom_emoji_id": try ActionInput.id(body, "custom_emoji_id")] }
        let big = try ActionInput.bool(body, "big")
        let tdlib = try await authorize(.messagesSend, chats: [chat], as: principal)
        _ = try await perform(remove ? "removeMessageReaction" : "addMessageReaction", ["chat_id": chat, "message_id": MessageId.toInternal(id), "reaction_type": reaction, "is_big": big, "update_recent_reactions": false], using: tdlib)
    }

    public func vote(_ body: JSONObjectValue, chat: Int64, message: Int64, as principal: Principal) async throws {
        let id = try ActionInput.id(["message_id": .id(message)], "message_id", message: true)
        guard let options = body["option_ids"]?.arrayValue, options.count <= 100 else { throw APIError.invalidRequest("option_ids", "must be an array of option indices") }
        let ids = try options.map { try ActionInput.integer($0, field: "option_ids") }
        guard Set(ids).count == ids.count else { throw APIError.invalidRequest("option_ids", "duplicates") }
        let tdlib = try await authorize(.messagesSend, chats: [chat], as: principal)
        _ = try await perform("setPollAnswer", ["chat_id": chat, "message_id": MessageId.toInternal(id), "option_ids": ids], using: tdlib)
    }

    public func settings(_ body: JSONObjectValue, chat: Int64, as principal: Principal) async throws -> ChatInfo {
        guard !body.isEmpty, body.keys.allSatisfy({ ["is_pinned", "is_archived", "is_muted", "mute_until"].contains($0) }) else { throw APIError.invalidRequest("body", "provide chat settings") }
        for key in ["is_pinned", "is_archived", "is_muted"] where body[key] != nil { _ = try ActionInput.bool(body, key) }
        var muteFor: Int?
        if body["mute_until"] != nil {
            guard try ActionInput.bool(body, "is_muted") else { throw APIError.invalidRequest("mute_until", "requires is_muted: true") }
            let until = try ActionInput.integer(body["mute_until"], field: "mute_until")
            muteFor = max(0, until - Int(clock.now.timeIntervalSince1970))
        }
        let tdlib = try await authorize(.chatsManage, chats: [chat], as: principal)
        var notification: JSONObject?
        if body["is_muted"] != nil {
            let original = try await perform("getChat", ["chat_id": chat], using: tdlib)
            guard var settings = original.object.object("notification_settings") else { throw APIError.internalError("getChat returned no notification settings") }
            settings["use_default_mute_for"] = false
            settings["mute_for"] = try ActionInput.bool(body, "is_muted") ? (muteFor ?? Int(Int32.max)) : 0
            notification = settings
        }
        try await checkAccess(.chatsManage, chats: [chat], as: principal)
        if body["is_pinned"] != nil {
            _ = try await perform("toggleChatIsPinned", ["chat_id": chat, "chat_list": ["@type": "chatListMain"], "is_pinned": try ActionInput.bool(body, "is_pinned")], using: tdlib)
        }
        if body["is_archived"] != nil {
            _ = try await perform("addChatToList", ["chat_id": chat, "chat_list": ["@type": try ActionInput.bool(body, "is_archived") ? "chatListArchive" : "chatListMain"]], using: tdlib)
        }
        if let notification { _ = try await perform("setChatNotificationSettings", ["chat_id": chat, "notification_settings": notification], using: tdlib) }
        return try await translator.chatInfo(chat, refresh: true)
    }

    public func startChat(_ body: JSONObjectValue, as principal: Principal, store: Store, monitor: Monitor) async throws -> ChatInfo {
        guard (body["username"] != nil) != (body["phone"] != nil) else { throw APIError.invalidRequest("body", "provide exactly one of username and phone") }
        let key = body["username"] != nil ? "username" : "phone"
        let value = try ActionInput.string(body, key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { throw APIError.invalidRequest(key, "invalid value") }
        let tdlib = try await authorize(.chatsManage, chats: [], as: principal)
        let chat: Int64
        if key == "username" {
            let result = try await perform("searchPublicChat", ["username": value.hasPrefix("@") ? String(value.dropFirst()) : value], using: tdlib)
            guard let id = result.object.int64("id") else { throw APIError.internalError("searchPublicChat returned no id") }
            chat = id
        } else {
            let user = try await perform("searchUserByPhoneNumber", ["phone_number": value, "only_local": false], using: tdlib)
            guard let id = user.object.int64("id") else { throw APIError.internalError("searchUserByPhoneNumber returned no id") }
            // Private chat ids equal user ids. App callers cannot create ungranted chats.
            if principal.grant != nil { try await checkAccess(.chatsManage, chats: [id], as: principal) }
            let result = try await perform("createPrivateChat", ["user_id": id, "force": false], using: tdlib)
            guard let resultId = result.object.int64("id") else { throw APIError.internalError("createPrivateChat returned no id") }
            chat = resultId
        }
        if principal.grant != nil { try await checkAccess(.chatsManage, chats: [chat], as: principal) }
        else {
            var set = try await store.monitoredSet()
            if !set.chatIds.contains(chat) { set.chatIds.append(chat); try await monitor.setMonitoredSet(set) }
        }
        return try await translator.chatInfo(chat, refresh: true)
    }
}
