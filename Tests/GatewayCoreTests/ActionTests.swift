import Foundation
import GatewayCore
import GatewayTestSupport
import TDLibClient
import Testing

@Suite struct ActionTests {
    struct Setup {
        let core: Core
        let sender: MessageSender
        let telegram: FakeTelegram
        let directory: URL
        init() async throws {
            core = try await Core()
            try await core.monitorDefaults()
            await ActionFixtures.install(core.tdlib)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("tgw-actions-" + UUID().uuidString)
            telegram = FakeTelegram(state: .ready, tdlib: core.tdlib)
            sender = MessageSender(grants: core.grants, translator: core.translator, telegram: telegram, rateLimiter: RateLimiter(clock: core.clock), clock: core.clock, uploadDirectory: directory)
        }
        func run(_ name: String, as principal: Principal = .admin) async throws {
            switch name {
            case "forward": _ = try await sender.forward(["from_chat_id": .id(Fixtures.channelId), "message_ids": ["1530"]], to: Fixtures.channelId, as: principal)
            case "edit": _ = try await sender.edit(["text": "edited", "entities": [["type": "bold", "offset": 0, "length": 6]]], chat: Fixtures.channelId, message: 1530, as: principal)
            case "delete": try await sender.delete(["message_ids": ["1530"], "for_everyone": true], chat: Fixtures.channelId, as: principal)
            case "react": try await sender.react(["emoji": "👍", "big": true], chat: Fixtures.channelId, message: 1530, as: principal)
            case "unreact": try await sender.react(["custom_emoji_id": "123"], chat: Fixtures.channelId, message: 1530, remove: true, as: principal)
            case "vote": try await sender.vote(["option_ids": [0, 2]], chat: Fixtures.channelId, message: 1530, as: principal)
            case "retract": try await sender.vote(["option_ids": []], chat: Fixtures.channelId, message: 1530, as: principal)
            case "pin": _ = try await sender.settings(["is_pinned": true], chat: Fixtures.channelId, as: principal)
            case "archive": _ = try await sender.settings(["is_archived": true], chat: Fixtures.channelId, as: principal)
            case "mute": _ = try await sender.settings(["is_muted": true, "mute_until": .number(core.clock.now.timeIntervalSince1970 + 300)], chat: Fixtures.channelId, as: principal)
            default: _ = try await sender.startChat(["username": "acmeupdates"], as: principal, store: core.store, monitor: core.monitor)
            }
        }
    }

