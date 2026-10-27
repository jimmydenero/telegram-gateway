import ArgumentParser
import Foundation
import GatewayCore

struct MonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Show or change the monitored set (chats and folders the gateway watches).",
        subcommands: [List.self, Add.self, Remove.self, Folders.self],
        defaultSubcommand: List.self
    )

    /// Parses `<chat-id>` or `folder:<id>`.
    static func parseSource(_ raw: String) throws -> (chat: Int64?, folder: Int64?) {
        if raw.hasPrefix("folder:") {
            guard let id = Int64(raw.dropFirst("folder:".count)) else { throw ValidationError("folder id must be a number: \(raw)") }
            return (nil, id)
        }
        guard let id = Int64(raw) else { throw ValidationError("chat id must be a number (from `tgw monitor list --all` or `tgw chats`): \(raw)") }
        return (id, nil)
    }

    static func current(_ client: GatewayClient) async throws -> (chats: [Int64], folders: [Int64]) {
        let json = try Admin.check(try await client.get("/v1/admin/monitored-chats"))
        let chats = (json["chat_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Int64.init) }
        let folders = (json["folder_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Int64.init) }
        return (chats, folders)
    }

    static func put(_ client: GatewayClient, chats: [Int64], folders: [Int64]) async throws -> JSONValue {
        try Admin.check(try await client.put("/v1/admin/monitored-chats", [
            "chat_ids": .array(chats.map { .id($0) }), "folder_ids": .array(folders.map { .id($0) }),
        ]))
    }

    static func printSet(_ client: GatewayClient, _ set: JSONValue) async throws {
        print("chat_ids       \(Admin.idList(set["chat_ids"]))")
        print("folder_ids     \(Admin.idList(set["folder_ids"]))")
        let chats = try Admin.check(try await client.get("/v1/admin/chats"))
        print("effective      \((set["effective_chat_ids"]?.arrayValue ?? []).count) chats")
        Admin.table(["id", "type", "members", "title"], (chats["chats"]?.arrayValue ?? []).map { c in
            [c["id"]?.stringValue ?? "", c["type"]?.stringValue ?? "", c["member_count"]?.intValue.map(String.init) ?? "-", c["title"]?.stringValue ?? ""]
        })
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the monitored set, or every chat in the account with --all.")

        @Flag(help: "List every chat in the account's main chat list (needs a logged-in daemon).")
        var all = false

        @Flag(help: "List archived chats (implies --all).")
        var archive = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            if all || archive {
                var cursor: String?
                var rows: [[String]] = []
                repeat {
                    let path = "/v1/admin/chats?all=true&limit=200" + (archive ? "&list=archive" : "") + (cursor.map { "&cursor=\($0)" } ?? "")
                    let page = try Admin.check(try await client.get(path))
                    if output.json { print(page.pretty()) }
                    rows += (page["chats"]?.arrayValue ?? []).map { c in
                        [c["id"]?.stringValue ?? "", c["type"]?.stringValue ?? "", c["is_monitored"]?.boolValue == true ? "yes" : "", c["title"]?.stringValue ?? ""]
                    }
                    cursor = page["has_more"]?.boolValue == true ? page["next_cursor"]?.stringValue : nil
                } while cursor != nil
                if !output.json { Admin.table(["id", "type", "monitored", "title"], rows) }
                return
            }
            let set = try Admin.check(try await client.get("/v1/admin/monitored-chats"))
            if output.json { print(set.pretty()); return }
            try await printSet(client, set)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add chats (ids) or folders (folder:<id>) to the monitored set.")

        @Argument(help: "Chat ids, or folder:<id>.")
        var sources: [String]

        func run() async throws {
            let client = try Admin.client()
            var (chats, folders) = try await current(client)
            for raw in sources {
                let (chat, folder) = try parseSource(raw)
                if let chat, !chats.contains(chat) { chats.append(chat) }
                if let folder, !folders.contains(folder) { folders.append(folder) }
            }
            try await printSet(client, try await put(client, chats: chats, folders: folders))
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove chats or folders from the monitored set.")

        @Argument(help: "Chat ids, or folder:<id>.")
        var sources: [String]

        func run() async throws {
            let client = try Admin.client()
            var (chats, folders) = try await current(client)
            for raw in sources {
                let (chat, folder) = try parseSource(raw)
                if let chat { chats.removeAll { $0 == chat } }
                if let folder { folders.removeAll { $0 == folder } }
            }
            try await printSet(client, try await put(client, chats: chats, folders: folders))
        }
    }

    struct Folders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the account's chat folders.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.get("/v1/admin/folders"))
            if output.json { print(json.pretty()); return }
            Admin.table(["id", "monitored", "chats", "title"], (json["folders"]?.arrayValue ?? []).map { f in
                [f["id"]?.stringValue ?? "", f["is_monitored"]?.boolValue == true ? "yes" : "", String((f["chat_ids"]?.arrayValue ?? []).count), f["title"]?.stringValue ?? ""]
            })
        }
    }
}
