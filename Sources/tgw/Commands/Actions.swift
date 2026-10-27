import ArgumentParser
import Foundation
import GatewayCore

/// Owner actions use the HTTP API; no CLI command opens TDLib.
private func action(_ method: String, _ path: String, _ body: JSONObjectValue, yes: Bool) async throws {
    if !yes {
        print("Act as your Telegram account: \(method) \(path)\n\(JSONValue.object(body).pretty())")
        guard ["y", "yes"].contains(try Prompt.line("Continue? [y/N] ").lowercased()) else { print("cancelled"); return }
    }
    let client = try Admin.client()
    let response = try Admin.check(try await client.send(method, path, body: .object(body)))
    print(response == .null ? "done" : response.pretty())
}

struct React: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add or remove your reaction: <chat> <message> <emoji>.")
    @Argument(parsing: .allUnrecognized) var values: [String] = []
    @Flag var remove = false
    @Flag var custom = false
    @Flag var big = false
    @Flag(name: .shortAndLong) var yes = false
    func validate() throws { try validateActionIds(values, count: 3) }
    func run() async throws {
        try await action(remove ? "DELETE" : "PUT", "/v1/chats/\(values[0])/messages/\(values[1])/reactions", [custom ? "custom_emoji_id" : "emoji": .string(values[2]), "big": .bool(big)], yes: yes)
    }
}
struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Edit your message or caption: <chat> <message> <text>.")
    @Argument(parsing: .allUnrecognized) var values: [String] = []
    @Flag(name: .shortAndLong) var yes = false
    func validate() throws { try validateActionIds(values, count: 3) }
    func run() async throws { try await action("PATCH", "/v1/chats/\(values[0])/messages/\(values[1])", ["text": .string(values[2])], yes: yes) }
}
struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete your messages: <chat> <message> […].")
    @Argument(parsing: .allUnrecognized) var values: [String] = []
    @Flag var forEveryone = false
    @Flag(name: .shortAndLong) var yes = false
    func validate() throws { try validateActionIds(values, count: nil); for value in values.dropFirst() { try validateMessageId(value) } }
    func run() async throws { try await action("DELETE", "/v1/chats/\(values[0])/messages", ["message_ids": .array(values.dropFirst().map(JSONValue.string)), "for_everyone": .bool(forEveryone)], yes: yes) }
}
struct Forward: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Forward messages: <destination-chat> <source-chat> <message> […].")
    @Argument(parsing: .allUnrecognized) var values: [String] = []
    @Flag var sendCopy = false
    @Flag(name: .shortAndLong) var yes = false
    func validate() throws {
        guard values.count >= 3, Int64(values[0]) != nil, Int64(values[1]) != nil else { throw ValidationError("give destination, source and message ids") }
        for value in values.dropFirst(2) { try validateMessageId(value) }
    }
    func run() async throws { try await action("POST", "/v1/chats/\(values[0])/forward", ["from_chat_id": .string(values[1]), "message_ids": .array(values.dropFirst(2).map(JSONValue.string)), "send_copy": .bool(sendCopy)], yes: yes) }
}
struct Vote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Vote: <chat> <message> [option-index …]; no options retracts your vote.")
    @Argument(parsing: .allUnrecognized) var values: [String] = []
    @Flag(name: .shortAndLong) var yes = false
    func validate() throws {
        try validateActionIds(values, count: nil)
        for value in values.dropFirst(2) { guard let id = Int(value), id >= 0 else { throw ValidationError("options must be non-negative integers") } }
    }
    func run() async throws { try await action("POST", "/v1/chats/\(values[0])/messages/\(values[1])/poll", ["option_ids": .array(values.dropFirst(2).compactMap(Double.init).map(JSONValue.number))], yes: yes) }
}
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chat", abstract: "Pin, archive, mute or start a chat.", subcommands: [Pin.self, Archive.self, Mute.self, Start.self])
    struct Options: ParsableArguments {
        @Argument(parsing: .allUnrecognized) var chats: [String] = []
        @Flag(help: "Undo the setting (unpin, unarchive, unmute).") var undo = false
        @Flag(name: .shortAndLong) var yes = false
        func validate() throws { guard chats.count == 1, Int64(chats[0]) != nil else { throw ValidationError("give one chat id") } }
        func run(_ field: String, extra: JSONObjectValue = [:]) async throws {
            var body = extra
            body[field] = .bool(!undo)
            try await action("PATCH", "/v1/chats/\(chats[0])", body, yes: yes)
        }
    }
    struct Pin: AsyncParsableCommand {
        @OptionGroup var options: Options
        func run() async throws { try await options.run("is_pinned") }
    }
    struct Archive: AsyncParsableCommand {
        @OptionGroup var options: Options
        func run() async throws { try await options.run("is_archived") }
    }
    struct Mute: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Option(name: .customLong("for"), help: "Unmute automatically after this long, as mm:ss or hh:mm:ss. Mutes indefinitely if left out.") var duration: String?
        func validate() throws {
            if let value = duration { guard muteSeconds(value) != nil, !options.undo else { throw ValidationError("--for takes mm:ss or hh:mm:ss, and not with --undo") } }
        }
        func run() async throws {
            let until = duration.flatMap(muteSeconds).map { JSONValue.number((Date().timeIntervalSince1970 + Double($0)).rounded()) }
            try await options.run("is_muted", extra: until.map { ["mute_until": $0] } ?? [:])
        }
    }
    struct Start: AsyncParsableCommand {
        @Argument var username: String
        @Flag(help: "Interpret the argument as a phone number.") var phone = false
        @Flag(name: .shortAndLong) var yes = false
        func run() async throws { try await action("POST", "/v1/chats", [phone ? "phone" : "username": .string(username)], yes: yes) }
    }
}
/// "30:00" or "8:00:00" in seconds; nil unless positive and well formed.
func muteSeconds(_ value: String) -> Int? {
    let raw = value.split(separator: ":", omittingEmptySubsequences: false)
    let parts = raw.compactMap { Int($0) }
    guard (2...3).contains(raw.count), parts.count == raw.count, parts.allSatisfy({ $0 >= 0 }), parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
    let seconds = parts.reduce(0) { $0 * 60 + $1 }
    return seconds > 0 ? seconds : nil
}
private func validateMessageId(_ value: String) throws {
    guard let id = Int64(value), id > 0, id <= Int64.max >> 20 else { throw ValidationError("invalid message id") }
}
private func validateActionIds(_ values: [String], count: Int?) throws {
    guard values.count >= 2, count == nil || values.count == count, Int64(values[0]) != nil else { throw ValidationError("give chat, message and action arguments") }
    try validateMessageId(values[1])
}
