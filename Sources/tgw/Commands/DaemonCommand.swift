import ArgumentParser
import Foundation
import GatewayCore

/// launchd management. The menu bar app will later register the daemon with SMAppService
/// instead; until then this writes a LaunchAgent plist and drives launchctl.
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Install, remove or inspect the launchd agent that keeps the daemon running.",
        subcommands: [Install.self, Uninstall.self, Status.self, Reload.self, Restart.self, Logs.self]
    )

    static let label = "local.telegram-gateway"

    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var domain: String { "gui/\(getuid())" }

    /// The daemon binary: `--binary`, else `GatewayDaemon` next to this `tgw`.
    static func resolveBinary(_ override: String?) throws -> URL {
        if let override { return URL(filePath: override) }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "GatewayDaemon")
        guard let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) else {
            throw CLIError("cannot find GatewayDaemon next to tgw; build it (`swift build -c release`) or pass --binary <path>")
        }
        return sibling.resolvingSymlinksInPath()
    }

    /// The plist with the placeholders filled in.
    static func renderPlist(binary: URL, paths: Paths) -> String {
        let template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>__BINARY__</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>TGW_HOME</key>
                <string>__HOME__</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>__LOGS__/daemon.out.log</string>
            <key>StandardErrorPath</key>
            <string>__LOGS__/daemon.err.log</string>
        </dict>
        </plist>
        """
        return template
            .replacingOccurrences(of: "__BINARY__", with: binary.path)
            .replacingOccurrences(of: "__HOME__", with: paths.home.path)
            .replacingOccurrences(of: "__LOGS__", with: paths.logs.path)
    }

    @discardableResult
    static func launchctl(_ arguments: [String], tolerate: [Int32] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 || tolerate.contains(process.terminationStatus) else {
            throw CLIError("launchctl \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the LaunchAgent plist and start the daemon (bootstrap).")

        @Option(help: "Path to the GatewayDaemon binary (default: next to tgw).")
        var binary: String?

        func run() async throws {
            let paths = Paths.resolve()
            try paths.prepare()
            let daemon = try DaemonCommand.resolveBinary(binary)
            let plist = DaemonCommand.agentPlist
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: plist.path) {
                // Replacing: stop the old one first (ignore "not loaded").
                try DaemonCommand.launchctl(["bootout", "\(DaemonCommand.domain)/\(DaemonCommand.label)"], tolerate: [3, 5, 113])
            }
            try DaemonCommand.renderPlist(binary: daemon, paths: paths).write(to: plist, atomically: true, encoding: .utf8)
            try DaemonCommand.launchctl(["bootstrap", DaemonCommand.domain, plist.path])
            print("installed \(plist.path)")
            print("binary    \(daemon.path)")
            print("data      \(paths.home.path)")
            print("logs      \(paths.logs.path)/daemon.err.log")
            print("The daemon starts now and at every login. `tgw health` to check it.")
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the daemon (bootout) and remove the LaunchAgent plist. Data is kept.")

        func run() async throws {
            let plist = DaemonCommand.agentPlist
            try DaemonCommand.launchctl(["bootout", "\(DaemonCommand.domain)/\(DaemonCommand.label)"], tolerate: [3, 5, 113])
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
                print("removed \(plist.path)")
            } else {
                print("no LaunchAgent plist at \(plist.path)")
            }
            print("daemon stopped; data in \(Paths.resolve().home.path) is untouched")
        }
    }

    struct Reload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make the running gateway re-read config.json (POST /v1/admin/reload).",
            discussion: "Changes to api_id / api_hash and to links (tgw link) take effect at once, however the gateway was started. Other settings (port, …) need `tgw daemon restart`."
        )

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = try Admin.client()
            let json = try Admin.check(try await client.post("/v1/admin/reload"))
            if output.json { print(json.pretty()); return }
            print("reloaded  telegram \(json["telegram"]?.stringValue ?? "?")")
            for key in ["started", "restarted", "stopped"] {
                for url in json["links"]?[key]?.arrayValue?.compactMap(\.stringValue) ?? [] { print("link      \(key) \(url)") }
            }
            let restart = (json["restart_required"]?.arrayValue ?? []).compactMap(\.stringValue)
            if !restart.isEmpty {
                print("restart   needed for: \(restart.joined(separator: ", ")) (`tgw daemon restart`)")
            }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restart the gateway installed by `tgw daemon install` (launchctl kickstart -k).",
            discussion: "Applies every setting in config.json. A gateway started another way (the menu bar app, a terminal) is not affected; restart it there."
        )

        func run() async throws {
            try DaemonCommand.launchctl(["kickstart", "-k", "\(DaemonCommand.domain)/\(DaemonCommand.label)"])
            print("restarted \(DaemonCommand.label)")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Whether launchd has the agent, its pid, and the daemon's health.")

        func run() async throws {
            let plist = DaemonCommand.agentPlist
            print("plist     \(FileManager.default.fileExists(atPath: plist.path) ? plist.path : "not installed")")
            let output = (try? DaemonCommand.launchctl(["print", "\(DaemonCommand.domain)/\(DaemonCommand.label)"])) ?? ""
            if output.isEmpty {
                print("launchd   not loaded")
            } else {
                let state = output.split(separator: "\n").first { $0.contains("state = ") }?.trimmingCharacters(in: .whitespaces) ?? "loaded"
                let pid = output.split(separator: "\n").first { $0.contains("pid = ") }?.trimmingCharacters(in: .whitespaces) ?? "pid = -"
                print("launchd   \(state), \(pid)")
            }
            let paths = Paths.resolve()
            if let holder = InstanceLock.holder(paths: paths) {
                print("lock      held by pid \(holder.pid) (\(holder.role))")
            } else {
                print("lock      free")
            }
            let config = try Config.load(paths: paths)
            let reply = try? await GatewayClient(port: config.port, token: nil).get("/v1/health")
            if let reply, reply.isSuccess {
                print("health    \(reply.json["status"]?.stringValue ?? "?") auth=\(reply.json["tdlib"]?["auth_state"]?.stringValue ?? "?") head_seq=\(reply.json["head_seq"]?.intValue ?? 0) on port \(config.port)")
            } else {
                print("health    daemon not answering on port \(config.port)")
            }
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the daemon's log (stderr under <TGW_HOME>/logs/).")

        @Option(name: .shortAndLong, help: "Lines to show.")
        var lines = 100

        @Flag(name: .shortAndLong, help: "Follow the log.")
        var follow = false

        func run() async throws {
            let log = Paths.resolve().logs.appending(path: "daemon.err.log")
            guard FileManager.default.fileExists(atPath: log.path) else { throw CLIError("no log yet at \(log.path)") }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/tail")
            process.arguments = (follow ? ["-f"] : []) + ["-n", String(lines), log.path]
            try process.run()
            process.waitUntilExit()
        }
    }
}
