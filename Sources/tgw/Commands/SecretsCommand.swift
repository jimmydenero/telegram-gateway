import ArgumentParser
import Foundation
import GatewayCore

/// The secret store (docs/development.md "Secrets"): the file store by default, the login
/// Keychain when config.json says `"secrets": "keychain"`.
struct SecretsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Show where secrets live or regenerate the admin token.",
        subcommands: [Show.self, RegenerateAdminToken.self],
        defaultSubcommand: Show.self
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Which store is in use and which secrets exist (values are never printed).")

        func run() async throws {
            let paths = Paths.resolve()
            let config = try Config.load(paths: paths)
            let store = Secrets.resolve(config: config, paths: paths)
            print("backend      \(config.secrets.rawValue)")
            print("location     \(store.description)")
            print("db key       \(try store.read(Secrets.databaseKeyAccount) != nil ? "present" : "absent (created on first TDLib open)")")
            print("admin token  \(try Secrets.existingAdminToken(store) != nil ? "present" : "absent (created when the daemon first runs)")")
            for link in config.links {
                print("link token   \(link.baseURL): \(try LinkSettings.token(for: link.baseURL, secrets: store) != nil ? "present" : "absent")")
            }
        }
    }

    struct RegenerateAdminToken: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "regenerate-admin-token", abstract: "Replace the admin token. Restart the daemon so it picks the new one up.")

        func run() async throws {
            let paths = Paths.resolve()
            let config = try Config.load(paths: paths)
            let store = Secrets.resolve(config: config, paths: paths)
            try Secrets.regenerateAdminToken(store)
            print("new admin token written to \(store.description); restart the daemon (`tgw daemon uninstall` then `install`, or launchctl kickstart)")
        }
    }
}
