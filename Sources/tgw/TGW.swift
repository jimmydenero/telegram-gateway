import ArgumentParser
import Foundation

/// The gateway version reported to Telegram as `application_version`.
let applicationVersion = "0.1.0"

@main
struct TGW: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tgw",
        abstract: "Telegram Gateway command-line tool.",
        discussion: """
            Administers the gateway daemon over its local API (daemon, health, monitor, \
            requests, grants, events, send) and, for development before the daemon is installed, \
            opens TDLib directly (login, whoami, chats, watch, logout). Data lives in \
            ~/Library/Application Support/TelegramGateway/ (TGW_HOME overrides). The direct \
            commands refuse to run while the daemon holds TDLib.
            """,
        subcommands: [
            DaemonCommand.self, Health.self, MonitorCommand.self, RequestsCommand.self, GrantsCommand.self, EventsCommand.self, Send.self, SecretsCommand.self,
            Login.self, Whoami.self, Chats.self, Watch.self, Logout.self,
        ]
    )
}

/// An error whose message is meant for the person at the terminal.
struct CLIError: Error, CustomStringConvertible, LocalizedError {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? { description }
}

/// Writes to stderr without buffering surprises.
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
