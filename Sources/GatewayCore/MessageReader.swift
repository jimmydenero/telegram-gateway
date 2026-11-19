import Foundation
import TDLibClient

/// Marks messages read as the user, when a person read them: an app holding
/// `messages:mark_read` whose user opened the chat, or the owner's `tgw read`
/// (docs/api.md "Marking as read"). The one place in the gateway that calls `viewMessages`
/// or `readAllChatMentions`.
///
/// `viewMessages` is sent with `force_read`, which marks messages read in a chat that is not
/// open, so the reader never calls `openChat`. It never sets the `online` option and never
/// sends a chat action: the account still does not appear online.
public actor MessageReader {
    /// Reads per token per minute (docs/api.md "Rate limits").
    public static let readsPerMinute = 60

    private let grants: Grants
    private let translator: Translator
    private let telegram: any TelegramControl
    private let rateLimiter: RateLimiter

    public init(grants: Grants, translator: Translator, telegram: any TelegramControl, rateLimiter: RateLimiter) {
        self.grants = grants
        self.translator = translator
        self.telegram = telegram
        self.rateLimiter = rateLimiter
    }

    /// Marks the chat read up to the message with public id `upTo`, the newest message the
    /// person saw, and with `mentions` also clears its unread mentions. Returns the chat with
    /// its new unread state. There is no "up to the newest": a message that arrived after the
    /// person looked must not get a read receipt.
    ///
    /// Checks, in order: the `messages:mark_read` scope (`403 insufficient_scope`), that the
    /// grant is still in force (`401 token_revoked`), that the chat is granted and monitored
    /// (`403 chat_not_granted`; for the admin token, monitored), the rate limit (`429`), and a
    /// live Telegram session (`503`). Telegram's refusal is `502 send_failed`, as for the
    /// other actions; a flood wait is `429`.
    public func markRead(chat chatId: Int64, upTo: Int64, mentions: Bool = false, as principal: Principal) async throws -> ChatInfo {
        try await grants.require(.messagesMarkRead, principal)
        if let grant = principal.grant {
            guard let fresh = try await grants.grant(grant.id) else { throw APIError.invalidToken }
            if let revoked = fresh.revokedAt { throw APIError.tokenRevoked(at: revoked) }
            try await grants.require(.messagesMarkRead, .app(fresh))
        }
        try await grants.requireChat(chatId, principal)
        if upTo <= 0 || upTo > Int64.max >> 20 { throw APIError.invalidRequest("up_to_message_id", "must be a message id") }
        let decision = await rateLimiter.hit("read:\(principal.rateLimitKey)", limit: Self.readsPerMinute)
        guard decision.allowed else { throw APIError.rateLimited(retryAfter: decision.retryAfter) }
        let tdlib = try await telegram.requireLive()

        do {
            _ = try await tdlib.request("viewMessages", [
                "chat_id": chatId, "message_ids": [MessageId.toInternal(upTo)],
                "source": ["@type": "messageSourceChatHistory"] as JSONObject, "force_read": true,
            ])
            if mentions { _ = try await tdlib.request("readAllChatMentions", ["chat_id": chatId]) }
        } catch let error as TDLibError {
            throw MessageSender.apiError(code: error.code, message: error.message)
        }
        return try await translator.chatInfoWithCurrentReadState(chatId)
    }
}
