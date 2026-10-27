import Foundation
import Testing
@testable import TelegramGateway

/// The one mapping from API identifiers to the words shown on screen.
@Suite("Wording")
struct WordingTests {
    @Test("Permissions in plain words")
    func permissionNames() {
        #expect(Permission.name("messages:read") == "New messages")
        #expect(Permission.name("history:read") == "Past messages")
        #expect(Permission.name("media:read") == "Photos and files")
        #expect(Permission.name("chats:read") == "Chat names and details")
        #expect(Permission.name("messages:send") == "Send and react")
        #expect(Permission.name("chats:manage") == "Manage chats")
        #expect(Permission.meaning("messages:send").contains("as you"))
        #expect(Permission.reading(["messages:send", "chats:manage", "chats:read", "messages:read"]) == ["messages:read", "chats:read"])
        // A scope this version does not know is shown as it is rather than hidden.
        #expect(Permission.name("reactions:read") == "reactions:read")
        for scope in Permission.order {
            #expect(!Permission.meaning(scope).isEmpty)
            #expect(!Permission.meaning(scope).contains(":"))
        }
    }

    @Test("Permission lists: sentence and compact summary, in a fixed order")
    func permissionLists() {
        let scopes = ["chats:read", "messages:read", "history:read"]
        #expect(Permission.sorted(scopes) == ["messages:read", "history:read", "chats:read"])
        #expect(Permission.sentence(scopes) == "New messages, past messages, chat names and details")
        #expect(Permission.summary(["chats:read", "messages:read"]) == "new messages, chat names")
        #expect(Permission.summary(["messages:read", "history:read", "media:read", "chats:read"]) == "new messages, past messages, photos and files, chat names")
        #expect(Permission.sentence([]) == "")
        #expect(Permission.sorted(["zzz:read", "messages:read"]) == ["messages:read", "zzz:read"])
    }

    @Test("Counts are grouped and pluralised")
    func counts() {
        #expect(Wording.count(1, "chat") == "1 chat")
        #expect(Wording.count(2, "chat") == "2 chats")
        #expect(Wording.count(0, "message") == "0 messages")
        #expect(Wording.count(4812, "message") == "4,812 messages")
    }

    @Test("The address never groups the port")
    func address() {
        #expect(Wording.address(URL(string: "http://127.0.0.1:41414")!) == "127.0.0.1:41414")
        #expect(!Wording.address(GatewayConfig().baseURL).contains(","))
    }

    @Test("Relative times")
    func relativeTimes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(Wording.ago(now.addingTimeInterval(-20), now: now) == "now")
        #expect(Wording.ago(now.addingTimeInterval(-90), now: now) == "1m ago")
        #expect(Wording.ago(now.addingTimeInterval(-3 * 3600 - 5), now: now) == "3h ago")
        #expect(Wording.ago(now.addingTimeInterval(-2 * 86400 - 5), now: now) == "2d ago")
        #expect(Wording.ago(now.addingTimeInterval(60), now: now) == "now")
        #expect(Wording.uptime(since: now.addingTimeInterval(-30), now: now) == "just started")
        #expect(Wording.uptime(since: now.addingTimeInterval(-12 * 60), now: now) == "up 12m")
        #expect(Wording.uptime(since: now.addingTimeInterval(-6 * 3600 - 60), now: now) == "up 6h")
        #expect(Wording.uptime(since: now.addingTimeInterval(-3 * 86400 - 60), now: now) == "up 3d")
        #expect(Wording.elapsed(since: now.addingTimeInterval(-6 * 3600 - 60), now: now) == "6h")
        #expect(Wording.elapsed(since: now.addingTimeInterval(-10), now: now) == "under a minute")
        #expect(Wording.timeLeft(until: now.addingTimeInterval(12 * 60 - 10), now: now) == "12 min left")
        #expect(Wording.timeLeft(until: now.addingTimeInterval(15 * 60), now: now) == "15 min left")
        #expect(Wording.timeLeft(until: now.addingTimeInterval(40), now: now) == "under a minute left")
        #expect(Wording.timeLeft(until: now.addingTimeInterval(-1), now: now) == "expired")
    }

    @Test("A webhook is named by its host")
    func host() {
        #expect(Wording.host(of: "https://analytics.example.com/tgw/events") == "analytics.example.com")
        #expect(Wording.host(of: "http://127.0.0.1:8080/hook") == "127.0.0.1")
        #expect(Wording.host(of: "not a url") == "not a url")
    }

    @Test("Chat subtitle: kind, members, handle, in that order, missing parts left out")
    func chatSubtitle() {
        let channel = Chat(id: "-1001", type: .channel, title: "Acme", username: "acmeupdates", memberCount: 12840, isMonitored: false, photo: nil)
        #expect(Wording.chatSubtitle(channel) == "Channel · 13K members · @acmeupdates")
        let group = Chat(id: "-2", type: .basicGroup, title: "Family", username: nil, memberCount: 6, isMonitored: false, photo: nil)
        #expect(Wording.chatSubtitle(group) == "Group · 6 members")
        let person = Chat(id: "3", type: .private, title: "Alice", username: "alice", memberCount: nil, isMonitored: false, photo: nil)
        #expect(Wording.chatSubtitle(person) == "Person · @alice")
        let bare = Chat(id: "4", type: .supergroup, title: "X", username: nil, memberCount: nil, isMonitored: false, photo: nil)
        #expect(Wording.chatSubtitle(bare) == "Group")
        let one = Chat(id: "5", type: .channel, title: "Solo", username: nil, memberCount: 1, isMonitored: false, photo: nil)
        #expect(Wording.chatSubtitle(one) == "Channel · 1 member")
    }

    @Test("Where the login code went")
    func codeDestination() {
        #expect(Wording.codeDestination(type: "telegram_message", phone: "+1 ••• 42") == "Sent to the Telegram app on +1 ••• 42")
        #expect(Wording.codeDestination(type: "sms", phone: nil) == "Sent by SMS")
        #expect(Wording.codeDestination(type: "call", phone: "+15551234567") == "Sent by phone call on +15551234567")
        #expect(Wording.codeDestination(type: nil, phone: "+15551234567") == "Sent to +15551234567")
        #expect(Wording.codeDestination(type: nil, phone: nil) == nil)
    }

    @Test("Telegram's error codes in plain words")
    @MainActor
    func loginMessages() {
        func message(_ text: String, reason: String? = nil) -> String {
            AppModel.loginMessage(for: APIError(code: "invalid_request", message: text, details: reason.map { ["reason": .string($0)] }))
        }
        #expect(message("x", reason: "wrong_password") == "That password isn't right.")
        #expect(message("x", reason: "wrong_code") == "That code isn't right.")
        #expect(message("qr: API_ID_INVALID").contains("API ID"))
        #expect(!message("qr: API_ID_INVALID").contains("API_ID_INVALID"))
        #expect(message("Something else") == "Something else")
    }
}
