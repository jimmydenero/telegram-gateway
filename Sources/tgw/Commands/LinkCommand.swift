import ArgumentParser
import Foundation
import GatewayCore

/// Links to Volgenic (docs/link.md): the gateway dials out to a Volgenic server and lets that
/// Volgenic account drive it. URLs go to config.json, tokens to the secret store; `add` and
/// `remove` reload the running gateway so the change applies at once.
struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link the gateway to a Volgenic account, list links, or remove one.",
        subcommands: [Add.self, List.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a link (or replace its token) and connect it now.",
            discussion: "Paste the command Volgenic shows: tgw link add https://volgenic.com vgl_…"
        )

        @Argument(help: "The Volgenic server, for example https://volgenic.com.")
        var baseURL: String

        @Argument(help: "The link token Volgenic showed (vgl_…).")
        var token: String

        func run() async throws {
            let paths = Paths.resolve()
            let config = try Config.load(paths: paths)
            let secrets = Secrets.resolve(config: config, paths: paths)
            let added: (baseURL: String, replaced: Bool)
            do {
                added = try LinkSettings.add(baseURL: baseURL, token: token, paths: paths, secrets: secrets)
            } catch let error as GatewayError {
                throw CLIError(error.description)
            }
            print(added.replaced ? "replaced the token of the link to \(added.baseURL)" : "added link to \(added.baseURL)")
            guard let client = await LinkCommand.reload() else { return }
            // Give the link a moment to connect, so the person sees whether the token works.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                guard let status = try? await LinkCommand.status(client, added.baseURL) else { break }
                let state = status["state"]?.stringValue ?? "?"
                if state == "connected" || state == "unauthorized" || state == "waiting" {
                    LinkCommand.describe(status)
                    return
                }
            }
            print("state     connecting (tgw link list shows how it goes)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List links: URL, connected or not, since when, last error.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let paths = Paths.resolve()
            let config = try Config.load(paths: paths)
            var live: [String: JSONValue] = [:]
            var running = false
            if let client = try? Admin.client(), let reply = try? await client.get("/v1/admin/links"), reply.isSuccess {
                running = true
                if output.json { print(reply.json.pretty()); return }
                for item in reply.json["links"]?.arrayValue ?? [] {
                    if let url = item["base_url"]?.stringValue { live[url] = item }
                }
            }
            if output.json {
                print(JSONValue.object(["links": .array(config.links.map(\.json))]).pretty())
                return
            }
            guard !config.links.isEmpty else {
                print("no links. Add one with the command Volgenic shows: tgw link add <base_url> <token>")
                return
            }
            var rows: [[String]] = []
            for link in config.links {
                if let status = live[link.baseURL] {
                    let connected = status["connected"]?.boolValue == true ? "yes" : "no"
                    rows.append([link.baseURL, connected, status["state"]?.stringValue ?? "?", Admin.short(status["since"]), status["last_error"]?.stringValue ?? "-"])
                } else {
                    rows.append([link.baseURL, "no", running ? "not loaded (tgw daemon reload)" : "gateway not running", "-", "-"])
                }
            }
            Admin.table(["base_url", "connected", "state", "since", "last error"], rows)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a link and its token, and close it now.")

        @Argument(help: "The Volgenic server, as in tgw link list.")
        var baseURL: String

        func run() async throws {
            let paths = Paths.resolve()
            let config = try Config.load(paths: paths)
            let secrets = Secrets.resolve(config: config, paths: paths)
            let existed: Bool
            do {
                existed = try LinkSettings.remove(baseURL: baseURL, paths: paths, secrets: secrets)
            } catch let error as GatewayError {
                throw CLIError(error.description)
            }
            guard existed else { throw CLIError("there is no link to \(baseURL) (tgw link list)") }
            print("removed link to \(try LinkSettings.normalize(baseURL))")
            _ = await LinkCommand.reload()
        }
    }

    /// Asks the running gateway to reload; nil (with a note) when it is not running.
    static func reload() async -> GatewayClient? {
        guard let client = try? Admin.client(), let reply = try? await client.post("/v1/admin/reload") else {
            print("the gateway is not running; it applies this when it starts")
            return nil
        }
        guard reply.isSuccess else {
            print("the gateway did not reload (\(reply.errorCode ?? "http \(reply.status)"): \(reply.errorMessage ?? "")); run tgw daemon reload")
            return nil
        }
        return client
    }

    static func status(_ client: GatewayClient, _ baseURL: String) async throws -> JSONValue? {
        let json = try Admin.check(try await client.get("/v1/admin/links"))
        return json["links"]?.arrayValue?.first { $0["base_url"]?.stringValue == baseURL }
    }

    static func describe(_ status: JSONValue) {
        print("state     \(status["state"]?.stringValue ?? "?") since \(Admin.short(status["since"]))")
        if status["state"]?.stringValue != "connected", let error = status["last_error"]?.stringValue {
            print("error     \(error)")
        }
    }
}
