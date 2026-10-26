import Foundation

// The words shown on screen. The API speaks in identifiers (`messages:read`, `basic_group`,
// timestamps); the screen uses plain language. Every screen goes through these functions so
// one thing is always called one name. Unit-tested in WordingTests.

/// What a state means to the person looking at it. Colour is derived from this and nothing else:
/// `ok` green, `attention` amber (waiting, or needs the user), `failed` red.
enum Tone: Equatable, Sendable {
    case neutral
    case ok
    case attention
    case failed
}

/// A **scope** (docs/grants.md) in plain words. The identifier appears only as a tooltip.
enum Permission {
    /// Canonical display order, whatever order the API returned.
    static let order = ["messages:read", "history:read", "media:read", "chats:read", "messages:send"]

    /// "New messages"
    static func name(_ scope: String) -> String {
        switch scope {
        case "messages:read": "New messages"
        case "history:read": "Past messages"
        case "media:read": "Photos and files"
        case "chats:read": "Chat names and details"
        case "messages:send": "Send messages"
        default: scope
        }
    }

    /// One line saying what the permission lets an app do.
    static func meaning(_ scope: String) -> String {
        switch scope {
        case "messages:read": "Every message as it arrives, with edits and deletions"
        case "history:read": "Messages from before the app was connected"
        case "media:read": "Download what is attached to those messages"
        case "chats:read": "Titles, usernames and member counts"
        case "messages:send": "Sends messages as you in these chats; people see them as written by you"
        default: "Not known to this version of the app"
        }
    }

    /// The short form for compact rows: "new messages", "chat names".
    static func short(_ scope: String) -> String {
        switch scope {
        case "chats:read": "chat names"
        default: name(scope).lowercasedFirst
        }
    }

    /// The one permission that acts as the user instead of reading. Shown apart, under
    /// "Can send", so it is never mistaken for one more kind of reading.
    static let send = "messages:send"

    /// The reading permissions among `scopes`, in display order.
    static func reading(_ scopes: [String]) -> [String] {
        sorted(scopes.filter { $0 != send })
    }

    static func sorted(_ scopes: [String]) -> [String] {
        scopes.sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
    }

    /// "New messages, past messages, chat names and details"
    static func sentence(_ scopes: [String]) -> String {
        sorted(scopes).map { name($0).lowercasedFirst }.joined(separator: ", ").capitalizedFirst
    }

    /// "new messages, chat names"
    static func summary(_ scopes: [String]) -> String {
        sorted(scopes).map(short).joined(separator: ", ")
    }
}

enum Wording {
    /// "1 chat", "2 chats", "4,812 messages".
    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number.formatted(.number.grouping(.automatic))) \(number == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// How long ago, compactly: "now", "5m ago", "3h ago", "2d ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    /// "up 12m", "up 6h", "up 3d".
    static func uptime(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        return seconds < 60 ? "just started" : "up \(elapsed(since: start, now: now))"
    }

    /// "12m", "6h", "3d"; "under a minute" at first.
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 { return "under a minute" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    /// Time until a request expires: "12 min left", "under a minute left", "expired".
    static func timeLeft(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "expired" }
        if seconds < 60 { return "under a minute left" }
        return "\(Int((seconds / 60).rounded(.up))) min left"
    }

    /// The host of a webhook URL, which is all anyone needs to recognise it.
    static func host(of urlString: String) -> String {
        URLComponents(string: urlString)?.host ?? urlString
    }

    /// "127.0.0.1:41414" — the port is an identifier, never grouped as "41,414".
    static func address(_ url: URL) -> String {
        let host = url.host() ?? "127.0.0.1"
        guard let port = url.port else { return host }
        return "\(host):\(String(port))"
    }

    static func chatKind(_ type: ChatType) -> String {
        switch type {
        case .private: "Person"
        case .basicGroup, .supergroup: "Group"
        case .channel: "Channel"
        case .unknown: "Chat"
        }
    }

    /// The one secondary line under a chat, in a fixed order with missing parts left out:
    /// "Channel · 13K members · @acmeupdates".
    static func chatSubtitle(_ chat: Chat) -> String {
        var parts = [chatKind(chat.type)]
        if let members = chat.memberCount {
            let compact = members.formatted(.number.notation(.compactName))
            parts.append("\(compact) \(members == 1 ? "member" : "members")")
        }
        if let username = chat.username, !username.isEmpty {
            parts.append("@\(username)")
        }
        return parts.joined(separator: " · ")
    }

    /// Where Telegram sent the login code: "Sent to the Telegram app on +1 555 123 4567".
    static func codeDestination(type: String?, phone: String?) -> String? {
        let place: String
        switch type {
        case "telegram_message": place = "Sent to the Telegram app"
        case "sms", "fragment", "firebase": place = "Sent by SMS"
        case "call", "flash_call", "missed_call": place = "Sent by phone call"
        default: place = "Sent"
        }
        if let phone, !phone.isEmpty { return place == "Sent" ? "Sent to \(phone)" : "\(place) on \(phone)" }
        return place == "Sent" ? nil : place
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Grant {
    /// Its delivery stopped or is failing.
    var needsAttention: Bool { webhook?.state == .paused || webhook?.state == .retrying }

    /// The trailing state of an app in a list: quiet when fine, amber when it needs the user.
    var state: (tone: Tone, text: String) {
        if let webhook {
            switch webhook.state {
            case .paused: return (.attention, "Paused")
            case .retrying: return (.attention, "Failing")
            case .active, .unknown:
                if let last = [webhook.lastDeliveryAt, lastSeenAt].compactMap({ $0 }).max() {
                    return (.ok, Wording.ago(last))
                }
                return (.neutral, "Nothing sent yet")
            }
        }
        if let lastSeenAt { return (.ok, Wording.ago(lastSeenAt)) }
        return (.neutral, "Not connected yet")
    }

    /// "2 chats · new messages, chat names", "Product folder · …", or "1 chat · 4 permissions"
    /// once naming them would wrap the row. The detail lists them in full.
    var summary: String {
        let place = chats.isFolder
            ? "\(chats.folderTitle ?? "A") folder"
            : Wording.count(chats.chatIds?.count ?? 0, "chat")
        let permissions = scopes.count <= 2 ? Permission.summary(scopes) : Wording.count(scopes.count, "permission")
        return "\(place) · \(permissions)"
    }
}
