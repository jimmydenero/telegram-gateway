import Foundation

// The objects defined in docs/events.md and docs/api.md. Each is a plain Codable value (that
// is how the store keeps it) with a `json` rendering that produces exactly the documented
// wire shape: ids as strings, absent values as null, keys in the documented order.

// MARK: Chats

public enum ChatType: String, Codable, Sendable {
    case `private`
    case basicGroup = "basic_group"
    case supergroup
    case channel
}

/// A chat's read state and its place in the chat list, as the user's Telegram apps show them
/// (docs/events.md "Chat summary"). Kept current from TDLib's chat updates; nil on chats and
/// events recorded before the gateway tracked it.
public struct ChatState: Codable, Sendable, Equatable {
    public var unreadCount: Int
    public var unreadMentionCount: Int
    /// Public message ids; nil when nothing has been read yet.
    public var lastReadInboxMessageId: Int64?
    public var lastReadOutboxMessageId: Int64?
    public var isMarkedAsUnread: Bool
    public var isPinned: Bool
    /// TDLib's order in the main chat list, as a decimal string; "0" when not in it.
    public var order: String
    public var isArchived: Bool
    public var isMuted: Bool

    public init(
        unreadCount: Int = 0, unreadMentionCount: Int = 0, lastReadInboxMessageId: Int64? = nil,
        lastReadOutboxMessageId: Int64? = nil, isMarkedAsUnread: Bool = false, isPinned: Bool = false,
        order: String = "0", isArchived: Bool = false, isMuted: Bool = false
    ) {
        self.unreadCount = unreadCount
        self.unreadMentionCount = unreadMentionCount
        self.lastReadInboxMessageId = lastReadInboxMessageId
        self.lastReadOutboxMessageId = lastReadOutboxMessageId
        self.isMarkedAsUnread = isMarkedAsUnread
        self.isPinned = isPinned
        self.order = order
        self.isArchived = isArchived
        self.isMuted = isMuted
    }

    /// The fields `chat.read` reports.
    public var readFields: JSONObjectValue {
        [
            "unread_count": .number(Double(unreadCount)),
            "unread_mention_count": .number(Double(unreadMentionCount)),
            "last_read_inbox_message_id": .id(lastReadInboxMessageId),
            "last_read_outbox_message_id": .id(lastReadOutboxMessageId),
            "is_marked_as_unread": .bool(isMarkedAsUnread),
        ]
    }

    /// The fields `chat.position` reports.
    public var positionFields: JSONObjectValue {
        ["is_pinned": .bool(isPinned), "order": .string(order), "is_archived": .bool(isArchived)]
    }

    public func sameRead(as other: ChatState) -> Bool {
        unreadCount == other.unreadCount && unreadMentionCount == other.unreadMentionCount
            && lastReadInboxMessageId == other.lastReadInboxMessageId
            && lastReadOutboxMessageId == other.lastReadOutboxMessageId && isMarkedAsUnread == other.isMarkedAsUnread
    }

    public func samePosition(as other: ChatState) -> Bool {
        isPinned == other.isPinned && order == other.order && isArchived == other.isArchived
    }

    /// Every field, in the documented order, or nulls when the state is unknown.
    static func fields(_ state: ChatState?) -> [(String, JSONValue)] {
        guard let state else {
            return ["unread_count", "unread_mention_count", "last_read_inbox_message_id", "last_read_outbox_message_id",
                    "is_marked_as_unread", "is_pinned", "order", "is_archived", "is_muted"].map { ($0, JSONValue.null) }
        }
        return [
            ("unread_count", .number(Double(state.unreadCount))),
            ("unread_mention_count", .number(Double(state.unreadMentionCount))),
            ("last_read_inbox_message_id", .id(state.lastReadInboxMessageId)),
            ("last_read_outbox_message_id", .id(state.lastReadOutboxMessageId)),
            ("is_marked_as_unread", .bool(state.isMarkedAsUnread)),
            ("is_pinned", .bool(state.isPinned)),
            ("order", .string(state.order)),
            ("is_archived", .bool(state.isArchived)),
            ("is_muted", .bool(state.isMuted)),
        ]
    }
}