    @Test(arguments: ["forward", "edit", "delete", "react", "unreact", "vote", "retract", "pin", "archive", "mute", "start"])
    func requestsAndSafety(_ name: String) async throws {
        let s = try await Setup()
        try await s.run(name)
        let types = ["forward": "forwardMessages", "edit": "editMessageText", "delete": "deleteMessages", "react": "addMessageReaction", "unreact": "removeMessageReaction", "vote": "setPollAnswer", "retract": "setPollAnswer", "pin": "toggleChatIsPinned", "archive": "addChatToList", "mute": "setChatNotificationSettings", "start": "searchPublicChat"]
        let request = try #require(await s.core.tdlib.requests(ofType: types[name] ?? "").last?.object)
        if ["edit", "react", "unreact", "vote", "retract"].contains(name) { #expect(request.int64("message_id") == MessageId.toInternal(1530)) }
        if name == "forward" { #expect(request.int64("from_chat_id") == Fixtures.channelId) }
        if name == "delete" { #expect(request.bool("revoke") == true) }
        if name == "react" { #expect(request.object("reaction_type")?.string("emoji") == "👍"); #expect(request.bool("is_big") == true) }
        if name == "unreact" { #expect(request.object("reaction_type")?.int64("custom_emoji_id") == 123) }
        if name == "retract" { #expect(request.array("option_ids")?.isEmpty == true) }
        if name == "pin" { #expect(request.object("chat_list")?.type == "chatListMain") }
        if name == "archive" { #expect(request.object("chat_list")?.type == "chatListArchive") }
        if name == "mute" { #expect(request.object("notification_settings")?.int("mute_for") == 300) }
        let forbidden = Set(["openChat", "viewMessages", "readAllChatMentions", "sendChatAction"])
        #expect(await s.core.tdlib.requests.allSatisfy { !forbidden.contains($0.object.type ?? "") })
    }

    @Test(arguments: ["forward", "edit", "delete", "react", "unreact", "vote", "pin", "archive", "mute", "start"])
    func requiresScopeAndFreshGrant(_ name: String) async throws {
        let s = try await Setup()
        let (reader, _) = try await s.core.makeGrant()
        #expect(await apiError { try await s.run(name, as: .app(reader)) }?.code == "insufficient_scope")
        let (writer, _) = try await s.core.makeGrant(scopes: [.messagesSend, .chatsManage])
        try await s.core.grants.revoke(writer.id)
        #expect(await apiError { try await s.run(name, as: .app(writer)) }?.code == "token_revoked")
    }

    @Test func forwardChecksBothChats() async throws {
        let s = try await Setup()
        let (grant, _) = try await s.core.makeGrant(scopes: [.messagesSend])
        #expect(await apiError { try await s.sender.forward(["from_chat_id": .id(Fixtures.groupId), "message_ids": ["1530"]], to: Fixtures.channelId, as: .app(grant)) }?.code == "chat_not_granted")
        #expect(await s.core.tdlib.requests(ofType: "forwardMessages").isEmpty)
    }

    @Test func ownershipAndDeletionPermissions() async throws {
        let s = try await Setup()
        await s.core.tdlib.on("getMessage") { _ in var message = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "other").object; message["is_outgoing"] = false; return message }
        #expect(await apiError { try await s.run("edit") }?.code == "invalid_request")
        #expect(await apiError { try await s.run("delete") }?.code == "invalid_request")
        await ActionFixtures.install(s.core.tdlib)
        await s.core.tdlib.on("getMessage") { _ in Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "own").object }
        await s.core.tdlib.on("getMessageProperties") { _ in ["@type": "messageProperties", "can_be_deleted_for_all_users": false] }
        #expect(await apiError { try await s.run("delete") }?.code == "invalid_request")
        #expect(await s.core.tdlib.requests(ofType: "deleteMessages").isEmpty)
    }

    @Test func mediaEditUsesCaption() async throws {
        let s = try await Setup()
        await s.core.tdlib.on("getMessage") { _ in var message = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "own").object; message["content"] = ["@type": "messagePhoto"]; return message }
        try await s.run("edit")
        let request = try #require(await s.core.tdlib.requests(ofType: "editMessageCaption").first?.object)
        #expect(request.object("caption")?.string("text") == "edited")
    }

    @Test(arguments: ["photo", "video", "document", "voice", "audio", "animation", "sticker"])
    func mediaUsesPinnedSchemaAndCleansUp(_ kind: String) async throws {
        let s = try await Setup()
        defer { try? FileManager.default.removeItem(at: s.directory) }
        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "uploaded")
        await s.core.tdlib.on("sendMessage") { request in
            let field = kind == "voice" ? "voice_note" : kind
            let content = try #require(request.object("input_message_content"))
            let nested = try #require(content.object(field))
            let file = try #require(nested.object(field))
            #expect(file.type == "inputFileLocal")
            let path = try #require(file.string("path"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("fixture".utf8))
            #expect(path.hasPrefix(s.directory.path))
            #expect(request.object("options")?.bool("disable_notification") == true)
            return final.object
        }
        var media: JSONObjectValue = ["kind": .string(kind), "file_name": "fixture.ogg", "mime_type": "audio/ogg", "data_base64": .string(Data("fixture".utf8).base64EncodedString())]
        if kind == "voice" { media["duration"] = 3; media["waveform"] = "AQI=" }
        let result = try await s.sender.send(["silent": true, "media": .object(media)], to: Fixtures.channelId, as: .admin)
        #expect(result.id == 1530)
        if kind == "voice" {
            let note = try #require(await s.core.tdlib.requests(ofType: "sendMessage").last?.object.object("input_message_content")?.object("voice_note"))
            #expect(note.int("duration") == 3)
            #expect(note.string("waveform") == "AQI=")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).isEmpty)
    }

    @Test func invalidInputNeverMutates() async throws {
        let s = try await Setup()
        for body in ([["emoji": "👍", "custom_emoji_id": "1"], [:], ["emoji": "👍", "big": "yes"]] as [JSONObjectValue]) {
            #expect(await apiError { try await s.sender.react(body, chat: Fixtures.channelId, message: 1530, as: .admin) }?.code == "invalid_request")
        }
        #expect(await apiError { try await s.sender.vote(["option_ids": [-1]], chat: Fixtures.channelId, message: 1530, as: .admin) }?.code == "invalid_request")
        #expect(await apiError { try await s.sender.send(["text": "😀", "entities": [["type": "bold", "offset": 1, "length": 1]]], to: Fixtures.channelId, as: .admin) }?.code == "invalid_request")
        #expect(await s.core.tdlib.requests(ofType: "sendMessage").isEmpty)
    }

    @Test func entitiesBecomeTDLibEntities() async throws {
        let s = try await Setup()
        await s.core.tdlib.on("sendMessage") { _ in Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "code let").object }
        let entities: JSONValue = [["type": "pre", "offset": 0, "length": 4, "language": .null], ["type": "pre", "offset": 5, "length": 3, "language": "swift"], ["type": "text_link", "offset": 0, "length": 4, "url": "https://example.com"]]
        _ = try await s.sender.send(["text": "code let", "entities": entities, "silent": false], to: Fixtures.channelId, as: .admin)
        let sent = try #require(await s.core.tdlib.requests(ofType: "sendMessage").last?.object.object("input_message_content")?.object("text")?.array("entities") as? [JSONObject])
        #expect(sent.compactMap { $0.object("type")?.type } == ["textEntityTypePre", "textEntityTypePreCode", "textEntityTypeTextUrl"])
        #expect(sent[1].object("type")?.string("language") == "swift")
    }

    @Test func mediaMetadataMustFitTheKind() async throws {
        let s = try await Setup()
        for (kind, field, value) in [("document", "duration", JSONValue.number(3)), ("photo", "waveform", "AQI="), ("audio", "width", 10)] {
            let media: JSONObjectValue = ["kind": .string(kind), "file_name": "a.bin", "mime_type": "application/octet-stream", "data_base64": "YQ==", field: value]
            #expect(await apiError { try await s.sender.send(["media": .object(media)], to: Fixtures.channelId, as: .admin) }?.code == "invalid_request")
        }
        #expect(await s.core.tdlib.requests(ofType: "sendMessage").isEmpty)
    }

    @Test func invalidSendDoesNotSpendTheRateLimit() async throws {
        let s = try await Setup()
        for _ in 0..<(MessageSender.sendsPerMinute + 5) {
            #expect(await apiError { try await s.sender.send(["text": "  "], to: Fixtures.channelId, as: .admin) }?.code == "invalid_request")
        }
        try await s.run("react")
    }

    @Test func staleUploadsAreSweptAndRecentOnesKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tgw-sweep-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), recent = root.appendingPathComponent("recent")
        for directory in [old, recent] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86400)], ofItemAtPath: old.path)
        MessageSender.removeStaleUploads(in: root, olderThan: Date(timeIntervalSinceNow: -86400))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["recent"])
        MessageSender.removeStaleUploads(in: root.appendingPathComponent("missing"), olderThan: Date())
    }

    @Test func actionsShareRateLimitAndMapFloodWait() async throws {
        let s = try await Setup()
        for _ in 0..<20 { try await s.run("react") }
        #expect(await apiError { try await s.run("vote") }?.code == "rate_limited")
        s.core.clock.advance(by: .seconds(61))
        await s.core.tdlib.on("setPollAnswer") { _ in throw TDLibError(code: 429, message: "Too Many Requests: retry after 7") }
        #expect(await apiError { try await s.run("vote") }?.code == "rate_limited")
    }
}

