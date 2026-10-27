import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import NIOCore

/// Unauthenticated routes: health and the app side of the access-request flow.
struct PublicRoutes {
    let deps: Dependencies

    func register(on group: RouterGroup<GatewayRequestContext>) {
        group.get("/health") { _, _ in try await health() }
        group.post("/access-requests") { request, context in try await createAccessRequest(request, context) }
        group.get("/access-requests/:id") { _, context in try await pollAccessRequest(context) }
    }

    func health() async throws -> Response {
        let authState = await deps.telegram.authStateName()
        let connection = await deps.telegram.connectionState()
        let ok = authState == "ready" && connection == .ready
        return json([
            "status": ok ? "ok" : "degraded",
            "version": .string(deps.version),
            "started_at": .date(deps.startedAt),
            "time": .date(deps.clock.now),
            "tdlib": ["auth_state": .string(authState), "connection_state": .string(connection.rawValue)],
            "head_seq": .number(Double(try await deps.eventLog.headSeq())),
        ])
    }

    func createAccessRequest(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let decision = await deps.rateLimiter.hit("access-requests:post", limit: 10)
        guard decision.allowed else { throw APIError.rateLimited(retryAfter: decision.retryAfter) }
        let body = try await jsonBody(request, context)
        var requestedChats: [Int64]?
        if let raw = body["requested_chats"], raw != .null, raw != "any" {
            guard raw.arrayValue != nil else { throw APIError.invalidRequest("requested_chats", "must be an array of chat ids or \"any\"") }
            requestedChats = try body.ids("requested_chats")
        }
        var webhookUrl: String?
        if let webhook = body["webhook"], webhook != .null {
            guard let object = webhook.objectValue else { throw APIError.invalidRequest("webhook", "must be an object with url") }
            webhookUrl = try object.requiredString("url")
        }
        let submission = AccessRequests.Submission(
            name: try body.requiredString("name"),
            description: try body.requiredString("description"),
            scopes: try body.scopes("scopes", required: true) ?? [],
            requestedChats: requestedChats,
            webhookUrl: webhookUrl
        )
        let created = try await deps.accessRequests.create(submission)
        return json([
            "request_id": .string(created.id),
            "poll_url": .string("http://127.0.0.1:\(deps.config.port)/v1/access-requests/\(created.id)"),
            "status": "pending",
            "expires_at": .date(created.expiresAt),
        ], status: .created)
    }

    func pollAccessRequest(_ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        let decision = await deps.rateLimiter.throttle("access-request:\(id)", interval: 2)
        guard decision.allowed else { throw APIError.rateLimited(retryAfter: decision.retryAfter) }
        guard let request = try await deps.accessRequests.get(id) else { throw APIError.notFound }
        return json(try await deps.accessRequests.pollJSON(request))
    }
}

/// Routes for app tokens (the admin token works too): own grant, webhook settings, chats,
/// events, history, sending, media.
struct AppRoutes {
    let deps: Dependencies

    func register(on group: RouterGroup<GatewayRequestContext>) {
        group.get("/me") { _, context in try await me(context) }
        group.get("/me/webhook") { _, context in try await getWebhook(context) }
        group.put("/me/webhook") { request, context in try await putWebhook(request, context) }
        group.delete("/me/webhook") { _, context in try await deleteWebhook(context) }
        group.post("/me/webhook/resume") { _, context in try await resumeWebhook(context) }
        group.get("/chats") { _, context in try await chats(context) }
        group.get("/chats/:chat_id") { _, context in try await chat(context) }
        group.get("/chats/:chat_id/messages") { request, context in try await history(request, context) }
        group.post("/chats/:chat_id/messages") { request, context in try await sendMessage(request, context) }
        group.get("/events") { request, context in try await events(request, context) }
        group.get("/media/:media_id") { request, context in try await media(request, context, head: false) }
        group.head("/media/:media_id") { request, context in try await media(request, context, head: true) }
    }

    // MARK: Grant

    func me(_ context: GatewayRequestContext) async throws -> Response {
        switch try context.requirePrincipal() {
        case .admin: return json(["grant": try await deps.grants.adminGrantJSON()])
        case .app(let grant):
            let fresh = try await deps.grants.grant(grant.id) ?? grant
            return json(["grant": try await deps.grants.json(fresh)])
        }
    }

    /// The webhook endpoints need an app grant; the admin token has no webhook.
    private func appGrant(_ context: GatewayRequestContext) throws -> Grant {
        guard let grant = try context.requirePrincipal().grant else { throw APIError.webhookNotConfigured }
        return grant
    }

    func getWebhook(_ context: GatewayRequestContext) async throws -> Response {
        let grant = try appGrant(context)
        let fresh = try await deps.grants.grant(grant.id) ?? grant
        guard fresh.webhook != nil else {
            var error = APIError.webhookNotConfigured
            error.status = 404
            throw error
        }
        let full = try await deps.grants.json(fresh)
        return json(full["webhook"] ?? .null)
    }

