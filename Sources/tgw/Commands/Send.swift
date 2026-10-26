import ArgumentParser
import Foundation
import GatewayCore

/// `tgw send`: the owner sends a message through the running gateway, with the admin token
/// (`POST /v1/chats/{chat_id}/messages`). Only to monitored chats; asks first unless `--yes`.
struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a text message as yourself to a monitored chat, through the running gateway.",
        discussion: """
            The message goes out from your Telegram account, like one typed on your phone. \
            The chat must be monitored. Shows the chat and the text and asks before sending, \
            unless --yes is given.
            """
    )

    @Argument(help: "The chat id, as listed by `tgw monitor`.")
    var chat: String

    @Argument(help: "The text to send (plain text, up to 4096 characters).")
    var text: String

    @Option(name: .customLong("reply-to"), help: "The id of a message in the same chat to reply to.")
    var replyTo: String?

    @Flag(name: .shortAndLong, help: "Send without asking for confirmation.")
    var yes = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard Int64(chat) != nil else { throw ValidationError("the chat must be a chat id, for example -1001234567890") }
        if let replyTo, (Int64(replyTo) ?? 0) <= 0 { throw ValidationError("--reply-to must be a message id") }
        do {
            try MessageSender.validate(text: text)
        } catch let error as APIError {
            throw ValidationError(error.details["reason"] == "too_long" ? "the text is longer than \(MessageSender.maxTextLength) characters" : "the text is empty")
        }
    }

    func run() async throws {
        let client = try Admin.client()
        if !yes {
            let monitored = try Admin.check(try await client.get("/v1/admin/chats"))
            let title = (monitored["chats"]?.arrayValue ?? []).first { $0["id"]?.stringValue == chat }?["title"]?.stringValue
            guard let title else { throw CLIError("chat \(chat) is not monitored; the gateway sends only to monitored chats (`tgw monitor add`)") }
            let account = try? Admin.check(try await client.get("/v1/admin/status"))["account"]?["display_name"]?.stringValue
            print("To      \(title) (\(chat))")
            if let replyTo { print("Reply   to message \(replyTo)") }
            print("From    \(account.map { "\($0), your Telegram account" } ?? "your Telegram account")")
            print("Text    \(text)")
            let answer = try Prompt.line("Send this message? [y/N] ")
            guard ["y", "yes"].contains(answer.lowercased()) else {
                print("not sent")
                return
            }
        }
        var body: JSONObjectValue = ["text": .string(text)]
        if let replyTo { body["reply_to"] = .string(replyTo) }
        let reply = try Admin.check(try await client.post("/v1/chats/\(chat)/messages", .object(body)))
        if output.json { print(reply.pretty()); return }
        let message = reply["message"]
        print("sent: message \(message?["id"]?.stringValue ?? "?") in chat \(chat)\(message?["link"]?.stringValue.map { "  \($0)" } ?? "")")
    }
}
