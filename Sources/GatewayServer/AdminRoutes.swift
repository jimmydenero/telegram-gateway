import Foundation
import GatewayCore
import GatewayLink
import HTTPTypes
import Hummingbird
import TDLibClient

/// `/v1/admin/*` (docs/api.md "Admin" sections). Every route here runs behind
/// `AdminOnlyMiddleware`.
struct AdminRoutes {
    let deps: Dependencies

    func register(on group: RouterGroup<GatewayRequestContext>) {
        group.get("/status") { _, context in try await status(viaLink: context.viaLink) }
        group.post("/reload") { _, _ in try await reload() }
        group.get("/links") { _, _ in json(["links": await linksJSON()]) }
        group.get("/auth") { _, _ in try await auth() }
        group.post("/auth/qr") { _, _ in try await authStep { try await deps.telegram.requestQr() } }
        group.post("/auth/phone") { request, context in
            let body = try await jsonBody(request, context)
            let phone = try body.requiredString("phone_number")
            return try await authStep { try await deps.telegram.setPhoneNumber(phone) }
        }
        group.post("/auth/code") { request, context in
            let body = try await jsonBody(request, context)
            let code = try body.requiredString("code")
            return try await authStep { try await deps.telegram.checkCode(code) }
        }
        group.post("/auth/password") { request, context in
            let body = try await jsonBody(request, context)
            let password = try body.requiredString("password")
            return try await authStep { try await deps.telegram.checkPassword(password) }
        }
        group.post("/auth/email") { request, context in
            let body = try await jsonBody(request, context)
            let email = try body.requiredString("email_address")
            return try await authStep { try await deps.telegram.setEmailAddress(email) }
        }
        group.post("/auth/email_code") { request, context in
            let body = try await jsonBody(request, context)
            let code = try body.requiredString("code")
            return try await authStep { try await deps.telegram.checkEmailCode(code) }
        }
        group.post("/auth/logout") { _, _ in try await authStep { try await deps.telegram.logOut() } }
        group.get("/access-requests") { request, _ in try await accessRequests(request) }
        group.post("/access-requests/:id/approve") { request, context in try await approve(request, context) }
        group.post("/access-requests/:id/deny") { request, context in try await deny(request, context) }
        group.get("/grants") { request, _ in try await grants(request) }
        group.get("/grants/:id") { _, context in try await grant(context) }
        group.delete("/grants/:id") { _, context in try await revoke(context) }
        group.post("/grants/:id/webhook/resume") { _, context in try await resumeWebhook(context) }
        group.get("/grants/:id/deliveries") { request, context in try await deliveries(request, context) }
        group.get("/chats") { request, _ in try await chats(request) }
        group.get("/folders") { _, _ in try await folders() }
        group.get("/monitored-chats") { _, _ in try await monitoredChats() }
        group.put("/monitored-chats") { request, context in try await putMonitoredChats(request, context) }
        group.post("/events/prune") { request, context in try await prune(request, context) }
    }

    // MARK: Status and login

    /// Over a link the `links` list is left out: it may name links to other Volgenic servers.
    func status(viaLink: Bool = false) async throws -> Response {
        let authState = await deps.telegram.authStateName()
        let connection = await deps.telegram.connectionState()
        let grants = try await deps.grants.list(includeRevoked: false)
        var webhooks = ["active": 0, "retrying": 0, "paused": 0]
        for grant in grants {
            if let state = grant.webhook?.state.rawValue { webhooks[state, default: 0] += 1 }
        }
        let backfill = await deps.monitor.backfill
        var body: JSONObjectValue = [
            "status": authState == "ready" && connection == .ready ? "ok" : "degraded",
            "version": .string(deps.version),
            "started_at": .date(deps.startedAt),
            "time": .date(deps.clock.now),
            "tdlib": ["auth_state": .string(authState), "connection_state": .string(connection.rawValue)],
            "head_seq": .number(Double(try await deps.eventLog.headSeq())),
            "account": await deps.telegram.account()?.json ?? .null,
            "monitored_chat_count": .number(Double(try await deps.store.effectiveMonitoredChatIds().count)),
            "grant_count": .number(Double(grants.count)),
            "webhooks": ["active": .number(Double(webhooks["active"] ?? 0)), "retrying": .number(Double(webhooks["retrying"] ?? 0)), "paused": .number(Double(webhooks["paused"] ?? 0))],
            "events_last_hour": .number(Double(try await deps.store.eventCount(recordedAfter: deps.clock.now.addingTimeInterval(-3600)))),
            "events_today": .number(Double(try await deps.store.eventCount(recordedAfter: Calendar.current.startOfDay(for: deps.clock.now)))),
            "oldest_seq": .optional(try await deps.eventLog.oldestSeq()),
            "media_cache_bytes": .number(Double(try await deps.mediaCache.cachedBytes())),
            "backfill": ["in_progress": .bool(backfill.inProgress), "chats_pending": .number(Double(backfill.chatsPending))],
        ]
        if !viaLink { body["links"] = await linksJSON() }
        return json(.object(body))
    }