@Suite struct ActionLifecycleTests {
    @Test func timeoutRetainsUploadUntilLateVerdict() async throws {
        let s = try await ActionTests.Setup()
        defer { try? FileManager.default.removeItem(at: s.directory) }
        let task = Task { try await s.sender.send(["media": ["kind": "document", "file_name": "test.txt", "mime_type": "text/plain", "data_base64": "YQ=="]], to: Fixtures.channelId, as: .admin) }
        try await s.core.clock.waitForSleepers(1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).count == 1)
        s.core.clock.advance(by: .seconds(31))
        #expect(await apiError { try await task.value }?.code == "send_timeout")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).count == 1)
        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "file")
        await s.sender.observe(Fixtures.updateMessageSendSucceeded(final, oldMessageId: Fixtures.localMessageId(1)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).isEmpty)
    }

    @Test func failedUploadCleansUpAndRejectsTraversal() async throws {
        let s = try await ActionTests.Setup()
        defer { try? FileManager.default.removeItem(at: s.directory) }
        await s.core.tdlib.on("sendMessage") { _ in throw TDLibError(code: 400, message: "FILE_INVALID") }
        let body: JSONObjectValue = ["media": ["kind": "document", "file_name": "test.txt", "mime_type": "text/plain", "data_base64": "YQ=="]]
        #expect(await apiError { try await s.sender.send(body, to: Fixtures.channelId, as: .admin) }?.code == "send_failed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.directory.path).isEmpty)
        for name in ["../secret", "/secret", "..", "a\\b"] {
            #expect(await apiError { try await s.sender.send(["media": ["kind": "document", "file_name": .string(name), "mime_type": "text/plain", "data_base64": "YQ=="]], to: Fixtures.channelId, as: .admin) }?.code == "invalid_request")
        }
        #expect(await s.core.tdlib.requests(ofType: "sendMessage").count == 1)
    }

    @Test func allActionsRequireLiveSession() async throws {
        let s = try await ActionTests.Setup()
        await s.telegram.set(state: .waitPhoneNumber)
        for name in ["forward", "edit", "delete", "react", "vote", "pin", "archive", "mute", "start"] {
            #expect(await apiError { try await s.run(name) }?.code == "not_logged_in")
        }
        await s.telegram.set(state: .ready)
        await s.telegram.set(connection: .waitingForNetwork)
        #expect(await apiError { try await s.run("react") }?.code == "telegram_unavailable")
    }

    @Test func updatesProduceOneEventPerChangeAndNoSyntheticEvents() async throws {
        let s = try await ActionTests.Setup()
        let before = try await s.core.eventLog.headSeq()
        for name in ["edit", "delete", "react", "vote"] { try await s.run(name) }
        #expect(try await s.core.eventLog.headSeq() == before)
        var edited = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1530, text: "edited").object
        edited["edit_date"] = 1790000000
        await s.core.tdlib.add(message: JSONBox(edited))
        let updates = [
            Fixtures.updateMessageEdited(chatId: Fixtures.channelId, id: 1530, editDate: 1790000000),
            Fixtures.updateMessageContent(chatId: Fixtures.channelId, id: 1530, content: Fixtures.textContent("edited")),
            Fixtures.updateMessageInteractionInfo(chatId: Fixtures.channelId, id: 1530, info: Fixtures.interactionInfo(reactions: [("👍", nil, 1, true)])),
            Fixtures.updateMessageContent(chatId: Fixtures.channelId, id: 1531, content: Fixtures.pollContent(question: "Which?", options: [("A", 1, true)])),
            Fixtures.updateDeleteMessages(chatId: Fixtures.channelId, ids: [1530], permanent: true, fromCache: false),
        ]
        for update in updates { await s.core.monitor.handle(update: update); await s.core.monitor.handle(update: update) }
        let events = try await s.core.eventLog.page(since: before, limit: 100).events
        #expect(events.filter { $0.type == .messageEdited }.count == 1)
        #expect(events.filter { $0.type == .messageDeleted }.count == 1)
        #expect(events.filter { $0.type == .messageReactions }.count == 1)
        #expect(events.filter { $0.type == .pollUpdated }.count == 1)
    }

    @Test func pendingForwardWaitsForFinalIdAndAppearsOnce() async throws {
        let s = try await ActionTests.Setup()
        let pending = Fixtures.pendingMessage(chatId: Fixtures.channelId, localId: Fixtures.localMessageId(1), text: "forwarded")
        await s.core.tdlib.on("forwardMessages") { _ in ["@type": "messages", "total_count": 1, "messages": [pending.object]] }
        let task = Task { try await s.sender.forward(["from_chat_id": .id(Fixtures.channelId), "message_ids": ["10"], "send_copy": true], to: Fixtures.channelId, as: .admin) }
        try await s.core.clock.waitForSleepers(1)
        let final = Fixtures.sentMessage(chatId: Fixtures.channelId, id: 1600, text: "forwarded")
        let update = Fixtures.updateMessageSendSucceeded(final, oldMessageId: Fixtures.localMessageId(1))
        let before = try await s.core.eventLog.headSeq()
        await s.core.monitor.handle(update: Fixtures.updateNewMessage(pending))
        await s.core.monitor.handle(update: update)
        await s.core.monitor.handle(update: Fixtures.updateNewMessage(final))
        await s.sender.observe(update)
        #expect(try await task.value.map(\.id) == [1600])
        #expect(try await s.core.eventLog.page(since: before, limit: 100).events.filter { $0.type == .messageNew }.count == 1)
    }
}