/// The `chat` field on most events (docs/events.md "Chat summary"). `state` is as the
/// gateway knew it when the event was recorded.
public struct ChatSummary: Codable, Sendable, Equatable {
    public var id: Int64
    public var type: ChatType
    public var title: String
    public var username: String?
    public var state: ChatState?

    public init(id: Int64, type: ChatType, title: String, username: String?, state: ChatState? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
        self.state = state
    }

    public var json: JSONValue {
        var object: JSONObjectValue = ["id": .id(id), "type": .string(type.rawValue), "title": .string(title), "username": .optional(username)]
        for (key, value) in ChatState.fields(state) { object[key] = value }
        return .object(object)
    }
}

/// A chat's profile photo as a reduced media reference (docs/events.md "Media object").
public struct ChatPhoto: Codable, Sendable, Equatable {
    public var mediaId: String
    public var width: Int
    public var height: Int

    public init(mediaId: String, width: Int, height: Int) {
        self.mediaId = mediaId
        self.width = width
        self.height = height
    }

    public var json: JSONValue {
        ["media_id": .string(mediaId), "width": .number(Double(width)), "height": .number(Double(height))]
    }
}

/// The full chat object (docs/api.md "The chat object"). `isMonitored` is computed at read
/// time and is not stored.
public struct ChatInfo: Codable, Sendable, Equatable {
    public var id: Int64
    public var type: ChatType
    public var title: String
    public var username: String?
    public var memberCount: Int?
    public var photo: ChatPhoto?
    public var state: ChatState?

    public init(id: Int64, type: ChatType, title: String, username: String?, memberCount: Int?, photo: ChatPhoto?, state: ChatState? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
        self.memberCount = memberCount
        self.photo = photo
        self.state = state
    }

    public var summary: ChatSummary { ChatSummary(id: id, type: type, title: title, username: username, state: state) }

    public func json(isMonitored: Bool) -> JSONValue {
        var object: JSONObjectValue = [
            "id": .id(id),
            "type": .string(type.rawValue),
            "title": .string(title),
            "username": .optional(username),
            "member_count": .optional(memberCount),
            "is_monitored": .bool(isMonitored),
            "photo": photo?.json ?? .null,
        ]
        for (key, value) in ChatState.fields(state) { object[key] = value }
        return .object(object)
    }

    /// Which documented fields differ between two states, in the documented order. Read state
    /// and position have events of their own; only `is_muted` is reported here.
    public static func changes(from old: ChatInfo?, to new: ChatInfo) -> [String] {
        guard let old else { return [] }
        var changes: [String] = []
        if old.title != new.title { changes.append("title") }
        if old.username != new.username { changes.append("username") }
        if old.photo != new.photo { changes.append("photo") }
        if old.memberCount != new.memberCount { changes.append("member_count") }
        if let before = old.state?.isMuted, let after = new.state?.isMuted, before != after { changes.append("is_muted") }
        return changes
    }
}

// MARK: Messages

public struct Sender: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case user
        case chat
    }

    public var type: Kind
    public var id: Int64
    public var displayName: String
    public var username: String?
    /// Present only for `user`.
    public var isBot: Bool?

    public init(type: Kind, id: Int64, displayName: String, username: String?, isBot: Bool?) {
        self.type = type
        self.id = id
        self.displayName = displayName
        self.username = username
        self.isBot = isBot
    }

    public var json: JSONValue {
        var object: JSONObjectValue = [
            "type": .string(type.rawValue),
            "id": .id(id),
            "display_name": .string(displayName),
            "username": .optional(username),
        ]
        if type == .user { object["is_bot"] = .bool(isBot ?? false) }
        return .object(object)
    }
}