    /// Every link to Volgenic and its state (docs/link.md "Link state").
    func linksJSON() async -> JSONValue {
        .array(await deps.links?.statuses().map(\.json) ?? [])
    }

    /// Re-reads config.json and brings the Telegram session in line with it, without
    /// touching the event log, grants or open connections.
    func reload() async throws -> Response {
        guard let reloader = deps.reloader else { throw APIError.notFound }
        let result = try await reloader.reload()
        deps.logger.info("reload: telegram \(result.telegram.rawValue), restart required for \(result.restartRequired)")
        return json(result.json)
    }

    func auth() async throws -> Response {
        let state = await deps.telegram.authState()
        var hint: JSONValue = .null
        if case .waitPassword(let h) = state, !h.isEmpty { hint = .string(h) }
        let code = await deps.telegram.codeInfo()
        return json([
            "auth_state": .string(state?.apiName ?? "unknown"),
            "qr_link": .optional(await deps.telegram.qrLink()),
            "phone_hint": .optional(code?.phoneNumber.isEmpty == false ? code?.phoneNumber : nil),
            "code_type": .optional(code?.type),
            "password_hint": hint,
        ])
    }

    private func authStep(_ step: () async throws -> Void) async throws -> Response {
        try await step()
        return try await auth()
    }

    // MARK: Access requests

    func accessRequests(_ request: Request) async throws -> Response {
        let all = Query(request).bool("all")
        let requests = try await deps.accessRequests.list(all: all)
        var items: [JSONValue] = []
        for r in requests { items.append(try await deps.accessRequests.adminJSON(r)) }
        return json(["access_requests": .array(items)])
    }

    func approve(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        let body = try await jsonBody(request, context)
        let chatIds = try body.ids("chat_ids")
        let folderId = try body.optionalString("folder_id").map { try parseChatId($0, field: "folder_id") }
        let chats: GrantChats
        switch (chatIds, folderId) {
        case (let ids?, nil): chats = .list(ids)
        case (nil, let folder?): chats = .folder(id: folder)
        default: throw APIError.invalidRequest("chat_ids", "exactly one of chat_ids or folder_id is required")
        }
        let grant = try await deps.accessRequests.approve(id, .init(chats: chats, scopes: try body.scopes("scopes", required: false)))
        await deps.dispatcher?.syncLoops()
        return json(try await deps.grants.json(grant))
    }

    func deny(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        let body = try await jsonBody(request, context)
        try await deps.accessRequests.deny(id, reason: try body.optionalString("reason"))
        return json(["status": "denied"])
    }

    // MARK: Grants

    func grants(_ request: Request) async throws -> Response {
        let includeRevoked = Query(request).bool("include_revoked")
        var items: [JSONValue] = []
        for grant in try await deps.grants.list(includeRevoked: includeRevoked) { items.append(try await deps.grants.json(grant)) }
        return json(["grants": .array(items)])
    }

    func grant(_ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        guard let grant = try await deps.grants.grant(id) else { throw APIError.notFound }
        let delivered = try await deps.store.eventsDelivered(grantId: id, since: deps.clock.now.addingTimeInterval(-86_400))
        let connections = await deps.rateLimiter.slotsInUse("ws:\(id)")
        return json([
            "grant": try await deps.grants.json(grant),
            "stats": ["events_delivered_24h": .number(Double(delivered)), "websocket_connections": .number(Double(connections))],
        ])
    }

    func revoke(_ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        try await deps.grants.revoke(id)
        return noContent()
    }

    func resumeWebhook(_ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        let webhook = try await deps.grants.resumeWebhook(grantId: id)
        await deps.dispatcher?.wake(grantId: id)
        return json(Grants.webhookSettingsJSON(webhook, secret: nil))
    }

    func deliveries(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let id = try context.parameters.require("id")
        guard try await deps.grants.grant(id) != nil else { throw APIError.notFound }
        let limit = try Query(request).int("limit", default: 50, range: 1...200)
        var rows = try await deps.store.deliveries(grantId: id, limit: limit + 1)
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        return json(["deliveries": .array(rows.map(\.json)), "has_more": .bool(hasMore)])
    }

