import ArgumentParser
import Foundation
import GatewayCore

struct Health: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the daemon's health (GET /v1/health) and, with the admin token, its full status.")

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let paths = Paths.resolve()
        let config = try Config.load(paths: paths)
        let anonymous = GatewayClient(port: config.port, token: nil)
        let health = try Admin.check(try await anonymous.get("/v1/health"))
        var status: JSONValue?
        if let admin = try? Admin.client() {
            status = try Admin.check(try await admin.get("/v1/admin/status"))
        }
        if output.json {
            print((status ?? health).pretty())
            return
        }
        let s = status ?? health
        print("status        \(s["status"]?.stringValue ?? "?")   version \(s["version"]?.stringValue ?? "?")   port \(config.port)")
        print("telegram      auth=\(s["tdlib"]?["auth_state"]?.stringValue ?? "?")  connection=\(s["tdlib"]?["connection_state"]?.stringValue ?? "?")")
        if let account = s["account"], !account.isNull {
            print("account       \(account["display_name"]?.stringValue ?? "") (@\(account["username"]?.stringValue ?? "-")) id=\(account["user_id"]?.stringValue ?? "?") phone=…\(account["phone_last4"]?.stringValue ?? "")")
        }
        print("events        head_seq=\(s["head_seq"]?.intValue ?? 0)  oldest_seq=\(s["oldest_seq"]?.intValue.map(String.init) ?? "-")  last_hour=\(s["events_last_hour"]?.intValue ?? 0)")
        if status != nil {
            print("monitored     \(s["monitored_chat_count"]?.intValue ?? 0) chats   grants \(s["grant_count"]?.intValue ?? 0)   webhooks active=\(s["webhooks"]?["active"]?.intValue ?? 0) retrying=\(s["webhooks"]?["retrying"]?.intValue ?? 0) paused=\(s["webhooks"]?["paused"]?.intValue ?? 0)")
            print("backfill      in_progress=\(s["backfill"]?["in_progress"]?.boolValue ?? false) chats_pending=\(s["backfill"]?["chats_pending"]?.intValue ?? 0)   media_cache=\(s["media_cache_bytes"]?.intValue ?? 0) bytes")
        }
        for link in s["links"]?.arrayValue ?? [] {
            let state = link["state"]?.stringValue ?? "?"
            let error = state == "connected" ? "" : (link["last_error"]?.stringValue).map { "  last error: \($0)" } ?? ""
            print("link          \(link["base_url"]?.stringValue ?? "?")  \(state) since \(Admin.short(link["since"]))\(error)")
        }
        print("started       \(Admin.short(s["started_at"]))")
    }
}