public struct Entity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case mention
        case textMention = "text_mention"
        case hashtag
        case cashtag
        case url
        case textLink = "text_link"
        case botCommand = "bot_command"
        case email
        case bold
        case italic
        case underline
        case strikethrough
        case spoiler
        case code
        case pre
        case blockquote
        case customEmoji = "custom_emoji"
    }

    public var type: Kind
    /// UTF-16 code units, as Telegram defines them.
    public var offset: Int
    public var length: Int
    public var userId: Int64?
    public var url: String?
    /// `pre` only: the code block's language, when the sender gave one.
    public var language: String?
    /// `custom_emoji` only.
    public var customEmojiId: String?

    public init(type: Kind, offset: Int, length: Int, userId: Int64? = nil, url: String? = nil, language: String? = nil, customEmojiId: String? = nil) {
        self.type = type
        self.offset = offset
        self.length = length
        self.userId = userId
        self.url = url
        self.language = language
        self.customEmojiId = customEmojiId
    }

    public var json: JSONValue {
        var object: JSONObjectValue = [
            "type": .string(type.rawValue),
            "offset": .number(Double(offset)),
            "length": .number(Double(length)),
        ]
        if type == .textMention { object["user_id"] = .id(userId) }
        if type == .textLink { object["url"] = .optional(url) }
        if type == .pre { object["language"] = .optional(language) }
        if type == .customEmoji { object["custom_emoji_id"] = .optional(customEmojiId) }
        return .object(object)
    }
}

public struct ReplyTo: Codable, Sendable, Equatable {
    public var chatId: Int64
    public var messageId: Int64

    public init(chatId: Int64, messageId: Int64) {
        self.chatId = chatId
        self.messageId = messageId
    }

    public var json: JSONValue { ["chat_id": .id(chatId), "message_id": .id(messageId)] }
}

public struct ForwardOrigin: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case user
        case chat
        case hiddenUser = "hidden_user"
    }

    public var type: Kind
    public var id: Int64?
    public var displayName: String
    public var username: String?
    public var messageId: Int64?
    public var date: Date

    public init(type: Kind, id: Int64?, displayName: String, username: String?, messageId: Int64?, date: Date) {
        self.type = type
        self.id = id
        self.displayName = displayName
        self.username = username
        self.messageId = messageId
        self.date = date
    }

    public var json: JSONValue {
        [
            "type": .string(type.rawValue),
            "id": .id(id),
            "display_name": .string(displayName),
            "username": .optional(username),
            "message_id": .id(messageId),
            "date": .date(date),
        ]
    }
}

public enum MediaKind: String, Codable, Sendable {
    case photo, video, document, audio, voice, sticker, animation
    case videoNote = "video_note"
}

public struct Media: Codable, Sendable, Equatable {
    public var mediaId: String
    public var kind: MediaKind
    public var mime: String?
    public var size: Int64?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Int?
    public var fileName: String?

    public init(
        mediaId: String, kind: MediaKind, mime: String?, size: Int64?, width: Int?, height: Int?,
        durationSeconds: Int?, fileName: String?
    ) {
        self.mediaId = mediaId
        self.kind = kind
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.fileName = fileName
    }

    public var json: JSONValue {
        [
            "media_id": .string(mediaId),
            "kind": .string(kind.rawValue),
            "mime": .optional(mime),
            "size": .optional(size),
            "width": .optional(width),
            "height": .optional(height),
            "duration_seconds": .optional(durationSeconds),
            "file_name": .optional(fileName),
        ]
    }
}

/// One reaction on a message (docs/events.md "Reactions"): a standard emoji or a custom one.
public struct Reaction: Codable, Sendable, Equatable {
    public var emoji: String?
    public var customEmojiId: String?
    public var count: Int
    /// Whether the user's own account chose it.
    public var chosen: Bool

    public init(emoji: String?, customEmojiId: String?, count: Int, chosen: Bool) {
        self.emoji = emoji
        self.customEmojiId = customEmojiId
        self.count = count
        self.chosen = chosen
    }