    // MARK: Chats, folders, monitored set

    func chats(_ request: Request) async throws -> Response {
        let query = Query(request)
        let monitored = try await deps.store.effectiveMonitoredChatIds()
        guard query.bool("all") else {
            let chats = try await deps.store.chats(monitored.sorted())
            return json(["chats": .array(chats.map { $0.json(isMonitored: true) })])
        }
        let limit = try query.int("limit", default: 200, range: 1...500)
        let offset = query.string("cursor").flatMap(AdminRoutes.decodeCursor) ?? 0
        let tdlib = try await deps.telegram.requireLive()
        let mainList: JSONObject = ["@type": "chatListMain"]
        for _ in 0..<100 {
            do {
                _ = try await tdlib.request("loadChats", ["chat_list": mainList, "limit": 100])
            } catch let error as TDLibError where error.code == 404 {
                break
            }
        }
        let response = try await tdlib.request("getChats", ["chat_list": mainList, "limit": 10_000]).object
        let ids = (response.array("chat_ids") ?? []).compactMap(Translator.int64)
        let slice = ids.dropFirst(offset).prefix(limit)
        var items: [JSONValue] = []
        for id in slice {
            guard let info = try? await deps.translator.chatInfo(id) else { continue } // secret chats are omitted
            try await deps.store.upsertChat(info, now: deps.clock.now)
            items.append(info.json(isMonitored: monitored.contains(id)))
        }
        let next = offset + slice.count
        return json(["chats": .array(items), "has_more": .bool(next < ids.count), "next_cursor": .string(AdminRoutes.encodeCursor(next))])
    }

    static func encodeCursor(_ offset: Int) -> String { "c_" + Identifiers.base64url(Data(String(offset).utf8)) }

    static func decodeCursor(_ cursor: String) -> Int? {
        guard cursor.hasPrefix("c_") else { return nil }
        var base64 = String(cursor.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else { return nil }
        return Int(text)
    }

    func folders() async throws -> Response {
        let monitored = try await deps.store.monitoredSet()
        let folders = try await deps.store.folders()
        return json(["folders": .array(folders.map { folder in
            [
                "id": .id(folder.id), "title": .string(folder.title),
                "chat_ids": .array(folder.chatIds.map { .id($0) }), "is_monitored": .bool(monitored.folderIds.contains(folder.id)),
            ]
        })])
    }

    func monitoredChats() async throws -> Response {
        let set = try await deps.store.monitoredSet()
        let effective = try await deps.store.effectiveMonitoredChatIds().sorted()
        return json([
            "chat_ids": .array(set.chatIds.map { .id($0) }),
            "folder_ids": .array(set.folderIds.map { .id($0) }),
            "effective_chat_ids": .array(effective.map { .id($0) }),
        ])
    }

    func putMonitoredChats(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let body = try await jsonBody(request, context)
        guard let chatIds = try body.ids("chat_ids") else { throw APIError.invalidRequest("chat_ids", "is required (an array, possibly empty)") }
        guard let folderIds = try body.ids("folder_ids") else { throw APIError.invalidRequest("folder_ids", "is required (an array, possibly empty)") }
        try await deps.monitor.setMonitoredSet(MonitoredSet(chatIds: chatIds, folderIds: folderIds))
        return try await monitoredChats()
    }

    // MARK: Pruning

    func prune(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let body = try await jsonBody(request, context)
        let force = body["force"]?.boolValue ?? false
        let boundary: Int64
        if let beforeSeq = body["before_seq"] {
            guard let value = beforeSeq.int64Value, value > 0 else { throw APIError.invalidRequest("before_seq", "must be a positive integer") }
            boundary = value
        } else if let olderThan = body["older_than"]?.stringValue {
            guard let date = Timestamp.parse(olderThan) else { throw APIError.invalidRequest("older_than", "must be an RFC 3339 timestamp") }
            boundary = try await deps.eventLog.seq(recordedAtOrAfter: date)
        } else {
            throw APIError.invalidRequest("before_seq", "one of before_seq or older_than is required")
        }
        let (deleted, oldest) = try await Maintenance.pruneEvents(boundary: boundary, force: force, eventLog: deps.eventLog, grants: deps.grants)
        return json(["deleted": .number(Double(deleted)), "oldest_seq": .number(Double(oldest))])
    }
}
