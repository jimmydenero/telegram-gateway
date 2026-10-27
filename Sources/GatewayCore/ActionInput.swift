import Foundation
import TDLibClient

/// Validates the gateway action vocabulary before constructing TDLib requests.
public enum ActionInput {
    public static let maxMediaBytes = 20 * 1024 * 1024
    public static let maxUploadBodyBytes = ((maxMediaBytes + 2) / 3) * 4 + 64 * 1024

    static func string(_ body: JSONObjectValue, _ key: String) throws -> String {
        guard let s = body[key]?.stringValue else { throw APIError.invalidRequest(key, "must be a string") }
        return s
    }
    static func bool(_ body: JSONObjectValue, _ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = body[key] else { return fallback }
        guard case .bool(let b) = value else { throw APIError.invalidRequest(key, "must be a boolean") }
        return b
    }
    static func optionalId(_ body: JSONObjectValue, _ key: String, message: Bool = false) throws -> Int64? {
        guard body[key] != nil else { return nil }
        guard let raw = body[key]?.stringValue, let id = Int64(raw), id != 0,
              !message || (id > 0 && id <= Int64.max >> 20) else {
            throw APIError.invalidRequest(key, "must be a valid id string")
        }
        return id
    }
    static func id(_ body: JSONObjectValue, _ key: String, message: Bool = false) throws -> Int64 {
        guard let id = try optionalId(body, key, message: message) else { throw APIError.invalidRequest(key, "required") }
        return id
    }
    static func ids(_ body: JSONObjectValue) throws -> [Int64] {
        guard let array = body["message_ids"]?.arrayValue, !array.isEmpty, array.count <= 100 else {
            throw APIError.invalidRequest("message_ids", "must contain 1 to 100 id strings")
        }
        let ids = try array.map { try id(["id": $0], "id", message: true) }
        guard Set(ids).count == ids.count else { throw APIError.invalidRequest("message_ids", "duplicates") }
        return ids.sorted().map(MessageId.toInternal)
    }
    static func integer(_ value: JSONValue?, field: String, max: Int = Int(Int32.max)) throws -> Int {
        guard case .number(let n) = value, n.isFinite, n >= 0, n <= Double(max), n.rounded() == n else {
            throw APIError.invalidRequest(field, "must be a non-negative integer")
        }
        return Int(n)
    }
    static func formatted(_ text: String, entities: JSONValue?, limit: Int) throws -> JSONObject {
        guard text.utf16.count <= limit else { throw APIError.invalidRequest("text", "too_long") }
        let names = ["mention": "Mention", "text_mention": "MentionName", "hashtag": "Hashtag", "cashtag": "Cashtag", "url": "Url", "text_link": "TextUrl", "bot_command": "BotCommand", "email": "EmailAddress", "bold": "Bold", "italic": "Italic", "underline": "Underline", "strikethrough": "Strikethrough", "spoiler": "Spoiler", "code": "Code", "pre": "Pre", "blockquote": "BlockQuote", "custom_emoji": "CustomEmoji"]
        var result: [JSONObject] = []
        if let entities {
            guard let array = entities.arrayValue, array.count <= 100 else { throw APIError.invalidRequest("entities", "must be an array of at most 100 entities") }
            for item in array {
                guard let entity = item.objectValue, let type = entity["type"]?.stringValue, let name = names[type] else { throw APIError.invalidRequest("entities", "unknown entity type") }
                let offset = try integer(entity["offset"], field: "offset", max: text.utf16.count)
                let length = try integer(entity["length"], field: "length", max: text.utf16.count)
                guard length > 0, offset + length <= text.utf16.count else { throw APIError.invalidRequest("entities", "span outside text") }
                let units = Array(text.utf16)
                for boundary in [offset, offset + length] where boundary > 0 && boundary < units.count {
                    guard !(0xDC00...0xDFFF).contains(units[boundary]) else { throw APIError.invalidRequest("entities", "span splits a surrogate pair") }
                }
                var td: JSONObject = ["@type": "textEntityType" + name]
                if type == "text_link" { td["url"] = try string(entity, "url") }
                if type == "text_mention" { td["user_id"] = try id(entity, "user_id") }
                if type == "custom_emoji" { td["custom_emoji_id"] = try id(entity, "custom_emoji_id") }
                if type == "pre", let language = entity["language"], language != .null { td = ["@type": "textEntityTypePreCode", "language": try string(entity, "language")] }
                result.append(["@type": "textEntity", "offset": offset, "length": length, "type": td])
            }
        }
        return ["@type": "formattedText", "text": text, "entities": result]
    }
}