    public var json: JSONValue {
        ["emoji": .optional(emoji), "custom_emoji_id": .optional(customEmojiId), "count": .number(Double(count)), "chosen": .bool(chosen)]
    }
}

/// docs/events.md "Poll".
public struct Poll: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case regular
        case quiz
    }

    public struct Option: Codable, Sendable, Equatable {
        public var text: String
        public var voterCount: Int
        public var isChosen: Bool

        public init(text: String, voterCount: Int, isChosen: Bool) {
            self.text = text
            self.voterCount = voterCount
            self.isChosen = isChosen
        }

        public var json: JSONValue {
            ["text": .string(text), "voter_count": .number(Double(voterCount)), "is_chosen": .bool(isChosen)]
        }
    }

    public var question: String
    public var options: [Option]
    public var totalVoterCount: Int
    public var isClosed: Bool
    public var isAnonymous: Bool
    public var type: Kind

    public init(question: String, options: [Option], totalVoterCount: Int, isClosed: Bool, isAnonymous: Bool, type: Kind) {
        self.question = question
        self.options = options
        self.totalVoterCount = totalVoterCount
        self.isClosed = isClosed
        self.isAnonymous = isAnonymous
        self.type = type
    }

    public var json: JSONValue {
        [
            "question": .string(question),
            "options": .array(options.map(\.json)),
            "total_voter_count": .number(Double(totalVoterCount)),
            "is_closed": .bool(isClosed),
            "is_anonymous": .bool(isAnonymous),
            "type": .string(type.rawValue),
        ]
    }
}

/// docs/events.md "Message object". `id` is the public message id.
public struct Message: Codable, Sendable, Equatable {
    public var id: Int64
    public var chatId: Int64
    public var sender: Sender
    public var date: Date
    public var editDate: Date?
    public var isOutgoing: Bool
    public var text: String
    public var entities: [Entity]
    public var replyTo: ReplyTo?
    public var forwardFrom: ForwardOrigin?
    public var media: [Media]
    public var mediaGroupId: String?
    public var link: String?
    public var rawContentType: String
    /// Nil on messages recorded before the gateway carried reactions; otherwise possibly empty.
    public var reactions: [Reaction]?
    /// The forum topic, in a supergroup with topics.
    public var topicId: Int64?
    public var poll: Poll?

    public init(
        id: Int64, chatId: Int64, sender: Sender, date: Date, editDate: Date?, isOutgoing: Bool, text: String,
        entities: [Entity], replyTo: ReplyTo?, forwardFrom: ForwardOrigin?, media: [Media], mediaGroupId: String?,
        link: String?, rawContentType: String, reactions: [Reaction]? = [], topicId: Int64? = nil, poll: Poll? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.sender = sender
        self.date = date
        self.editDate = editDate
        self.isOutgoing = isOutgoing
        self.text = text
        self.entities = entities
        self.replyTo = replyTo
        self.forwardFrom = forwardFrom
        self.media = media
        self.mediaGroupId = mediaGroupId
        self.link = link
        self.rawContentType = rawContentType
        self.reactions = reactions
        self.topicId = topicId
        self.poll = poll
    }

    public var json: JSONValue {
        [
            "id": .id(id),
            "chat_id": .id(chatId),
            "sender": sender.json,
            "date": .date(date),
            "edit_date": .date(editDate),
            "is_outgoing": .bool(isOutgoing),
            "text": .string(text),
            "entities": .array(entities.map(\.json)),
            "reply_to": replyTo?.json ?? .null,
            "forward_from": forwardFrom?.json ?? .null,
            "media": .array(media.map(\.json)),
            "media_group_id": .optional(mediaGroupId),
            "link": .optional(link),
            "raw_content_type": .string(rawContentType),
            "reactions": reactions.map { .array($0.map(\.json)) } ?? .null,
            "topic_id": .id(topicId),
            "poll": poll?.json ?? .null,
        ]
    }
}

// MARK: Events

