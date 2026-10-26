import Foundation

/// An error with the documented wire shape (docs/api.md "Errors"): HTTP status, stable `code`,
/// free-text `message`, and `details` keys listed per code. Domain code throws these so the
/// server only has to serialise them; the same codes go into WebSocket error frames.
public struct APIError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int
    public var code: String
    public var message: String
    public var details: JSONObjectValue
    /// Extra response headers, e.g. `Retry-After`.
    public var headers: [(String, String)]

    public init(status: Int, code: String, message: String, details: JSONObjectValue = [:], headers: [(String, String)] = []) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.headers = headers
    }

    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        lhs.status == rhs.status && lhs.code == rhs.code && lhs.message == rhs.message && lhs.details == rhs.details
    }

    public var description: String { "\(status) \(code): \(message)" }

    /// `{ "error": { "code", "message", "details" } }`.
    public var json: JSONValue {
        ["error": ["code": .string(code), "message": .string(message), "details": .object(details)]]
    }

    // MARK: 400

    public static func invalidRequest(_ field: String, _ reason: String) -> APIError {
        APIError(status: 400, code: "invalid_request", message: "\(field): \(reason)", details: ["field": .string(field), "reason": .string(reason)])
    }

    public static func scopeNotRequested(_ scope: String) -> APIError {
        APIError(status: 400, code: "scope_not_requested", message: "The app did not ask for the \(scope) scope.", details: ["scope": .string(scope)])
    }

    public static func chatNotMonitored(_ chatId: Int64) -> APIError {
        APIError(status: 400, code: "chat_not_monitored", message: "Chat \(chatId) is not monitored; monitor it first.", details: ["chat_id": .id(chatId)])
    }

    public static func folderNotMonitored(_ folderId: Int64) -> APIError {
        APIError(status: 400, code: "folder_not_monitored", message: "Folder \(folderId) is not monitored; monitor it first.", details: ["folder_id": .id(folderId)])
    }

    public static func chatNotMonitorable(_ chatId: Int64) -> APIError {
        APIError(status: 400, code: "chat_not_monitorable", message: "Chat \(chatId) is unknown or a secret chat and cannot be monitored.", details: ["chat_id": .id(chatId)])
    }

    // MARK: 401 / 403

    public static let missingToken = APIError(status: 401, code: "missing_token", message: "Send Authorization: Bearer <token>.")
    public static let invalidToken = APIError(status: 401, code: "invalid_token", message: "The token is malformed or unknown.")

    public static func tokenRevoked(at date: Date) -> APIError {
        APIError(status: 401, code: "token_revoked", message: "This grant was revoked.", details: ["revoked_at": .date(date)])
    }

    public static let adminOnly = APIError(status: 403, code: "admin_only", message: "This endpoint requires the admin token.")

    public static func insufficientScope(required: Scope, granted: [Scope]) -> APIError {
        APIError(
            status: 403, code: "insufficient_scope", message: "This endpoint requires the \(required.rawValue) scope.",
            details: ["required": .string(required.rawValue), "granted": .array(granted.map { .string($0.rawValue) })]
        )
    }

    public static let chatNotGranted = APIError(status: 403, code: "chat_not_granted", message: "The chat is outside this grant, not monitored, or does not exist.")

    // MARK: 404 / 409 / 410 / 413 / 429 / 500 / 502 / 503 / 504

    public static let notFound = APIError(status: 404, code: "not_found", message: "No such route or object.")

    public static func alreadyResolved(_ status: AccessRequestStatus) -> APIError {
        APIError(status: 409, code: "already_resolved", message: "The access request is \(status.rawValue).", details: ["status": .string(status.rawValue)])
    }

    public static func webhookNotPaused(_ state: WebhookState) -> APIError {
        APIError(status: 409, code: "webhook_not_paused", message: "The webhook is \(state.rawValue), not paused.", details: ["state": .string(state.rawValue)])
    }

    public static let webhookNotConfigured = APIError(status: 409, code: "webhook_not_configured", message: "This grant has no webhook.")

    public static func cursorBehind(grantId: String) -> APIError {
        APIError(status: 409, code: "cursor_behind", message: "Webhook cursor of grant \(grantId) is behind the boundary; pass force to prune anyway.", details: ["grant_id": .string(grantId)])
    }

    public static func historyPruned(oldestSeq: Int64) -> APIError {
        APIError(status: 410, code: "history_pruned", message: "Events before \(oldestSeq) were pruned.", details: ["oldest_seq": .number(Double(oldestSeq))])
    }

    public static func mediaGone(_ mediaId: String) -> APIError {
        APIError(status: 410, code: "media_gone", message: "Telegram can no longer serve this file.", details: ["media_id": .string(mediaId)])
    }

    public static let payloadTooLarge = APIError(status: 413, code: "payload_too_large", message: "Request body over 64 KiB.")

    public static func rateLimited(retryAfter: Int) -> APIError {
        APIError(
            status: 429, code: "rate_limited", message: "Too many requests; retry after \(retryAfter)s.",
            details: ["retry_after": .number(Double(retryAfter))], headers: [("Retry-After", String(retryAfter))]
        )
    }

    public static func internalError(_ message: String) -> APIError {
        APIError(status: 500, code: "internal", message: message)
    }

    public static func sendFailed(reason: String, telegramCode: Int) -> APIError {
        APIError(
            status: 502, code: "send_failed", message: "Telegram did not send the message: \(reason.isEmpty ? "no reason given" : reason)",
            details: ["reason": .string(reason), "telegram_code": .number(Double(telegramCode))]
        )
    }

    public static func notLoggedIn(authState: String) -> APIError {
        APIError(status: 503, code: "not_logged_in", message: "The gateway has no Telegram session; log in to Telegram first.", details: ["auth_state": .string(authState)])
    }

    public static func sendTimeout(chatId: Int64, after timeout: Duration) -> APIError {
        APIError(
            status: 504, code: "send_timeout",
            message: "Telegram did not confirm the message within \(timeout.components.seconds)s. It may still be sent; if it is, it appears as message.new.",
            details: ["chat_id": .id(chatId)]
        )
    }

    public static func telegramUnavailable(connectionState: String) -> APIError {
        APIError(status: 503, code: "telegram_unavailable", message: "The Telegram connection is \(connectionState).", details: ["connection_state": .string(connectionState)])
    }
}
