import Foundation

/// Who is calling: the admin token, or an app through its grant.
public enum Principal: Sendable, Equatable {
    case admin
    case app(Grant)

    public var isAdmin: Bool {
        if case .admin = self { return true }
        return false
    }

    public var grant: Grant? {
        if case .app(let grant) = self { return grant }
        return nil
    }

    /// A key for per-token rate limiting and connection counting.
    public var rateLimitKey: String {
        switch self {
        case .admin: "admin"
        case .app(let grant): grant.id
        }
    }
}

/// The access model (docs/grants.md): token lookup, the `granted ∩ monitored` rule evaluated
/// at read time, scope gating, token issue and revocation, webhook settings.
public actor Grants {
    private let store: Store
    private let clock: any GatewayClock
    private var adminTokenHash: String
    private var revocationSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(store: Store, adminToken: String, clock: any GatewayClock = SystemClock()) {
        self.store = store
        self.clock = clock
        self.adminTokenHash = Identifiers.hash(adminToken)
    }

    /// Replaces the admin token the daemon accepts (after `Secrets.regenerateAdminToken`).
    public func setAdminToken(_ token: String) {
        adminTokenHash = Identifiers.hash(token)
    }

    // MARK: Authentication

    /// Resolves a bearer token. Throws the documented 401s.
    public func authenticate(bearer token: String?) async throws -> Principal {
        guard let token, !token.isEmpty else { throw APIError.missingToken }
        guard Identifiers.looksLikeToken(token) else { throw APIError.invalidToken }
        let hash = Identifiers.hash(token)
        if hash == adminTokenHash { return .admin }
        guard let grant = try await store.grant(tokenHash: hash) else { throw APIError.invalidToken }
        if let revokedAt = grant.revokedAt { throw APIError.tokenRevoked(at: revokedAt) }
        try await store.touchGrant(grant.id, lastSeenAt: clock.now)
        return .app(grant)
    }

    /// Throws `insufficient_scope` unless the principal holds `scope` (admin holds all).
    public func require(_ scope: Scope, _ principal: Principal) throws {
        guard let grant = principal.grant else { return }
        guard grant.has(scope) else { throw APIError.insufficientScope(required: scope, granted: grant.scopes) }
    }

    // MARK: Effective chats

    /// `granted ∩ monitored`, sorted, computed now.
    public func effectiveChatIds(_ grant: Grant) async throws -> [Int64] {
        let monitored = try await store.effectiveMonitoredChatIds()
        return try await grantedChatIds(grant).filter { monitored.contains($0) }.sorted()
    }

    /// The chats the grant names (list, or the folder's current contents), regardless of monitoring.
    public func grantedChatIds(_ grant: Grant) async throws -> [Int64] {
        switch grant.chats {
        case .list(let ids): return ids
        case .folder(let id): return try await store.folder(id)?.chatIds ?? []
        }
    }

    /// Chat ids the principal may read now: nil for admin (everything), else the effective set.
    public func visibleChatIds(_ principal: Principal) async throws -> Set<Int64>? {
        guard let grant = principal.grant else { return nil }
        return Set(try await effectiveChatIds(grant))
    }

    /// Event types the principal's scopes allow: nil for admin (all).
    public func visibleEventTypes(_ principal: Principal) -> Set<EventType>? {
        guard let grant = principal.grant else { return nil }
        return Grants.visibleEventTypes(scopes: grant.scopes)
    }

    public static func visibleEventTypes(scopes: [Scope]) -> Set<EventType> {
        Set(EventType.allCases.filter { scopes.contains($0.requiredScope) })
    }

    /// Throws `chat_not_granted` unless the chat is in the principal's effective set. Admin:
    /// the chat must be monitored.
    public func requireChat(_ chatId: Int64, _ principal: Principal) async throws {
        if let visible = try await visibleChatIds(principal) {
            guard visible.contains(chatId) else { throw APIError.chatNotGranted }
        } else {
            guard try await store.effectiveMonitoredChatIds().contains(chatId) else { throw APIError.chatNotGranted }
        }
    }

    /// The chats an app sees at `GET /v1/chats`: every granted chat known to the cache, with
    /// `is_monitored` telling which are covered right now.
    public func chats(for principal: Principal) async throws -> [(chat: ChatInfo, isMonitored: Bool)] {
        let monitored = try await store.effectiveMonitoredChatIds()
        let ids: [Int64]
        if let grant = principal.grant {
            ids = try await grantedChatIds(grant)
        } else {
            ids = monitored.sorted()
        }
        return try await store.chats(ids).map { ($0, monitored.contains($0.id)) }
    }

    // MARK: Rendering

    /// The grant object with `effective_chat_ids`, folder title and webhook backlog resolved.
    public func json(_ grant: Grant) async throws -> JSONValue {
        let effective = try await effectiveChatIds(grant)
        var folderTitle: String?
        if case .folder(let id) = grant.chats { folderTitle = try await store.folder(id)?.title }
        var pending: Int64 = 0
        if let webhook = grant.webhook {
            pending = try await store.eventCount(since: webhook.cursorSeq, types: Grants.visibleEventTypes(scopes: grant.scopes), chatIds: Set(effective))
        }
        return grant.json(effectiveChatIds: effective, folderTitle: folderTitle, pendingWebhookEvents: pending)
    }

    /// The synthetic grant an admin token sees at `GET /v1/me`.
    public func adminGrantJSON() async throws -> JSONValue {
        let monitored = try await store.effectiveMonitoredChatIds().sorted()
        return [
            "id": "grant_admin",
            "app": ["name": "Admin", "description": "The admin token: every scope over every monitored chat."],
            "scopes": .array(Scope.allCases.map { .string($0.rawValue) }),
            "chats": ["mode": "list", "chat_ids": .array(monitored.map { .id($0) })],
            "effective_chat_ids": .array(monitored.map { .id($0) }),
            "webhook": .null,
            "created_at": .null,
            "last_seen_at": .null,
            "revoked_at": .null,
        ]
    }

    // MARK: Lifecycle

    public struct Issued: Sendable {
        public var grant: Grant
        public var token: String
        public var webhookSecret: String?
    }

    /// Creates a grant and its token. The token is returned once; only its hash is stored.
    /// A webhook cursor starts at the current head: the app gets new events only.
    public func create(name: String, description: String, scopes: [Scope], chats: GrantChats, webhookUrl: String?) async throws -> Issued {
        let token = Identifiers.token()
        var webhook: Webhook?
        var secret: String?
        if let webhookUrl {
            let s = Identifiers.webhookSecret()
            secret = s
            webhook = Webhook(url: webhookUrl, secret: s, cursorSeq: try await store.headSeq())
        }
        let grant = Grant(
            id: Identifiers.grantId(), name: name, description: description, scopes: scopes.sorted(), chats: chats,
            tokenHash: Identifiers.hash(token), webhook: webhook, createdAt: clock.now
        )
        try await store.insertGrant(grant)
        return Issued(grant: grant, token: token, webhookSecret: secret)
    }

    public func grant(_ id: String) async throws -> Grant? {
        try await store.grant(id)
    }

    /// Current (non-revoked) grants, or all.
    public func list(includeRevoked: Bool) async throws -> [Grant] {
        try await store.grants(includeRevoked: includeRevoked)
    }

    /// Grants with a webhook that is not paused and not revoked: what the dispatcher drives.
    public func grantsWithWebhooks() async throws -> [Grant] {
        try await store.grants(includeRevoked: false).filter { $0.webhook != nil }
    }

    /// Revokes: the token stops working, webhook deliveries are dropped, subscribers (open
    /// WebSockets, the dispatcher) are told. Idempotent; unknown id → `not_found`.
    public func revoke(_ id: String) async throws {
        guard var grant = try await store.grant(id) else { throw APIError.notFound }
        if grant.isRevoked { return }
        grant.revokedAt = clock.now
        try await store.updateGrant(grant)
        try await store.deleteDeliveries(grantId: id)
        for (_, continuation) in revocationSubscribers { continuation.yield(id) }
    }

    /// Grant ids as they are revoked.
    public func revocations() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        revocationSubscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeRevocationSubscriber(id) } }
        return stream
    }

    private func removeRevocationSubscriber(_ id: UUID) {
        revocationSubscribers.removeValue(forKey: id)
    }

    /// Deletes revoked grants older than 30 days.
    public func sweepRevoked() async throws {
        _ = try await store.deleteGrants(revokedBefore: clock.now.addingTimeInterval(-30 * 86_400))
    }

    // MARK: Webhooks

    /// Sets or replaces the webhook URL with a fresh secret. A paused webhook becomes active
    /// and continues from its cursor; a new webhook starts at the head.
    public func setWebhook(grantId: String, url: String) async throws -> (webhook: Webhook, secret: String) {
        guard var grant = try await store.grant(grantId), !grant.isRevoked else { throw APIError.notFound }
        let secret = Identifiers.webhookSecret()
        let cursor: Int64
        if let existing = grant.webhook { cursor = existing.cursorSeq } else { cursor = try await store.headSeq() }
        var webhook = Webhook(url: url, secret: secret, cursorSeq: cursor)
        webhook.lastDeliveryAt = grant.webhook?.lastDeliveryAt
        grant.webhook = webhook
        try await store.updateGrant(grant)
        try await store.deleteDeliveries(grantId: grantId)
        return (webhook, secret)
    }

    public func deleteWebhook(grantId: String) async throws {
        guard var grant = try await store.grant(grantId) else { throw APIError.notFound }
        guard grant.webhook != nil else { throw APIError.webhookNotConfigured }
        grant.webhook = nil
        try await store.updateGrant(grant)
        try await store.deleteDeliveries(grantId: grantId)
    }

    /// `paused` → `active`, keeping the cursor. `409 webhook_not_paused` otherwise.
    public func resumeWebhook(grantId: String) async throws -> Webhook {
        guard var grant = try await store.grant(grantId) else { throw APIError.notFound }
        guard var webhook = grant.webhook else { throw APIError.webhookNotConfigured }
        guard webhook.state == .paused else { throw APIError.webhookNotPaused(webhook.state) }
        webhook.state = .active
        webhook.pausedAt = nil
        webhook.failingSince = nil
        webhook.lastError = nil
        grant.webhook = webhook
        try await store.updateGrant(grant)
        return webhook
    }

    /// The dispatcher's way to persist delivery progress.
    public func updateWebhook(grantId: String, _ update: @Sendable (inout Webhook) -> Void) async throws {
        guard var grant = try await store.grant(grantId), var webhook = grant.webhook else { return }
        update(&webhook)
        grant.webhook = webhook
        try await store.updateGrant(grant)
    }

    /// `{ url, secret?, state, cursor_seq }` as returned by `PUT /v1/me/webhook` and resume.
    public static func webhookSettingsJSON(_ webhook: Webhook, secret: String?) -> JSONValue {
        var object: JSONObjectValue = ["url": .string(webhook.url)]
        if let secret { object["secret"] = .string(secret) }
        object["state"] = .string(webhook.state.rawValue)
        object["cursor_seq"] = .number(Double(webhook.cursorSeq))
        return .object(object)
    }
}