public enum EventType: String, Codable, Sendable, CaseIterable {
    case messageNew = "message.new"
    case messageEdited = "message.edited"
    case messageDeleted = "message.deleted"
    case chatUpdated = "chat.updated"
    case monitoringStarted = "monitoring.started"
    case monitoringStopped = "monitoring.stopped"
    case chatRead = "chat.read"
    case chatPosition = "chat.position"
    case messageReactions = "message.reactions"
    case pollUpdated = "poll.updated"

    /// The scope a grant needs to receive this type (docs/events.md "Event types").
    public var requiredScope: Scope {
        switch self {
        case .messageNew, .messageEdited, .messageDeleted, .messageReactions, .pollUpdated: .messagesRead
        case .chatUpdated, .monitoringStarted, .monitoringStopped, .chatRead, .chatPosition: .chatsRead
        }
    }
}

public struct MonitoringInfo: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case chat
        case folder
    }

    public var source: Source
    public var folderId: Int64?
    public var folderTitle: String?

    public init(source: Source, folderId: Int64?, folderTitle: String?) {
        self.source = source
        self.folderId = folderId
        self.folderTitle = folderTitle
    }

    public var json: JSONValue {
        ["source": .string(source.rawValue), "folder_id": .id(folderId), "folder_title": .optional(folderTitle)]
    }
}

/// The payload half of an event; the envelope (`seq`, timestamps, chat summary) is in `Event`.
public enum EventPayload: Codable, Sendable, Equatable {
    case message(Message)
    case messageIds([Int64])
    case chat(ChatInfo, changes: [String])
    case monitoring(MonitoringInfo)
    /// `chat.read` and `chat.position`: the state after the change.
    case chatState(ChatState)
    /// Public message id.
    case reactions(messageId: Int64, [Reaction])
    case poll(messageId: Int64, Poll)
}

/// docs/events.md "Envelope". `seq` is nil until the event is appended to the log.
public struct Event: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var seq: Int64?
    public var type: EventType
    public var occurredAt: Date
    public var recordedAt: Date
    public var chat: ChatSummary
    public var payload: EventPayload
    /// Public message id for `message.new` / `message.edited`; lets the monitor dedupe backfill.
    public var messageId: Int64?

    public init(
        seq: Int64? = nil, type: EventType, occurredAt: Date, recordedAt: Date, chat: ChatSummary,
        payload: EventPayload
    ) {
        self.seq = seq
        self.type = type
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.chat = chat
        self.payload = payload
        if case .message(let message) = payload { messageId = message.id }
    }

    public var chatId: Int64 { chat.id }

    /// The wire form. `isMonitored` applies to the full chat object in `chat.updated` only.
    public func json(isMonitored: Bool = true) -> JSONValue {
        var object: JSONObjectValue = [
            "v": .number(Double(Event.formatVersion)),
            "seq": .optional(seq),
            "type": .string(type.rawValue),
            "occurred_at": .date(occurredAt),
            "recorded_at": .date(recordedAt),
        ]
        switch payload {
        case .message(let message):
            object["chat"] = chat.json
            object["message"] = message.json
        case .messageIds(let ids):
            object["chat"] = chat.json
            object["message_ids"] = .array(ids.map { .id($0) })
        case .chat(let info, let changes):
            object["chat"] = info.json(isMonitored: isMonitored)
            object["changes"] = .array(changes.map { .string($0) })
        case .monitoring(let info):
            object["chat"] = chat.json
            object["monitoring"] = info.json
        case .chatState(let state):
            object["chat"] = chat.json
            let fields = type == .chatPosition ? state.positionFields : state.readFields
            for (key, value) in fields { object[key] = value }
        case .reactions(let messageId, let reactions):
            object["chat"] = chat.json
            object["message_id"] = .id(messageId)
            object["reactions"] = .array(reactions.map(\.json))
        case .poll(let messageId, let poll):
            object["chat"] = chat.json
            object["message_id"] = .id(messageId)
            object["poll"] = poll.json
        }
        return .object(object)
    }
}

// MARK: Grants