    func putWebhook(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let grant = try appGrant(context)
        let body = try await jsonBody(request, context)
        let url = try body.requiredString("url")
        try AccessRequests.validateWebhookUrl(url)
        let (webhook, secret) = try await deps.grants.setWebhook(grantId: grant.id, url: url)
        await deps.dispatcher?.wake(grantId: grant.id)
        return json(Grants.webhookSettingsJSON(webhook, secret: secret))
    }

    func deleteWebhook(_ context: GatewayRequestContext) async throws -> Response {
        let grant = try appGrant(context)
        try await deps.grants.deleteWebhook(grantId: grant.id)
        await deps.dispatcher?.stop(grantId: grant.id)
        return noContent()
    }

    func resumeWebhook(_ context: GatewayRequestContext) async throws -> Response {
        let grant = try appGrant(context)
        let webhook = try await deps.grants.resumeWebhook(grantId: grant.id)
        await deps.dispatcher?.wake(grantId: grant.id)
        return json(Grants.webhookSettingsJSON(webhook, secret: nil))
    }

    // MARK: Chats

    func chats(_ context: GatewayRequestContext) async throws -> Response {
        let principal = try context.requirePrincipal()
        try await deps.grants.require(.chatsRead, principal)
        var items: [JSONValue] = []
        for (chat, isMonitored) in try await deps.grants.chats(for: principal) {
            items.append(await deps.live(chat).json(isMonitored: isMonitored))
        }
        return json(["chats": .array(items)])
    }

    func chat(_ context: GatewayRequestContext) async throws -> Response {
        let principal = try context.requirePrincipal()
        try await deps.grants.require(.chatsRead, principal)
        let chatId = try parseChatId(try context.parameters.require("chat_id"), field: "chat_id")
        if let grant = principal.grant {
            guard try await deps.grants.grantedChatIds(grant).contains(chatId) else { throw APIError.chatNotGranted }
        }
        guard let chat = try await deps.store.chat(chatId) else { throw APIError.chatNotGranted }
        let monitored = try await deps.store.effectiveMonitoredChatIds().contains(chatId)
        return json(["chat": await deps.live(chat).json(isMonitored: monitored)])
    }

    // MARK: History

    func history(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let principal = try context.requirePrincipal()
        try await deps.grants.require(.historyRead, principal)
        let chatId = try parseChatId(try context.parameters.require("chat_id"), field: "chat_id")
        try await deps.grants.requireChat(chatId, principal)
        let decision = await deps.rateLimiter.hit("history:\(principal.rateLimitKey)", limit: 60)
        guard decision.allowed else { throw APIError.rateLimited(retryAfter: decision.retryAfter) }
        let query = Query(request)
        let limit = try query.int("limit", default: 50, range: 1...100)
        let before = try query.int64("before") ?? 0
        _ = try await deps.telegram.requireLive()
        let page = try await deps.translator.history(chatId: chatId, fromInternalId: MessageId.toInternal(before), offset: 0, limit: limit)
        for tm in page {
            for record in tm.media { try await deps.store.recordMedia(record, chatId: chatId) }
        }
        return json([
            "messages": .array(page.map { $0.message.json }),
            "has_more": .bool(page.count >= limit),
            "next_before": .id(page.last?.message.id ?? before),
        ])
    }

    // MARK: Sending

    func sendMessage(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let principal = try context.requirePrincipal()
        try await deps.grants.require(.messagesSend, principal)
        let chatId = try parseChatId(try context.parameters.require("chat_id"), field: "chat_id")
        let body = try await jsonBody(request, context)
        let text = try body.requiredString("text")
        var replyTo: Int64?
        if let raw = try body.optionalString("reply_to") {
            guard let id = Int64(raw), id > 0 else { throw APIError.invalidRequest("reply_to", "must be a message id string") }
            replyTo = id
        }
        let message = try await deps.sender.send(text, to: chatId, replyTo: replyTo, as: principal)
        return json(["message": message.json], status: .created)
    }

    // MARK: Events

    func events(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let principal = try context.requirePrincipal()
        let query = Query(request)
        let since = try query.int64("since") ?? 0
        let limit = try query.int("limit", default: 100, range: 1...1000)
        let filter = try await EventFilter(deps: deps, principal: principal, types: try query.eventTypes(), chatIds: try query.chatIds())
        let page: EventLog.Page
        do {
            page = try await deps.eventLog.page(since: since, limit: limit, types: filter.types, chatIds: filter.chatIds)
        } catch EventLog.PageError.historyPruned(let oldest) {
            throw APIError.historyPruned(oldestSeq: oldest)
        }
        return json([
            "events": .array(page.events.map { $0.json() }),
            "has_more": .bool(page.hasMore),
            "next_since": .number(Double(page.nextSince)),
            "head_seq": .number(Double(page.headSeq)),
        ])
    }

