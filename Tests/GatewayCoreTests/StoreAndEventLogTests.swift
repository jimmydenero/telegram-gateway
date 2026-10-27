import Foundation
import GatewayCore
import GatewayTestSupport
import Testing

@Suite struct StoreTests {
    @Test func migrationsCreateEveryTable() async throws {
        let store = try Store.inMemory()
        #expect(try await store.appliedMigrations() == ["v1", "v2-chat-state"])
        #expect(try await store.tableNames() == [
            "access_requests", "chat_cursors", "chats", "deliveries", "events", "folders", "grants", "media", "media_refs",
            "meta", "monitored_sources",
        ])
    }

    @Test func fileStoreUsesWALAndReopens() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "tgw-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let store = try Store.open(paths: paths)
        #expect(try await store.journalMode() == "wal")
        try await store.setMeta("k", "v")
        let reopened = try Store.open(paths: paths)
        #expect(try await reopened.meta("k") == "v")
        #expect(try await reopened.appliedMigrations() == ["v1", "v2-chat-state"])
    }

    @Test func monitoredSetAndEffectiveSetThroughFolders() async throws {
        let store = try Store.inMemory()
        let now = Date()
        try await store.upsertFolder(Folder(id: 3, title: "Product", chatIds: [-1001, -1002]), now: now)
        try await store.setMonitoredSet(MonitoredSet(chatIds: [-1002, -1003], folderIds: [3]), now: now)
        let effective = try await store.effectiveMonitored()
        #expect(Set(effective.keys) == [-1001, -1002, -1003])
        #expect(effective[-1001] == MonitoringInfo(source: .folder, folderId: 3, folderTitle: "Product"))
        // Explicit wins over folder membership.
        #expect(effective[-1002] == MonitoringInfo(source: .chat, folderId: nil, folderTitle: nil))
        #expect(try await store.monitoredSet() == MonitoredSet(chatIds: [-1003, -1002], folderIds: [3]))
    }

    @Test func cursorsNeverMoveBackwards() async throws {
        let store = try Store.inMemory()
        try await store.advanceCursor(chatId: -1, messageId: 500, now: Date())
        try await store.advanceCursor(chatId: -1, messageId: 300, now: Date())
        #expect(try await store.cursor(chatId: -1) == 500)
        try await store.deleteCursor(chatId: -1)
        #expect(try await store.cursor(chatId: -1) == nil)
    }

    @Test func grantRoundTripsEveryField() async throws {
        let store = try Store.inMemory()
        var webhook = Webhook(url: "https://x.example/h", secret: "whsec_1", state: .retrying, cursorSeq: 7)
        webhook.lastError = "HTTP 500"
        webhook.failingSince = Date(timeIntervalSince1970: 10)
        let grant = Grant(
            id: "grant_1", name: "A", description: "D", scopes: [.chatsRead, .messagesRead], chats: .folder(id: 3),
            tokenHash: "h", webhook: webhook, createdAt: Date(timeIntervalSince1970: 1), lastSeenAt: nil, revokedAt: nil
        )
        try await store.insertGrant(grant)
        #expect(try await store.grant("grant_1") == grant)
        #expect(try await store.grant(tokenHash: "h") == grant)
        var revoked = grant
        revoked.revokedAt = Date(timeIntervalSince1970: 2)
        try await store.updateGrant(revoked)
        #expect(try await store.grants(includeRevoked: false).isEmpty)
        #expect(try await store.grants(includeRevoked: true) == [revoked])
        #expect(try await store.deleteGrants(revokedBefore: Date(timeIntervalSince1970: 3)) == 1)
    }

    @Test func mediaIndexTracksReferencesAndCacheState() async throws {
        let store = try Store.inMemory()
        let media = Media(mediaId: "med_1", kind: .photo, mime: "image/jpeg", size: 10, width: 1, height: 1, durationSeconds: nil, fileName: nil)
        try await store.recordMedia(MediaRecord(media: media, remoteId: "r", uniqueId: "u"), chatId: -1)
        try await store.recordMedia(MediaRecord(media: media, remoteId: "r", uniqueId: "u"), chatId: -2)
        #expect(try await store.mediaChatIds("med_1") == [-1, -2])
        try await store.setMediaCached("med_1", localPath: "/tmp/x", bytes: 10, servedAt: Date())
        #expect(try await store.cachedMediaBytes() == 10)
        #expect(try await store.cachedMedia().map(\.media.mediaId) == ["med_1"])
    }
}

