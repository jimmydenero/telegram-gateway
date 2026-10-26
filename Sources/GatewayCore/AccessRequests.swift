import Foundation

/// The device-code style flow (docs/api.md "Access requests"): an app asks, the user approves
/// or denies, the app polls. Expiries: a pending request lasts `15:00`; a resolved one is
/// purged `10:00` after resolution and polling it returns `404`.
public actor AccessRequests {
    public static let pendingLifetime: TimeInterval = 15 * 60
    public static let resolvedLifetime: TimeInterval = 10 * 60

    private let store: Store
    private let grants: Grants
    private let clock: any GatewayClock

    public init(store: Store, grants: Grants, clock: any GatewayClock = SystemClock()) {
        self.store = store
        self.grants = grants
        self.clock = clock
    }

    /// What `POST /v1/access-requests` carries, already parsed.
    public struct Submission: Sendable, Equatable {
        public var name: String
        public var description: String
        public var scopes: [Scope]
        /// nil means `"any"`.
        public var requestedChats: [Int64]?
        public var webhookUrl: String?

        public init(name: String, description: String, scopes: [Scope], requestedChats: [Int64]?, webhookUrl: String?) {
            self.name = name
            self.description = description
            self.scopes = scopes
            self.requestedChats = requestedChats
            self.webhookUrl = webhookUrl
        }
    }

    /// Validates and stores a new pending request.
    public func create(_ submission: Submission) async throws -> AccessRequest {
        let name = submission.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else { throw APIError.invalidRequest("name", "must be 1–64 characters") }
        let description = submission.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...280).contains(description.count) else { throw APIError.invalidRequest("description", "must be 1–280 characters") }
        guard !submission.scopes.isEmpty else { throw APIError.invalidRequest("scopes", "must be a non-empty array of scope names") }
        if let url = submission.webhookUrl { try AccessRequests.validateWebhookUrl(url) }
        let now = clock.now
        let request = AccessRequest(
            id: Identifiers.requestId(), name: name, description: description,
            scopes: Array(Set(submission.scopes)).sorted(), requestedChats: submission.requestedChats,
            webhookUrl: submission.webhookUrl, createdAt: now, expiresAt: now.addingTimeInterval(AccessRequests.pendingLifetime)
        )
        try await store.insertAccessRequest(request)
        return request
    }

    /// `https` required unless the host is loopback (docs/api.md).
    public static func validateWebhookUrl(_ url: String) throws {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), let host = parsed.host()?.lowercased(), !host.isEmpty else {
            throw APIError.invalidRequest("webhook.url", "must be an absolute http(s) URL")
        }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        switch scheme {
        case "https": return
        case "http" where loopback: return
        case "http": throw APIError.invalidRequest("webhook.url", "must use https unless the host is 127.0.0.1, localhost or ::1")
        default: throw APIError.invalidRequest("webhook.url", "must be an absolute http(s) URL")
        }
    }

    /// The request as the poller sees it: expiry and purge applied on the fly. nil = purged
    /// or unknown (`404`).
    public func get(_ id: String) async throws -> AccessRequest? {
        guard var request = try await store.accessRequest(id) else { return nil }
        let now = clock.now
        if request.status == .pending, request.expiresAt <= now {
            request.status = .expired
            request.resolvedAt = request.expiresAt
            try await store.updateAccessRequest(request)
        }
        if request.status != .pending, let resolvedAt = request.resolvedAt,
           resolvedAt.addingTimeInterval(AccessRequests.resolvedLifetime) <= now {
            try await store.deleteAccessRequest(id)
            return nil
        }
        return request
    }

    /// Pending requests, or every retained request with `all`.
    public func list(all: Bool) async throws -> [AccessRequest] {
        try await sweep()
        return try await store.accessRequests(status: all ? nil : .pending)
    }

    /// Expires overdue pending requests and purges resolved ones past their hand-out window.
    public func sweep() async throws {
        for request in try await store.accessRequests(status: nil) {
            _ = try await get(request.id)
        }
    }

    public struct Approval: Sendable, Equatable {
        public var chats: GrantChats
        /// nil keeps the requested scopes.
        public var scopes: [Scope]?

        public init(chats: GrantChats, scopes: [Scope]? = nil) {
            self.chats = chats
            self.scopes = scopes
        }
    }

    /// Approves: validates against the monitored set and the requested scopes, creates the
    /// grant, and parks the token for the poller. Returns the grant (never the token).
    public func approve(_ id: String, _ approval: Approval) async throws -> Grant {
        guard var request = try await get(id) else { throw APIError.notFound }
        guard request.status == .pending else { throw APIError.alreadyResolved(request.status) }
        let scopes = approval.scopes ?? request.scopes
        guard !scopes.isEmpty else { throw APIError.invalidRequest("scopes", "must not be empty") }
        for scope in scopes where !request.scopes.contains(scope) {
            throw APIError.scopeNotRequested(scope.rawValue)
        }
        let monitored = try await store.monitoredSet()
        let monitoredChats = try await store.effectiveMonitoredChatIds()
        switch approval.chats {
        case .list(let ids):
            guard !ids.isEmpty else { throw APIError.invalidRequest("chat_ids", "must not be empty") }
            for chatId in ids where !monitoredChats.contains(chatId) {
                throw APIError.chatNotMonitored(chatId)
            }
        case .folder(let folderId):
            guard monitored.folderIds.contains(folderId) else { throw APIError.folderNotMonitored(folderId) }
        }
        let issued = try await grants.create(
            name: request.name, description: request.description, scopes: scopes.sorted(),
            chats: approval.chats, webhookUrl: request.webhookUrl
        )
        request.status = .approved
        request.resolvedAt = clock.now
        request.grantId = issued.grant.id
        request.issuedToken = issued.token
        request.issuedWebhookSecret = issued.webhookSecret
        try await store.updateAccessRequest(request)
        return issued.grant
    }

    public func deny(_ id: String, reason: String?) async throws {
        guard var request = try await get(id) else { throw APIError.notFound }
        guard request.status == .pending else { throw APIError.alreadyResolved(request.status) }
        request.status = .denied
        request.resolvedAt = clock.now
        request.deniedReason = reason
        try await store.updateAccessRequest(request)
    }

    // MARK: Rendering

    /// The poll response for the app (docs/api.md `GET /v1/access-requests/{id}`).
    public func pollJSON(_ request: AccessRequest) async throws -> JSONValue {
        switch request.status {
        case .pending:
            return ["request_id": .string(request.id), "status": "pending", "expires_at": .date(request.expiresAt)]
        case .expired:
            return ["request_id": .string(request.id), "status": "expired", "expires_at": .date(request.expiresAt)]
        case .denied:
            return [
                "request_id": .string(request.id), "status": "denied", "denied_at": .date(request.resolvedAt),
                "reason": .optional(request.deniedReason),
            ]
        case .approved:
            var grantJSON: JSONValue = .null
            if let grantId = request.grantId, let grant = try await grants.grant(grantId) {
                grantJSON = try await grants.json(grant)
            }
            var webhook: JSONValue = .null
            if let url = request.webhookUrl, let secret = request.issuedWebhookSecret {
                webhook = ["url": .string(url), "secret": .string(secret)]
            }
            return [
                "request_id": .string(request.id),
                "status": "approved",
                "approved_at": .date(request.resolvedAt),
                "token": .optional(request.issuedToken),
                "webhook": webhook,
                "grant": grantJSON,
            ]
        }
    }

    /// The admin view, with each requested chat's title and monitoring state resolved.
    public func adminJSON(_ request: AccessRequest) async throws -> JSONValue {
        var status: JSONValue = .null
        var requested: JSONValue = "any"
        if let ids = request.requestedChats {
            requested = .array(ids.map { .id($0) })
            let monitored = try await store.effectiveMonitoredChatIds()
            let known = try await store.chats(ids)
            status = .array(ids.map { id in
                [
                    "chat_id": .id(id),
                    "title": .optional(known.first { $0.id == id }?.title),
                    "is_monitored": .bool(monitored.contains(id)),
                ]
            })
        }
        return [
            "request_id": .string(request.id),
            "status": .string(request.status.rawValue),
            "name": .string(request.name),
            "description": .string(request.description),
            "scopes": .array(request.scopes.map { .string($0.rawValue) }),
            "requested_chats": requested,
            "requested_chats_status": status,
            "webhook_url": .optional(request.webhookUrl),
            "created_at": .date(request.createdAt),
            "expires_at": .date(request.expiresAt),
            "resolved_at": .date(request.resolvedAt),
            "grant_id": .optional(request.grantId),
        ]
    }
}
