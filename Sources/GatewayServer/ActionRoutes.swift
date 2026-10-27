import GatewayCore
import Hummingbird

extension AppRoutes {
    func actionChat(_ context: GatewayRequestContext) throws -> Int64 {
        try parseChatId(context.parameters.require("chat_id"), field: "chat_id")
    }
    func actionMessage(_ context: GatewayRequestContext) throws -> Int64 {
        guard let id = Int64(try context.parameters.require("message_id")), id > 0, id <= Int64.max >> 20 else { throw APIError.invalidRequest("message_id", "must be a message id") }
        return id
    }
    func forward(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let messages = try await deps.sender.forward(jsonBody(request, context), to: actionChat(context), as: context.requirePrincipal())
        return json(["messages": .array(messages.map(\.json))], status: .created)
    }
    func edit(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let message = try await deps.sender.edit(jsonBody(request, context), chat: actionChat(context), message: actionMessage(context), as: context.requirePrincipal())
        return json(["message": message.json])
    }
    func deleteMessages(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        try await deps.sender.delete(jsonBody(request, context), chat: actionChat(context), as: context.requirePrincipal())
        return noContent()
    }
    func react(_ request: Request, _ context: GatewayRequestContext, remove: Bool) async throws -> Response {
        try await deps.sender.react(jsonBody(request, context), chat: actionChat(context), message: actionMessage(context), remove: remove, as: context.requirePrincipal())
        return noContent()
    }
    func vote(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        try await deps.sender.vote(jsonBody(request, context), chat: actionChat(context), message: actionMessage(context), as: context.requirePrincipal())
        return noContent()
    }
    func settings(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let chat = try await deps.sender.settings(jsonBody(request, context), chat: actionChat(context), as: context.requirePrincipal())
        return json(["chat": chat.json(isMonitored: true)])
    }
    func markRead(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let principal = try context.requirePrincipal()
        try await deps.grants.require(.messagesMarkRead, principal)
        let body = try await jsonBody(request, context)
        var upTo: Int64?
        if let raw = try body.optionalString("up_to_message_id") {
            guard let id = Int64(raw), id > 0 else { throw APIError.invalidRequest("up_to_message_id", "must be a message id string") }
            upTo = id
        }
        let mentions = try ActionInput.bool(body, "mentions")
        let chat = try await deps.reader.markRead(chat: actionChat(context), upTo: upTo, mentions: mentions, as: principal)
        return json(["chat": chat.json(isMonitored: true)])
    }
    func startChat(_ request: Request, _ context: GatewayRequestContext) async throws -> Response {
        let chat = try await deps.sender.startChat(jsonBody(request, context), as: context.requirePrincipal(), store: deps.store, monitor: deps.monitor)
        return json(["chat": chat.json(isMonitored: true)], status: .created)
    }
}