public enum Scope: String, Codable, Sendable, CaseIterable, Comparable {
    case messagesRead = "messages:read"
    case historyRead = "history:read"
    case mediaRead = "media:read"
    case chatsRead = "chats:read"
    /// Sending text messages as the user to the granted chats (`MessageSender`).
    case messagesSend = "messages:send"
    case chatsManage = "chats:manage"
    /// Marking messages read as the user, when a person read them (`MessageReader`).
    case messagesMarkRead = "messages:mark_read"

    public static func < (lhs: Scope, rhs: Scope) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which chats a grant covers: a fixed list or a Telegram folder (docs/grants.md).
public enum GrantChats: Codable, Sendable, Equatable {
    case list([Int64])
    case folder(id: Int64)
}

public enum WebhookState: String, Codable, Sendable {
    case active, retrying, paused
}

/// A grant's webhook configuration and delivery state (docs/api.md "Grants").
public struct Webhook: Codable, Sendable, Equatable {
    public var url: String
    /// Held in plain text: the gateway must sign every delivery with it. See docs/api.md.
    public var secret: String
    public var state: WebhookState
    public var cursorSeq: Int64
    public var lastDeliveryAt: Date?
    public var lastError: String?
    public var pausedAt: Date?
    /// When the current run of failures began; nil while healthy. Drives the 24h pause.
    public var failingSince: Date?

    public init(url: String, secret: String, state: WebhookState = .active, cursorSeq: Int64) {
        self.url = url
        self.secret = secret
        self.state = state
        self.cursorSeq = cursorSeq
    }

    /// The webhook part of the grant object. Never includes the secret.
    public func json(pendingEvents: Int64) -> JSONValue {
        [
            "url": .string(url),
            "state": .string(state.rawValue),
            "cursor_seq": .number(Double(cursorSeq)),
            "pending_events": .number(Double(pendingEvents)),
            "last_delivery_at": .date(lastDeliveryAt),
            "last_error": .optional(lastError),
            "paused_at": .date(pausedAt),
        ]
    }
}

public struct Grant: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var scopes: [Scope]
    public var chats: GrantChats
    public var tokenHash: String
    public var webhook: Webhook?
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public init(
        id: String, name: String, description: String, scopes: [Scope], chats: GrantChats, tokenHash: String,
        webhook: Webhook?, createdAt: Date, lastSeenAt: Date? = nil, revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.scopes = scopes
        self.chats = chats
        self.tokenHash = tokenHash
        self.webhook = webhook
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }

    public var isRevoked: Bool { revokedAt != nil }

    public func has(_ scope: Scope) -> Bool { scopes.contains(scope) }

    /// The grant object (docs/api.md "Grants"). `effectiveChatIds` and the folder title are
    /// resolved at read time by `Grants`.
    public func json(effectiveChatIds: [Int64], folderTitle: String?, pendingWebhookEvents: Int64) -> JSONValue {
        let chatsJSON: JSONValue
        switch chats {
        case .list(let ids):
            chatsJSON = ["mode": "list", "chat_ids": .array(ids.map { .id($0) })]
        case .folder(let id):
            chatsJSON = ["mode": "folder", "folder_id": .id(id), "folder_title": .optional(folderTitle)]
        }
        return [
            "id": .string(id),
            "app": ["name": .string(name), "description": .string(description)],
            "scopes": .array(scopes.map { .string($0.rawValue) }),
            "chats": chatsJSON,
            "effective_chat_ids": .array(effectiveChatIds.map { .id($0) }),
            "webhook": webhook?.json(pendingEvents: pendingWebhookEvents) ?? .null,
            "created_at": .date(createdAt),
            "last_seen_at": .date(lastSeenAt),
            "revoked_at": .date(revokedAt),
        ]
    }
}

// MARK: Access requests

public enum AccessRequestStatus: String, Codable, Sendable {
    case pending, approved, denied, expired
}

