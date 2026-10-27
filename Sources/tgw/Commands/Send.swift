import ArgumentParser
import Foundation
import GatewayCore
import UniformTypeIdentifiers

/// `tgw send`: the owner sends a message through the running gateway, with the admin token
/// (`POST /v1/chats/{chat_id}/messages`). Only to monitored chats; asks first unless `--yes`.
struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send text or a file as yourself to a monitored chat, through the running gateway.",
        discussion: """
            The message goes out from your Telegram account, like one typed on your phone. \
            The chat must be monitored. Shows the chat and the text and asks before sending, \
            unless --yes is given.
            """
    )

    // Collected as unrecognized words so that a group's or channel's negative chat id
    // (-100…) is read as the chat, not as an option.
    @Argument(parsing: .allUnrecognized, help: ArgumentHelp(
        "The chat id, as listed by `tgw monitor`, then the text to send (plain text, up to 4096 characters; quote it).",
        valueName: "chat> <text"))
    var chatAndText: [String] = []

    var chat: String { chatAndText.first ?? "" }
    var text: String { chatAndText.dropFirst().first ?? "" }

    @Option(name: .customLong("reply-to"), help: "The id of a message in the same chat to reply to.")
    var replyTo: String?

    @Flag(name: .shortAndLong, help: "Send without asking for confirmation.")
    var yes = false

    @Option(help: "Send this file, at most 20 MiB. The text, if given, becomes its caption.") var file: String?
    @Option(help: "How Telegram shows the file: photo, video, document, voice, audio, animation or sticker.") var kind = "document"
    @Option(help: "The file's MIME type. Guessed from the file name if left out.") var mimeType: String?
    @Flag(help: "Send without a notification sound.") var silent = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard chatAndText.count == 2 || (file != nil && chatAndText.count == 1) else { throw ValidationError("give the chat id and the text, with the text in quotes") }
        guard Int64(chat) != nil else { throw ValidationError("the chat must be a chat id, for example -1001234567890") }
        if let replyTo, (Int64(replyTo) ?? 0) <= 0 { throw ValidationError("--reply-to must be a message id") }
        guard ["photo", "video", "document", "voice", "audio", "animation", "sticker"].contains(kind) else { throw ValidationError("--kind must be photo, video, document, voice, audio, animation or sticker") }
        do {
            if file == nil { try MessageSender.validate(text: text) }
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
            if let file { print("File    \(file) (\(kind))") }
            let answer = try Prompt.line("Send this message? [y/N] ")
            guard ["y", "yes"].contains(answer.lowercased()) else {
                print("not sent")
                return
            }
        }
        var body: JSONObjectValue = ["text": .string(text)]
        body["silent"] = .bool(silent)
        if let file {
            let url = URL(fileURLWithPath: file)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ActionInput.maxMediaBytes else { throw CLIError("file exceeds 20 MiB") }
            let data = try Data(contentsOf: url)
            let mime = mimeType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            body["media"] = .object(["kind": .string(kind), "data_base64": .string(data.base64EncodedString()), "file_name": .string(url.lastPathComponent), "mime_type": .string(mime)])
        }
        if let replyTo { body["reply_to"] = .string(replyTo) }
        let reply = try Admin.check(try await client.post("/v1/chats/\(chat)/messages", .object(body)))
        if output.json { print(reply.pretty()); return }
        let message = reply["message"]
        print("sent: message \(message?["id"]?.stringValue ?? "?") in chat \(chat)\(message?["link"]?.stringValue.map { "  \($0)" } ?? "")")
    }
}
