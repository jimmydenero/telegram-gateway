import Foundation
import GatewayCore
import TDLibClient

/// A scripted TDLib. Answers `getUser`, `getChat`, `getSupergroup`, `getBasicGroup`,
/// `getMessage`, `getChatHistory`, `getRemoteFile`, `getFile`, `downloadFile`, `deleteFile`,
/// `loadChats`, `getChats` from the objects a test registers, records every request, and
/// lets a test override any type with a handler. `sendMessage` answers as TDLib does, with a
/// pending message under a fresh local id (`Fixtures.localMessageId`); nothing is sent
/// anywhere, and the test decides the outcome by pushing an update.
public actor FakeTDLib: TDLibRequesting {
    public typealias Handler = @Sendable (JSONObject) throws -> JSONObject

    public private(set) var requests: [JSONBox] = []
    private var users: [Int64: JSONBox] = [:]
    private var chats: [Int64: JSONBox] = [:]
    private var supergroups: [Int64: JSONBox] = [:]
    private var basicGroups: [Int64: JSONBox] = [:]
    private var messages: [String: JSONBox] = [:]
    private var files: [String: JSONBox] = [:]
    private var fileIds: [Int: String] = [:]
    private var folderChats: [Int64: [Int64]] = [:]
    private var handlers: [String: Handler] = [:]
    /// Files that "finish" downloading when `downloadFile` is called, and where they land.
    private var downloadable: [String: String] = [:]
    private var sendCount = 0

    public init() {}

    // MARK: Registering objects

    public func add(user: JSONBox) {
        if let id = user.object.int64("id") { users[id] = user }
    }

    public func add(chat: JSONBox) {
        if let id = chat.object.int64("id") { chats[id] = chat }
    }

    public func add(supergroup: JSONBox) {
        if let id = supergroup.object.int64("id") { supergroups[id] = supergroup }
    }

    public func add(basicGroup: JSONBox) {
        if let id = basicGroup.object.int64("id") { basicGroups[id] = basicGroup }
    }

    public func add(message: JSONBox) {
        let m = message.object
        if let chat = m.int64("chat_id"), let id = m.int64("id") { messages["\(chat):\(id)"] = message }
    }

    /// A `file` object reachable by its `remote.id`. With `completedPath`, `downloadFile`
    /// completes it at once: `local.path` set, `is_downloading_completed = true`. Without it
    /// the download never finishes (a stalled download).
    public func add(file: JSONBox, completedPath: String? = nil) {
        let f = file.object
        guard let remoteId = f.object("remote")?.string("id") else { return }
        files[remoteId] = file
        if let id = f.int("id") { fileIds[id] = remoteId }
        if let completedPath { downloadable[remoteId] = completedPath }
    }

    public func setFolder(_ folderId: Int64, chatIds: [Int64]) {
        folderChats[folderId] = chatIds
    }

    public func on(_ type: String, _ handler: @escaping Handler) {
        handlers[type] = handler
    }

    public func requests(ofType type: String) -> [JSONBox] {
        requests.filter { $0.object.type == type }
    }

    public func clearRequests() {
        requests.removeAll()
    }

    // MARK: TDLibRequesting

    public func request(_ request: JSONBox) async throws -> JSONBox {
        requests.append(request)
        let r = request.object
        let type = r.type ?? ""
        if let handler = handlers[type] { return JSONBox(try handler(r)) }
        switch type {
        case "getUser":
            guard let id = r.int64("user_id"), let user = users[id] else { throw TDLibError(code: 400, message: "USER_ID_INVALID") }
            return user
        case "getChat":
            guard let id = r.int64("chat_id"), let chat = chats[id] else { throw TDLibError(code: 400, message: "Chat not found") }
            return chat
        case "getSupergroup":
            guard let id = r.int64("supergroup_id"), let g = supergroups[id] else { throw TDLibError(code: 400, message: "Supergroup not found") }
            return g
        case "getSupergroupFullInfo":
            return JSONBox(["@type": "supergroupFullInfo", "member_count": 0])
        case "getBasicGroup":
            guard let id = r.int64("basic_group_id"), let g = basicGroups[id] else { throw TDLibError(code: 400, message: "Group not found") }
            return g
        case "getMessage":
            guard let chat = r.int64("chat_id"), let id = r.int64("message_id"), let m = messages["\(chat):\(id)"] else {
                throw TDLibError(code: 404, message: "Not Found")
            }
            return m
        case "getChatHistory":
            return JSONBox(history(r))
        case "loadChats":
            throw TDLibError(code: 404, message: "Not Found")
        case "getChats":
            let folderId = r.object("chat_list")?.int64("chat_folder_id") ?? 0
            let ids = folderChats[folderId] ?? []
            return JSONBox(["@type": "chats", "total_count": ids.count, "chat_ids": ids.map { Int($0) }])
        case "getRemoteFile":
            guard let remoteId = r.string("remote_file_id"), let file = files[remoteId] else { throw TDLibError(code: 400, message: "Invalid remote file identifier") }
            return file
        case "getFile":
            guard let id = r.int("file_id"), let remoteId = fileIds[id], let file = files[remoteId] else { throw TDLibError(code: 400, message: "File not found") }
            return file
        case "downloadFile":
            guard let id = r.int("file_id"), let remoteId = fileIds[id], let file = files[remoteId] else { throw TDLibError(code: 400, message: "File not found") }
            if let path = downloadable[remoteId] {
                var object = file.object
                var local = object.object("local") ?? [:]
                local["@type"] = "localFile"
                local["is_downloading_completed"] = true
                local["path"] = path
                local["downloaded_size"] = object.int("size") ?? 0
                object["local"] = local
                let completed = JSONBox(object)
                files[remoteId] = completed
                return completed
            }
            // A stalled download: the file stays incomplete.
            return file
        case "sendMessage":
            sendCount += 1
            let chatId = r.int64("chat_id") ?? 0
            let text = r.object("input_message_content")?.object("text")?.string("text") ?? ""
            let replyTo = r.object("reply_to")?.int64("message_id").map(MessageId.toPublic)
            return Fixtures.pendingMessage(chatId: chatId, localId: Fixtures.localMessageId(sendCount), text: text, replyTo: replyTo)
        case "deleteFile":
            return JSONBox(["@type": "ok"])
        case "setOption", "close":
            return JSONBox(["@type": "ok"])
        default:
            throw TDLibError(code: 500, message: "FakeTDLib: no handler for \(type)")
        }
    }

    /// `getChatHistory` over the registered messages of the chat: newest first, `offset`
    /// negative returns messages newer than `from_message_id` (TDLib's semantics).
    private func history(_ r: JSONObject) -> JSONObject {
        let chatId = r.int64("chat_id") ?? 0
        let from = r.int64("from_message_id") ?? 0
        let offset = r.int("offset") ?? 0
        let limit = r.int("limit") ?? 100
        let all = messages.values.map(\.object).filter { $0.int64("chat_id") == chatId }.sorted { ($0.int64("id") ?? 0) > ($1.int64("id") ?? 0) }
        var selected: [JSONObject]
        if from == 0 {
            selected = all
        } else if offset < 0 {
            let newer = all.filter { ($0.int64("id") ?? 0) > from }.suffix(-offset)
            let older = all.filter { ($0.int64("id") ?? 0) <= from }
            selected = Array(newer) + older
        } else {
            selected = all.filter { ($0.int64("id") ?? 0) < from }
        }
        selected = Array(selected.prefix(limit))
        return ["@type": "messages", "total_count": selected.count, "messages": selected]
    }
}
