import Foundation
import TDLibClient

/// Sends text messages for the `messages:send` scope and for the owner's `tgw send`
/// (docs/api.md "Sending messages"). The one place in the gateway that calls `sendMessage`.
///
/// TDLib answers `sendMessage` at once with a temporary copy of the message (a local id and a
/// `sending_state`); the server's verdict arrives later as `updateMessageSendSucceeded` (with
/// the final id) or `updateMessageSendFailed`. `send` waits for that verdict, up to `timeout`,
/// and returns the final message in the gateway's own format. The daemon passes every TDLib
/// update to `observe` after the monitor has recorded it, so the sent message is already in
/// the event log as `message.new` when `send` returns.
///
/// Never calls `openChat` or `viewMessages`, and never touches the `online` option.
public actor MessageSender {
    /// Telegram's limit on the text of one message, in UTF-16 code units (TDLib's
    /// `message_text_length_max`).
    public static let maxTextLength = 4096
    /// Sends per token per minute (docs/api.md "Rate limits").
    public static let sendsPerMinute = 20
    public static let defaultTimeout: Duration = .seconds(30)

    /// What Telegram said about one message being sent.
    enum Outcome: Sendable {
        case succeeded(JSONBox)
        case failed(code: Int, message: String)
        case timedOut
    }

    private struct Key: Hashable {
        let chatId: Int64
        let localId: Int64
    }

    private let grants: Grants
    private let translator: Translator
    private let telegram: any TelegramControl
    private let rateLimiter: RateLimiter
    private let clock: any GatewayClock
    private let timeout: Duration

    private var waiting: [Key: CheckedContinuation<Outcome, Never>] = [:]
    /// Verdicts that arrived before `send` started waiting for them (the update stream and
    /// the request's response travel separately). Bounded; oldest first.
    private var early: [(key: Key, outcome: Outcome)] = []

    public init(
        grants: Grants, translator: Translator, telegram: any TelegramControl, rateLimiter: RateLimiter,
        clock: any GatewayClock = SystemClock(), timeout: Duration = MessageSender.defaultTimeout
    ) {
        self.grants = grants
        self.translator = translator
        self.telegram = telegram
        self.rateLimiter = rateLimiter
        self.clock = clock
        self.timeout = timeout
    }

    /// Sends `text` to `chatId` as the user, optionally as a reply to the message with public
    /// id `replyTo`, and returns the message as Telegram stored it.
    ///
    /// Checks, in order: the `messages:send` scope (`403 insufficient_scope`), that the grant
    /// is still in force (`401 token_revoked`), that the chat is granted and monitored
    /// (`403 chat_not_granted`; for the admin token, monitored), the text
    /// (`400 invalid_request`), the rate limit (`429`), and a live Telegram session (`503`).
    /// Then `502 send_failed` if Telegram refuses, `504 send_timeout` if it does not answer.
    public func send(_ text: String, to chatId: Int64, replyTo: Int64? = nil, as principal: Principal) async throws -> Message {
        try await grants.require(.messagesSend, principal)
        if let grant = principal.grant {
            guard let current = try await grants.grant(grant.id) else { throw APIError.invalidToken }
            if let revokedAt = current.revokedAt { throw APIError.tokenRevoked(at: revokedAt) }
        }
        try await grants.requireChat(chatId, principal)
        try MessageSender.validate(text: text)
        if let replyTo, replyTo <= 0 { throw APIError.invalidRequest("reply_to", "must be a message id") }
        let decision = await rateLimiter.hit("send:\(principal.rateLimitKey)", limit: MessageSender.sendsPerMinute)
        guard decision.allowed else { throw APIError.rateLimited(retryAfter: decision.retryAfter) }
        let tdlib = try await telegram.requireLive()

        var fields: JSONObject = [
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageText",
                "text": ["@type": "formattedText", "text": text, "entities": [JSONObject]()],
                "clear_draft": false,
            ] as JSONObject,
        ]
        if let replyTo {
            fields["reply_to"] = ["@type": "inputMessageReplyToMessage", "message_id": MessageId.toInternal(replyTo)] as JSONObject
        }
        let pending: JSONObject
        do {
            pending = try await tdlib.request("sendMessage", fields).object
        } catch let error as TDLibError {
            throw MessageSender.apiError(code: error.code, message: error.message)
        }

        guard let localId = pending.int64("id") else { throw APIError.internalError("sendMessage returned a message without an id") }
        let outcome: Outcome
        switch pending.object("sending_state")?.type {
        case nil:
            outcome = .succeeded(JSONBox(pending))
        case "messageSendingStateFailed":
            let error = pending.object("sending_state")?.object("error")
            outcome = .failed(code: error?.int("code") ?? 0, message: error?.string("message") ?? "")
        default:
            outcome = await verdict(for: Key(chatId: pending.int64("chat_id") ?? chatId, localId: localId))
        }

        switch outcome {
        case .succeeded(let message):
            return try await translator.translateMessage(message).message
        case .failed(let code, let message):
            throw MessageSender.apiError(code: code, message: message)
        case .timedOut:
            throw APIError.sendTimeout(chatId: chatId, after: timeout)
        }
    }

    /// Throws `400 invalid_request` (field `text`) for empty or over-long text.
    public static func validate(text: String) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw APIError.invalidRequest("text", "empty")
        }
        if text.utf16.count > maxTextLength {
            var error = APIError.invalidRequest("text", "too_long")
            error.details["max_length"] = .number(Double(maxTextLength))
            throw error
        }
    }

    /// Telegram's refusal as the API reports it: a flood wait (TDLib code 429, "Too Many
    /// Requests: retry after N") is `429 rate_limited`, anything else `502 send_failed`.
    static func apiError(code: Int, message: String) -> APIError {
        if code == 429 {
            let seconds = message.split(separator: " ").last.flatMap { Int($0) } ?? 60
            return APIError.rateLimited(retryAfter: max(1, seconds))
        }
        return APIError.sendFailed(reason: message, telegramCode: code)
    }

    /// Takes in a TDLib update. Only the outcome of messages this gateway sent matters here;
    /// everything else is ignored.
    public func observe(_ update: JSONBox) {
        let object = update.object
        switch object.type {
        case "updateMessageSendSucceeded":
            guard let message = object.object("message"), let chatId = message.int64("chat_id"),
                  let old = object.int64("old_message_id") else { return }
            resolve(Key(chatId: chatId, localId: old), .succeeded(JSONBox(message)))
        case "updateMessageSendFailed":
            guard let chatId = object.object("message")?.int64("chat_id"), let old = object.int64("old_message_id") else { return }
            let error = object.object("error")
            resolve(Key(chatId: chatId, localId: old), .failed(code: error?.int("code") ?? 0, message: error?.string("message") ?? ""))
        case "updateDeleteMessages":
            // TDLib may drop a message it cannot send and report only its deletion.
            guard let chatId = object.int64("chat_id") else { return }
            for id in (object.array("message_ids") ?? []).compactMap(Translator.int64) {
                let key = Key(chatId: chatId, localId: id)
                if waiting[key] != nil { resolve(key, .failed(code: 0, message: "The message was deleted before it was sent.")) }
            }
        default:
            return
        }
    }

    /// The number of sends waiting for Telegram's verdict (tests).
    public var waitingCount: Int { waiting.count }

    private func verdict(for key: Key) async -> Outcome {
        if let index = early.firstIndex(where: { $0.key == key }) {
            return early.remove(at: index).outcome
        }
        let clock = clock
        let timeout = timeout
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.resolve(key, .timedOut, keepIfUnclaimed: false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            waiting[key] = continuation
        }
    }

    private func resolve(_ key: Key, _ outcome: Outcome, keepIfUnclaimed: Bool = true) {
        if let continuation = waiting.removeValue(forKey: key) {
            continuation.resume(returning: outcome)
        } else if keepIfUnclaimed {
            early.append((key, outcome))
            if early.count > 64 { early.removeFirst(early.count - 64) }
        }
    }
}