    // MARK: Media

    func media(_ request: Request, _ context: GatewayRequestContext, head: Bool) async throws -> Response {
        let principal = try context.requirePrincipal()
        try await deps.grants.require(.mediaRead, principal)
        let mediaId = try context.parameters.require("media_id")
        // Never distinguish unknown from ungranted.
        guard let record = try await deps.mediaCache.record(mediaId) else { throw APIError.chatNotGranted }
        let visible: Set<Int64>
        if let granted = try await deps.grants.visibleChatIds(principal) { visible = granted } else { visible = try await deps.store.effectiveMonitoredChatIds() }
        let referencedIn = try await deps.store.mediaChatIds(mediaId)
        guard !referencedIn.isDisjoint(with: visible) else { throw APIError.chatNotGranted }

        var headers = HTTPFields()
        headers[.contentType] = record.media.mime ?? "application/octet-stream"
        headers[.eTag] = "\"\(mediaId)\""
        headers[.cacheControl] = "private, max-age=31536000, immutable"
        headers[.acceptRanges] = "bytes"
        if let name = record.media.fileName {
            headers[.contentDisposition] = "inline; filename=\"\(name.replacingOccurrences(of: "\"", with: ""))\""
        }
        if head {
            let cached = try await deps.mediaCache.isCached(mediaId)
            headers[.cached] = cached ? "true" : "false"
            if let size = record.media.size { headers[.contentLength] = String(size) }
            return Response(status: .ok, headers: headers)
        }

        let slotKey = "media:\(principal.rateLimitKey)"
        let cachedAlready = try await deps.mediaCache.isCached(mediaId)
        if !cachedAlready {
            _ = try await deps.telegram.requireLive()
            guard await deps.rateLimiter.acquire(slotKey, max: 4) else { throw APIError.rateLimited(retryAfter: 5) }
        }
        let fetch: MediaCache.Fetch
        do {
            fetch = try await deps.mediaCache.fetch(mediaId, wait: .seconds(30))
        } catch {
            if !cachedAlready { await deps.rateLimiter.release(slotKey) }
            throw error
        }
        if !cachedAlready { await deps.rateLimiter.release(slotKey) }

        switch fetch {
        case .downloading(let downloaded, let size):
            headers[.contentType] = "application/json; charset=utf-8"
            headers[.retryAfter] = "5"
            let body: JSONValue = ["status": "downloading", "media_id": .string(mediaId), "bytes_downloaded": .number(Double(downloaded)), "size": .optional(size)]
            return Response(status: .accepted, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: body.serialized())))
        case .ready(let path, let bytes):
            let fileIO = FileIO()
            if let range = request.headers[.range], let (lower, upper) = AppRoutes.parseRange(range, size: bytes) {
                headers[.contentRange] = "bytes \(lower)-\(upper)/\(bytes)"
                headers[.contentLength] = String(upper - lower + 1)
                let body = try await fileIO.loadFile(path: path, range: Int(lower)...Int(upper), context: context)
                return Response(status: .partialContent, headers: headers, body: body)
            }
            headers[.contentLength] = String(bytes)
            let body = try await fileIO.loadFile(path: path, context: context)
            return Response(status: .ok, headers: headers, body: body)
        }
    }

    /// `bytes=a-b`, `bytes=a-`, `bytes=-n` → inclusive bounds within `size`.
    static func parseRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard size > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let start = Int64(parts[0])
        let end = Int64(parts[1])
        switch (start, end) {
        case (let s?, let e?) where s <= e && s < size: return (s, min(e, size - 1))
        case (let s?, nil) where s < size: return (s, size - 1)
        case (nil, let n?) where n > 0: return (max(0, size - n), size - 1)
        default: return nil
        }
    }
}

/// What a principal may read from the log, narrowed by the request's own filters.
struct EventFilter {
    let types: Set<EventType>?
    let chatIds: Set<Int64>?

    init(deps: Dependencies, principal: Principal, types requested: Set<EventType>?, chatIds requestedChats: Set<Int64>?) async throws {
        let allowedTypes = await deps.grants.visibleEventTypes(principal)
        let allowedChats = try await deps.grants.visibleChatIds(principal)
        switch (allowedTypes, requested) {
        case (nil, let r): types = r
        case (let a?, nil): types = a
        case (let a?, let r?): types = a.intersection(r)
        }
        switch (allowedChats, requestedChats) {
        case (nil, let r): chatIds = r
        case (let a?, nil): chatIds = a
        case (let a?, let r?): chatIds = a.intersection(r)
        }
    }
}