/// What an app asked for (docs/api.md "Access requests").
public struct AccessRequest: Codable, Sendable, Equatable {
    public var id: String
    public var status: AccessRequestStatus
    public var name: String
    public var description: String
    public var scopes: [Scope]
    /// nil means `"any"`.
    public var requestedChats: [Int64]?
    public var webhookUrl: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var resolvedAt: Date?
    public var deniedReason: String?
    public var grantId: String?
    /// The app's token and webhook secret, kept only for the hand-out window after approval
    /// (docs/api.md: `10:00`), then erased with the request.
    public var issuedToken: String?
    public var issuedWebhookSecret: String?

    public init(
        id: String, status: AccessRequestStatus = .pending, name: String, description: String, scopes: [Scope],
        requestedChats: [Int64]?, webhookUrl: String?, createdAt: Date, expiresAt: Date
    ) {
        self.id = id
        self.status = status
        self.name = name
        self.description = description
        self.scopes = scopes
        self.requestedChats = requestedChats
        self.webhookUrl = webhookUrl
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

// MARK: Webhook deliveries

public enum DeliveryStatus: String, Codable, Sendable {
    case inFlight = "in_flight"
    case succeeded
    case failed
}

public struct Delivery: Codable, Sendable, Equatable {
    public var id: String
    public var grantId: String
    public var seqs: [Int64]
    public var attempt: Int
    public var status: DeliveryStatus
    public var httpStatus: Int?
    public var error: String?
    public var sentAt: Date
    public var completedAt: Date?

    public init(
        id: String, grantId: String, seqs: [Int64], attempt: Int, status: DeliveryStatus, httpStatus: Int? = nil,
        error: String? = nil, sentAt: Date, completedAt: Date? = nil
    ) {
        self.id = id
        self.grantId = grantId
        self.seqs = seqs
        self.attempt = attempt
        self.status = status
        self.httpStatus = httpStatus
        self.error = error
        self.sentAt = sentAt
        self.completedAt = completedAt
    }

    public var firstSeq: Int64 { seqs.first ?? 0 }
    public var lastSeq: Int64 { seqs.last ?? 0 }

    public var json: JSONValue {
        [
            "delivery_id": .string(id),
            "first_seq": .number(Double(firstSeq)),
            "last_seq": .number(Double(lastSeq)),
            "event_count": .number(Double(seqs.count)),
            "attempt": .number(Double(attempt)),
            "status": .string(status.rawValue),
            "http_status": .optional(httpStatus),
            "error": .optional(error),
            "sent_at": .date(sentAt),
            "completed_at": .date(completedAt),
        ]
    }
}

// MARK: Folders and the monitored set

public struct Folder: Codable, Sendable, Equatable {
    public var id: Int64
    public var title: String
    public var chatIds: [Int64]

    public init(id: Int64, title: String, chatIds: [Int64]) {
        self.id = id
        self.title = title
        self.chatIds = chatIds
    }
}

/// What the user chose to monitor: explicit chats plus folders (docs/api.md
/// "Admin: chat list, folders, monitored set").
public struct MonitoredSet: Codable, Sendable, Equatable {
    public var chatIds: [Int64]
    public var folderIds: [Int64]

    public init(chatIds: [Int64] = [], folderIds: [Int64] = []) {
        self.chatIds = chatIds
        self.folderIds = folderIds
    }
}

/// Media the gateway knows about: enough to download it again and to serve it.
public struct MediaRecord: Codable, Sendable, Equatable {
    public var media: Media
    /// TDLib's `remoteFile.id`, what `getRemoteFile` takes.
    public var remoteId: String
    public var uniqueId: String
    public var localPath: String?
    public var cachedBytes: Int64
    public var lastServedAt: Date?

    public init(media: Media, remoteId: String, uniqueId: String, localPath: String? = nil, cachedBytes: Int64 = 0,
                lastServedAt: Date? = nil) {
        self.media = media
        self.remoteId = remoteId
        self.uniqueId = uniqueId
        self.localPath = localPath
        self.cachedBytes = cachedBytes
        self.lastServedAt = lastServedAt
    }
}