struct SendInput {
    var content: JSONObject
    var data: Data?
    var fileName = ""
    var fileField = ""
    let silent: Bool

    init(_ body: JSONObjectValue) throws {
        silent = try ActionInput.bool(body, "silent")
        if let raw = body["media"] {
            guard let media = raw.objectValue else { throw APIError.invalidRequest("media", "must be an object") }
            let kind = try ActionInput.string(media, "kind")
            let types = ["photo": "Photo", "video": "Video", "document": "Document", "voice": "VoiceNote", "audio": "Audio", "animation": "Animation", "sticker": "Sticker"]
            guard let suffix = types[kind] else { throw APIError.invalidRequest("media.kind", "unsupported kind") }
            fileField = kind == "voice" ? "voice_note" : kind
            let name = try ActionInput.string(media, "file_name")
            guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240, !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw APIError.invalidRequest("file_name", "must be a basename") }
            fileName = name
            let mime = try ActionInput.string(media, "mime_type")
            if kind == "voice", !["audio/ogg", "audio/opus", "application/ogg"].contains(mime) { throw APIError.invalidRequest("mime_type", "voice must be Ogg/Opus") }
            let base64 = try ActionInput.string(media, "data_base64")
            guard base64.utf8.count <= ((ActionInput.maxMediaBytes + 2) / 3) * 4 else { throw APIError.payloadTooLarge }
            guard let decoded = Data(base64Encoded: base64), !decoded.isEmpty else { throw APIError.invalidRequest("data_base64", "must be non-empty base64") }
            guard decoded.count <= ActionInput.maxMediaBytes else { throw APIError.payloadTooLarge }
            data = decoded
            if body["text"] != nil && media["caption"] != nil { throw APIError.invalidRequest("text", "use either text or media.caption") }
            let caption = try media["caption"].map { _ in try ActionInput.string(media, "caption") } ?? body["text"].map { _ in try ActionInput.string(body, "text") } ?? ""
            if kind == "sticker", !caption.isEmpty { throw APIError.invalidRequest("caption", "stickers cannot have captions") }
            var nested: JSONObject = ["@type": "input" + suffix]
            // Only the metadata fields the pinned schema has for this kind.
            let metadata = ["photo": ["width", "height"], "video": ["duration", "width", "height"], "animation": ["duration", "width", "height"], "audio": ["duration"], "voice": ["duration"], "sticker": ["width", "height"]][kind] ?? []
            for field in ["duration", "width", "height"] where media[field] != nil {
                guard metadata.contains(field) else { throw APIError.invalidRequest("media.\(field)", "not used for \(kind)") }
                nested[field] = try ActionInput.integer(media[field], field: field)
            }
            if let waveform = media["waveform"] {
                guard kind == "voice" else { throw APIError.invalidRequest("media.waveform", "only for voice") }
                guard let value = waveform.stringValue, let bytes = Data(base64Encoded: value), bytes.count <= 1024 else { throw APIError.invalidRequest("waveform", "must be base64 bytes (at most 1024)") }
                nested["waveform"] = value
            }
            content = ["@type": "inputMessage" + suffix, fileField: nested]
            if kind != "sticker" { content["caption"] = try ActionInput.formatted(caption, entities: body["entities"], limit: 1024) }
        } else {
            let text = try ActionInput.string(body, "text")
            try MessageSender.validate(text: text)
            content = ["@type": "inputMessageText", "text": try ActionInput.formatted(text, entities: body["entities"], limit: MessageSender.maxTextLength), "clear_draft": false]
        }
    }
}