@Suite struct EventLogTests {
    @Test func appendAssignsIncreasingSeqAndStampsRecordedAt() async throws {
        let core = try await Core()
        let a = try await core.appendMessageEvent(id: 1)
        let b = try await core.appendMessageEvent(id: 2)
        #expect(a == 1 && b == 2)
        #expect(try await core.eventLog.headSeq() == 2)
        let page = try await core.eventLog.page(since: 0, limit: 10)
        #expect(page.events.map { $0.seq } == [1, 2])
        #expect(page.events[0].recordedAt == core.clock.now)
        #expect(page.events[0].chat.username == "acmeupdates")
        if case .message(let message) = page.events[0].payload { #expect(message.id == 1) } else { Issue.record("payload") }
    }

    @Test func pagingHasMoreAndCursors() async throws {
        let core = try await Core()
        for i in 1...5 { _ = try await core.appendMessageEvent(id: Int64(i)) }
        let first = try await core.eventLog.page(since: 0, limit: 2)
        #expect(first.events.map { $0.seq } == [1, 2] && first.hasMore && first.nextSince == 2 && first.headSeq == 5)
        let second = try await core.eventLog.page(since: first.nextSince, limit: 2)
        #expect(second.events.map { $0.seq } == [3, 4] && second.hasMore)
        let third = try await core.eventLog.page(since: second.nextSince, limit: 2)
        #expect(third.events.map { $0.seq } == [5] && !third.hasMore && third.nextSince == 5)
        let empty = try await core.eventLog.page(since: 5, limit: 2)
        #expect(empty.events.isEmpty && empty.nextSince == 5 && empty.headSeq == 5)
    }

    @Test func filtersByTypeAndChat() async throws {
        let core = try await Core()
        _ = try await core.appendMessageEvent(chatId: Fixtures.channelId, id: 1)
        _ = try await core.appendChatEvent(chatId: Fixtures.groupId)
        _ = try await core.appendMessageEvent(chatId: Fixtures.groupId, id: 2)
        let messages = try await core.eventLog.page(since: 0, limit: 10, types: [.messageNew])
        #expect(messages.events.map { $0.seq } == [1, 3])
        let group = try await core.eventLog.page(since: 0, limit: 10, chatIds: [Fixtures.groupId])
        #expect(group.events.map { $0.seq } == [2, 3])
        let none = try await core.eventLog.page(since: 0, limit: 10, chatIds: [])
        #expect(none.events.isEmpty && none.headSeq == 3)
    }

    @Test func pruneAndHistoryPrunedSemantics() async throws {
        let core = try await Core()
        for i in 1...10 { _ = try await core.appendMessageEvent(id: Int64(i)) }
        let (deleted, oldest) = try await core.eventLog.prune(beforeSeq: 5)
        #expect(deleted == 4 && oldest == 5)
        #expect(try await core.eventLog.oldestSeq() == 5)
        // since = 0 is "from the beginning of retained history".
        #expect(try await core.eventLog.page(since: 0, limit: 10).events.first?.seq == 5)
        // since = oldest - 1 starts exactly at the oldest retained event: nothing missed.
        #expect(try await core.eventLog.page(since: 4, limit: 10).events.first?.seq == 5)
        // since below that would skip pruned events → 410.
        await #expect(throws: EventLog.PageError.historyPruned(oldestSeq: 5)) {
            try await core.eventLog.page(since: 3, limit: 10)
        }
        // A fully pruned log keeps counting.
        _ = try await core.eventLog.prune(beforeSeq: 100)
        #expect(try await core.eventLog.headSeq() == 10)
        #expect(try await core.appendMessageEvent(id: 11) == 11)
    }

    @Test func olderThanBoundary() async throws {
        let core = try await Core()
        _ = try await core.appendMessageEvent(id: 1)
        core.clock.advance(by: .seconds(100))
        _ = try await core.appendMessageEvent(id: 2)
        let cutoff = core.clock.now.addingTimeInterval(-50)
        #expect(try await core.eventLog.seq(recordedAtOrAfter: cutoff) == 2)
        #expect(try await core.eventLog.seq(recordedAtOrAfter: core.clock.now.addingTimeInterval(10)) == 3)
    }

    @Test func subscribersLearnNewHeads() async throws {
        let core = try await Core()
        let stream = await core.eventLog.subscribe()
        #expect(await core.eventLog.subscriberCount == 1)
        _ = try await core.appendMessageEvent(id: 1)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 1)
    }
}
