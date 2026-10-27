import Foundation
import Logging
import TDLibClient

/// Watches the monitored chats: consumes TDLib updates, keeps the chat and folder caches,
/// appends events to the log, maintains per-chat cursors and backfills after a gap
/// (docs/architecture.md "Delivery guarantees"). Never calls `viewMessages` or `openChat`.
public actor Monitor {
    public static let memberCountCoalesce: TimeInterval = 5 * 60
    /// At most one `chat.read` per chat per second (docs/events.md "chat.read").
    public static let readCoalesce: TimeInterval = 1
    /// At most one `chat.position` per chat per `00:10` when only the order changed.
    public static let orderCoalesce: TimeInterval = 10

    public struct BackfillStatus: Sendable, Equatable {
        public var inProgress: Bool
        public var chatsPending: Int

        public init(inProgress: Bool = false, chatsPending: Int = 0) {
            self.inProgress = inProgress
            self.chatsPending = chatsPending
        }
    }

    private let store: Store
    private let eventLog: EventLog
    private let translator: Translator
    private let tdlib: any TDLibRequesting
    private let clock: any GatewayClock
    private let logger: Logger

    private var monitored: [Int64: MonitoringInfo] = [:]
    public private(set) var connectionState: ConnectionState = .connecting
    public private(set) var backfill = BackfillStatus()
    private var backfillTask: Task<Void, Never>?
    private var loaded = false
    /// Cursors as they were when the connection was last lost (or at startup). A live update
    /// that arrives before the backfill runs advances the cursor past messages we never saw;
    /// the backfill starts from this snapshot instead.
    private var gapCursors: [Int64: Int64] = [:]

    /// Coalescing of `chat.read` and `chat.position`: when each was last emitted per chat, the
    /// state it carried, and the trailing emission waiting for its interval to pass.
    private enum Coalesced: Hashable {
        case read(Int64)
        case position(Int64)
    }
    private var emittedAt: [Coalesced: Date] = [:]
    private var emittedState: [Coalesced: ChatState] = [:]
    private var pendingEmits: [Coalesced: Task<Void, Never>] = [:]

    public init(
        store: Store, eventLog: EventLog, translator: Translator, tdlib: any TDLibRequesting,
        clock: any GatewayClock = SystemClock(), logger: Logger = Logger(label: "monitor")
    ) {
        self.store = store
        self.eventLog = eventLog
        self.translator = translator
        self.tdlib = tdlib
        self.clock = clock
        self.logger = logger
    }

    /// Reads the monitored set from the store. Called once before handling updates.
    public func load() async throws {
        monitored = try await store.effectiveMonitored()
        gapCursors = try await store.cursors()
        loaded = true
    }

    public var monitoredChatIds: Set<Int64> { Set(monitored.keys) }

    /// Consumes updates until the stream ends.
    public func run(updates: AsyncStream<JSONBox>) async {
        if !loaded { try? await load() }
        for await update in updates {
            await handle(update: update)
        }
    }

    /// Processes one update. Errors are logged, never thrown: one bad update must not stop
    /// the stream.
    public func handle(update: JSONBox) async {
        if !loaded { try? await load() }
        do {
            for translated in try await translator.translate(update: update) {
                try await apply(translated)
            }
        } catch {
            logger.error("update \(update.object.type ?? "?") failed: \(error)")
        }
    }

    private func apply(_ translated: Translated) async throws {
        switch translated {
        case .messageNew(let tm):
            guard monitored[tm.chat.id] != nil else { return }
            try await recordNew(tm, internalId: MessageId.toInternal(tm.message.id))

        case .messageEdited(let tm):
            guard monitored[tm.chat.id] != nil else { return }
            try await store.upsertChat(tm.chat, now: clock.now)
            for record in tm.media { try await store.recordMedia(record, chatId: tm.chat.id) }
            let event = Event(
                type: .messageEdited, occurredAt: tm.message.editDate ?? clock.now, recordedAt: clock.now,
                chat: tm.chat.summary, payload: .message(tm.message)
            )
            try await eventLog.append(event)

        case .messageDeleted(let chatId, let ids):
            guard monitored[chatId] != nil else { return }
            let summary = try await summary(chatId)
            let now = clock.now
            try await eventLog.append(Event(type: .messageDeleted, occurredAt: now, recordedAt: now, chat: summary, payload: .messageIds(ids)))

        case .chatChanged(let chatId):
            guard monitored[chatId] != nil else { return }
            try await refreshChat(chatId)

        case .foldersChanged(let infos):
            try await refreshFolders(infos)

        case .folderMembership(let folderId, let chatId, let added):
            guard var folder = try await store.folder(folderId) else { return }
            if added, !folder.chatIds.contains(chatId) {
                folder.chatIds.append(chatId)
            } else if !added {
                folder.chatIds.removeAll { $0 == chatId }
            } else {
                return
            }
            try await store.upsertFolder(folder, now: clock.now)
            try await reconcileMonitored()

        case .chatState(let chatId, let state):
            guard monitored[chatId] != nil else { return }
            try await applyState(chatId, state)

        case .messageReactions(let chatId, let messageId, let reactions):
            guard monitored[chatId] != nil else { return }
            let now = clock.now
            let chat = try await summary(chatId)
            try await eventLog.append(Event(type: .messageReactions, occurredAt: now, recordedAt: now, chat: chat, payload: .reactions(messageId: messageId, reactions)))

        case .pollUpdated(let chatId, let messageId, let poll):
            guard monitored[chatId] != nil else { return }
            let now = clock.now
            let chat = try await summary(chatId)
            try await eventLog.append(Event(type: .pollUpdated, occurredAt: now, recordedAt: now, chat: chat, payload: .poll(messageId: messageId, poll)))

        case .connectionState(let state):
            let previous = connectionState
            connectionState = state
            if state != .ready, previous == .ready {
                gapCursors = try await store.cursors()
            }
            if state == .ready, previous != .ready {
                await translator.clearCaches()
                startBackfill()
            }
        }
    }

    // MARK: Messages

    /// Appends `message.new` unless this message was already recorded (an update racing a
    /// backfill), records its media, advances the cursor.
    private func recordNew(_ tm: TranslatedMessage, internalId: Int64) async throws {
        let chatId = tm.chat.id
        let cursor = try await store.cursor(chatId: chatId) ?? 0
        if internalId <= cursor, try await store.hasMessageEvent(chatId: chatId, messageId: tm.message.id) {
            return
        }
        try await store.upsertChat(tm.chat, now: clock.now)
        for record in tm.media { try await store.recordMedia(record, chatId: chatId) }
        let event = Event(type: .messageNew, occurredAt: tm.message.date, recordedAt: clock.now, chat: tm.chat.summary, payload: .message(tm.message))
        try await eventLog.append(event)
        try await store.advanceCursor(chatId: chatId, messageId: internalId, now: clock.now)
    }

    // MARK: Chats

    /// Re-reads a chat and emits `chat.updated` with the changed fields. Member-count-only
    /// changes are coalesced to one event per chat per `05:00`; the cache is always updated.
    private func refreshChat(_ chatId: Int64) async throws {
        let previous = try await store.chat(chatId)
        let fresh = try await translator.chatInfo(chatId, refresh: true)
        let changes = ChatInfo.changes(from: previous, to: fresh)
        try await store.upsertChat(fresh, now: clock.now)
        if let record = try await translator.chatPhotoRecord(chatId) {
            try await store.recordMedia(record, chatId: chatId)
        }
        guard !changes.isEmpty else { return }
        let now = clock.now
        if changes == ["member_count"], let last = try await store.memberCountEventAt(chatId: chatId),
           now.timeIntervalSince(last) < Monitor.memberCountCoalesce {
            return
        }
        if changes.contains("member_count") { try await store.setMemberCountEventAt(chatId: chatId, now) }
        try await eventLog.append(Event(type: .chatUpdated, occurredAt: now, recordedAt: now, chat: fresh.summary, payload: .chat(fresh, changes: changes)))
    }

    // MARK: Read state and position

    /// Records a monitored chat's new state and emits what changed: `chat.read`,
    /// `chat.position`, or `chat.updated` for `is_muted`. The first state recorded for a chat
    /// is a baseline and emits nothing.
    private func applyState(_ chatId: Int64, _ state: ChatState) async throws {
        guard var chat = try await store.chat(chatId) else { return }
        let previous = chat.state
        guard previous != state else { return }
        try await store.setChatState(chatId: chatId, state)
        guard let previous else { return }
        if !previous.sameRead(as: state) {
            try await coalesce(.read(chatId), interval: Monitor.readCoalesce, immediate: false)
        }
        if !previous.samePosition(as: state) {
            // Pinning, unpinning, archiving and unarchiving are emitted at once; the order alone
            // changes with every message, so it is coalesced.
            let moved = previous.isPinned != state.isPinned || previous.isArchived != state.isArchived
            try await coalesce(.position(chatId), interval: Monitor.orderCoalesce, immediate: moved)
        }
        if previous.isMuted != state.isMuted {
            chat.state = state
            let now = clock.now
            try await eventLog.append(Event(type: .chatUpdated, occurredAt: now, recordedAt: now, chat: chat.summary, payload: .chat(chat, changes: ["is_muted"])))
        }
    }

    /// Emits now if the interval since the last emission has passed (or `immediate`),
    /// otherwise once it has, with the state as it is then.
    private func coalesce(_ key: Coalesced, interval: TimeInterval, immediate: Bool) async throws {
        let now = clock.now
        if immediate || emittedAt[key].map({ now.timeIntervalSince($0) >= interval }) ?? true {
            try await emitState(key)
            return
        }
        guard pendingEmits[key] == nil else { return }
        pendingEmits[key] = Task { [weak self] in
            await self?.emitWhenDue(key, interval: interval)
        }
    }

    private func emitWhenDue(_ key: Coalesced, interval: TimeInterval) async {
        while let last = emittedAt[key] {
            let wait = interval - clock.now.timeIntervalSince(last)
            guard wait > 0 else { break }
            do {
                try await clock.sleep(for: .milliseconds(Int64((wait * 1000).rounded(.up))))
            } catch {
                return // cancelled by whoever removed it from `pendingEmits`
            }
        }
        pendingEmits[key] = nil
        do {
            try await emitState(key)
        } catch {
            logger.error("coalesced \(key) failed: \(error)")
        }
    }

    /// Appends `chat.read` or `chat.position` with the chat's recorded state, unless it equals
    /// what was last emitted (a change that was undone within the interval).
    private func emitState(_ key: Coalesced) async throws {
        let chatId: Int64, type: EventType
        switch key {
        case .read(let id): (chatId, type) = (id, .chatRead)
        case .position(let id): (chatId, type) = (id, .chatPosition)
        }
        guard monitored[chatId] != nil, let chat = try await store.chat(chatId), let state = chat.state else { return }
        if let last = emittedState[key] {
            let same = type == .chatRead ? last.sameRead(as: state) : last.samePosition(as: state)
            if same { return }
        }
        let now = clock.now
        emittedAt[key] = now
        emittedState[key] = state
        try await eventLog.append(Event(type: type, occurredAt: now, recordedAt: now, chat: chat.summary, payload: .chatState(state)))
    }

    /// Waits for coalesced emissions that are due (tests: after advancing the clock).
    public func waitForCoalesced() async {
        for task in pendingEmits.values { await task.value }
    }

    private func summary(_ chatId: Int64) async throws -> ChatSummary {
        if let cached = try await store.chat(chatId) { return cached.summary }
        if let info = try? await translator.chatInfo(chatId) {
            try await store.upsertChat(info, now: clock.now)
            return info.summary
        }
        return ChatSummary(id: chatId, type: chatId > 0 ? .private : .supergroup, title: "", username: nil)
    }

    // MARK: Folders

    /// Replaces the folder cache from TDLib: every folder's title and current chat list.
    public func refreshFolders(_ infos: [(id: Int64, title: String)]) async throws {
        let known = try await store.folders()
        for folder in known where !infos.contains(where: { $0.id == folder.id }) {
            try await store.deleteFolder(folder.id)
        }
        for info in infos {
            let chatIds = try await folderChatIds(info.id)
            try await store.upsertFolder(Folder(id: info.id, title: info.title, chatIds: chatIds), now: clock.now)
        }
        try await reconcileMonitored()
    }

    /// Loads a folder's chat list from TDLib. `loadChats` pages the list from the server
    /// until TDLib answers 404 ("nothing more"); `getChats` then returns the ids.
    private func folderChatIds(_ folderId: Int64) async throws -> [Int64] {
        let list: JSONObject = ["@type": "chatListFolder", "chat_folder_id": folderId]
        for _ in 0..<50 {
            do {
                _ = try await tdlib.request("loadChats", ["chat_list": list, "limit": 100])
            } catch let error as TDLibError where error.code == 404 {
                break
            }
        }
        let chats = try await tdlib.request("getChats", ["chat_list": list, "limit": 1000]).object
        return (chats.array("chat_ids") ?? []).compactMap(Translator.int64)
    }

    // MARK: Monitored set

    /// Replaces the monitored set (`PUT /v1/admin/monitored-chats`): validates every chat and
    /// folder, saves, and emits `monitoring.started` / `monitoring.stopped` for the difference.
    public func setMonitoredSet(_ set: MonitoredSet) async throws {
        let folders = try await store.folders()
        for folderId in set.folderIds where !folders.contains(where: { $0.id == folderId }) {
            throw APIError.invalidRequest("folder_ids", "unknown folder \(folderId)")
        }
        for chatId in set.chatIds {
            let info = try await translator.chatInfo(chatId)
            try await store.upsertChat(info, now: clock.now)
        }
        try await store.setMonitoredSet(set, now: clock.now)
        try await reconcileMonitored()
    }

    /// Compares the stored effective set with what this actor last saw and emits the
    /// difference. Called after any change to the monitored sources or the folder cache.
    public func reconcileMonitored() async throws {
        let previous = monitored
        let current = try await store.effectiveMonitored()
        monitored = current
        loaded = true
        let now = clock.now
        for chatId in previous.keys.sorted() where current[chatId] == nil {
            guard let info = previous[chatId] else { continue }
            let chat = try await summary(chatId)
            try await store.deleteCursor(chatId: chatId)
            gapCursors.removeValue(forKey: chatId)
            for key in [Coalesced.read(chatId), .position(chatId)] {
                pendingEmits.removeValue(forKey: key)?.cancel()
                emittedAt.removeValue(forKey: key)
                emittedState.removeValue(forKey: key)
            }
            try await eventLog.append(Event(type: .monitoringStopped, occurredAt: now, recordedAt: now, chat: chat, payload: .monitoring(info)))
        }
        for chatId in current.keys.sorted() where previous[chatId] == nil {
            guard let info = current[chatId] else { continue }
            var chat: ChatInfo
            do {
                chat = try await translator.chatInfo(chatId)
                try await store.upsertChat(chat, now: now)
                // The baseline later updates are compared with.
                if let state = chat.state { try await store.setChatState(chatId: chatId, state) }
            } catch {
                logger.warning("chat \(chatId) entered the monitored set but cannot be read: \(error)")
                chat = try await store.chat(chatId) ?? ChatInfo(id: chatId, type: chatId > 0 ? .private : .supergroup, title: "", username: nil, memberCount: nil, photo: nil)
            }
            // Backfill from now on, not before: the cursor starts at the chat's last message.
            if try await store.cursor(chatId: chatId) == nil, let last = try? await translator.lastMessageId(chatId) {
                try await store.advanceCursor(chatId: chatId, messageId: last, now: now)
            }
            try await eventLog.append(Event(type: .monitoringStarted, occurredAt: now, recordedAt: now, chat: chat.summary, payload: .monitoring(info)))
        }
    }

    // MARK: Backfill

    /// Pulls history from each chat's cursor forward. Runs once at a time; a second request
    /// while one is running is a no-op (the running one reads cursors as it goes).
    public func startBackfill() {
        guard backfillTask == nil else { return }
        backfillTask = Task { [weak self] in
            await self?.runBackfill()
            await self?.backfillFinished()
        }
    }

    private func backfillFinished() {
        backfillTask = nil
    }

    /// Waits for a running backfill to finish (tests).
    public func waitForBackfill() async {
        await backfillTask?.value
    }

    private func runBackfill() async {
        let chats = monitored.keys.sorted()
        let snapshot = gapCursors
        gapCursors = [:]
        backfill = BackfillStatus(inProgress: true, chatsPending: chats.count)
        defer { backfill = BackfillStatus() }
        for chatId in chats {
            do {
                try await backfillChat(chatId, gapCursor: snapshot[chatId])
            } catch {
                logger.error("backfill of \(chatId) failed: \(error)")
            }
            backfill.chatsPending -= 1
        }
    }

    /// `getChatHistory` from the cursor with a negative offset returns newer messages; loop
    /// until nothing newer comes back. Each page is applied oldest first so `seq` order matches
    /// message order.
    private func backfillChat(_ chatId: Int64, gapCursor: Int64?) async throws {
        guard let cursor = try await store.cursor(chatId: chatId) else {
            if let last = try await translator.lastMessageId(chatId) {
                try await store.advanceCursor(chatId: chatId, messageId: last, now: clock.now)
            }
            return
        }
        var from = min(cursor, gapCursor ?? cursor)
        for _ in 0..<100 {
            let page = try await translator.history(chatId: chatId, fromInternalId: from, offset: -99, limit: 100)
            let newer = page
                .map { ($0, MessageId.toInternal($0.message.id)) }
                .filter { $0.1 > from }
                .sorted { $0.1 < $1.1 }
            guard !newer.isEmpty else { return }
            for (tm, internalId) in newer {
                try await recordNew(tm, internalId: internalId)
            }
            from = newer[newer.count - 1].1
        }
    }
}
