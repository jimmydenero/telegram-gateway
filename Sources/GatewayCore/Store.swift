import Foundation
import GRDB

/// The gateway's own SQLite database, `<home>/gateway.sqlite` (docs/architecture.md "Data on disk"). One actor
/// owns the connection; every other component goes through it. WAL journal mode so readers
/// never block the monitor's writes.
///
/// Tables (see `migrate`): `monitored_sources`, `chats`, `folders`, `events`, `chat_cursors`,
/// `access_requests`, `grants`, `deliveries`, `media`, `media_refs`, `meta`.
public actor Store {
    private let db: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init(db: DatabaseQueue) throws {
        self.db = db
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        try Store.migrate(db)
    }

    /// Opens (creating if needed) the store at `paths.database`.
    public static func open(paths: Paths) throws -> Store {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: paths.database.path, configuration: configuration)
        return try Store(db: queue)
    }

    /// A private in-memory store for tests.
    public static func inMemory() throws -> Store {
        try Store(db: DatabaseQueue())
    }

    // MARK: Schema

    /// The migrations. Append, never edit: GRDB runs each one once and records it.
    static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE monitored_sources (
                    kind TEXT NOT NULL CHECK (kind IN ('chat', 'folder')),
                    id INTEGER NOT NULL,
                    added_at REAL NOT NULL,
                    PRIMARY KEY (kind, id)
                );
                CREATE TABLE chats (
                    id INTEGER PRIMARY KEY,
                    type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    username TEXT,
                    member_count INTEGER,
                    photo_media_id TEXT,
                    photo_width INTEGER,
                    photo_height INTEGER,
                    updated_at REAL NOT NULL,
                    member_count_event_at REAL
                );
                CREATE TABLE folders (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    chat_ids TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    v INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    chat_id INTEGER NOT NULL,
                    message_id INTEGER,
                    occurred_at REAL NOT NULL,
                    recorded_at REAL NOT NULL,
                    payload TEXT NOT NULL
                );
                CREATE INDEX events_chat_seq ON events (chat_id, seq);
                CREATE INDEX events_type_seq ON events (type, seq);
                CREATE INDEX events_recorded ON events (recorded_at);
                CREATE INDEX events_message ON events (chat_id, message_id) WHERE message_id IS NOT NULL;
                CREATE TABLE chat_cursors (
                    chat_id INTEGER PRIMARY KEY,
                    last_message_id INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE access_requests (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    scopes TEXT NOT NULL,
                    requested_chats TEXT,
                    webhook_url TEXT,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    resolved_at REAL,
                    denied_reason TEXT,
                    grant_id TEXT,
                    issued_token TEXT,
                    issued_webhook_secret TEXT
                );
                CREATE INDEX access_requests_status ON access_requests (status, expires_at);
                CREATE TABLE grants (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    scopes TEXT NOT NULL,
                    chat_mode TEXT NOT NULL CHECK (chat_mode IN ('list', 'folder')),
                    chat_ids TEXT NOT NULL,
                    folder_id INTEGER,
                    token_hash TEXT NOT NULL UNIQUE,
                    webhook_url TEXT,
                    webhook_secret TEXT,
                    webhook_state TEXT,
                    webhook_cursor_seq INTEGER,
                    webhook_last_delivery_at REAL,
                    webhook_last_error TEXT,
                    webhook_paused_at REAL,
                    webhook_failing_since REAL,
                    created_at REAL NOT NULL,
                    last_seen_at REAL,
                    revoked_at REAL
                );
                CREATE TABLE deliveries (
                    id TEXT PRIMARY KEY,
                    grant_id TEXT NOT NULL,
                    seqs TEXT NOT NULL,
                    first_seq INTEGER NOT NULL,
                    last_seq INTEGER NOT NULL,
                    attempt INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    http_status INTEGER,
                    error TEXT,
                    sent_at REAL NOT NULL,
                    completed_at REAL
                );
                CREATE INDEX deliveries_grant ON deliveries (grant_id, sent_at DESC);
                CREATE TABLE media (
                    media_id TEXT PRIMARY KEY,
                    remote_id TEXT NOT NULL,
                    unique_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    mime TEXT,
                    size INTEGER,
                    width INTEGER,
                    height INTEGER,
                    duration_seconds INTEGER,
                    file_name TEXT,
                    local_path TEXT,
                    cached_bytes INTEGER NOT NULL DEFAULT 0,
                    last_served_at REAL
                );
                CREATE TABLE media_refs (
                    media_id TEXT NOT NULL,
                    chat_id INTEGER NOT NULL,
                    PRIMARY KEY (media_id, chat_id)
                );
                CREATE TABLE meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
        // A chat's read state and list position (`ChatState`) as JSON; null until known.
        migrator.registerMigration("v2-chat-state") { db in
            try db.execute(sql: "ALTER TABLE chats ADD COLUMN state TEXT")
        }
        try migrator.migrate(db)
    }

    /// Names of the applied migrations, for tests.
    public func appliedMigrations() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    public func tableNames() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name")
        }
    }

    public func journalMode() throws -> String {
        try db.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "" }
    }

    // MARK: Helpers

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try decoder.decode(type, from: Data(text.utf8))
    }

    private static func date(_ value: Double?) -> Date? {
        value.map { Date(timeIntervalSince1970: $0) }
    }

    private static func seconds(_ date: Date?) -> Double? {
        date?.timeIntervalSince1970
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    // MARK: Monitored set

    public func monitoredSet() throws -> MonitoredSet {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT kind, id FROM monitored_sources ORDER BY id")
            var set = MonitoredSet()
            for row in rows {
                let kind: String = row["kind"]
                let id: Int64 = row["id"]
                if kind == "chat" { set.chatIds.append(id) } else { set.folderIds.append(id) }
            }
            return set
        }
    }

    public func setMonitoredSet(_ set: MonitoredSet, now: Date) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM monitored_sources")
            for id in Set(set.chatIds).sorted() {
                try db.execute(sql: "INSERT INTO monitored_sources (kind, id, added_at) VALUES ('chat', ?, ?)", arguments: [id, now.timeIntervalSince1970])
            }
            for id in Set(set.folderIds).sorted() {
                try db.execute(sql: "INSERT INTO monitored_sources (kind, id, added_at) VALUES ('folder', ?, ?)", arguments: [id, now.timeIntervalSince1970])
            }
        }
    }

    /// Every chat in the effective monitored set with why it is there: an explicitly
    /// monitored chat has `source: chat`; a chat that is only in a monitored folder has
    /// `source: folder` with that folder. Explicit wins when both apply.
    public func effectiveMonitored() throws -> [Int64: MonitoringInfo] {
        let set = try monitoredSet()
        let folders = try folders()
        var result: [Int64: MonitoringInfo] = [:]
        for folderId in set.folderIds {
            guard let folder = folders.first(where: { $0.id == folderId }) else { continue }
            for chatId in folder.chatIds where result[chatId] == nil {
                result[chatId] = MonitoringInfo(source: .folder, folderId: folder.id, folderTitle: folder.title)
            }
        }
        for chatId in set.chatIds {
            result[chatId] = MonitoringInfo(source: .chat, folderId: nil, folderTitle: nil)
        }
        return result
    }

    public func effectiveMonitoredChatIds() throws -> Set<Int64> {
        Set(try effectiveMonitored().keys)
    }

    // MARK: Chats cache

    /// The stored state is kept once there is one: only the monitor changes it, through
    /// `setChatState`, so that it compares each update with what it last recorded.
    public func upsertChat(_ chat: ChatInfo, now: Date) throws {
        let state = try chat.state.map(encode)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO chats (id, type, title, username, member_count, photo_media_id, photo_width, photo_height, updated_at, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET type = excluded.type, title = excluded.title, username = excluded.username,
                    member_count = excluded.member_count, photo_media_id = excluded.photo_media_id,
                    photo_width = excluded.photo_width, photo_height = excluded.photo_height, updated_at = excluded.updated_at,
                    state = COALESCE(chats.state, excluded.state)
                """, arguments: [
                    chat.id, chat.type.rawValue, chat.title, chat.username, chat.memberCount,
                    chat.photo?.mediaId, chat.photo?.width, chat.photo?.height, now.timeIntervalSince1970, state,
                ])
        }
    }

    /// Replaces a cached chat's read state and position. No-op for a chat not in the cache.
    public func setChatState(chatId: Int64, _ state: ChatState) throws {
        let text = try encode(state)
        try db.write { db in
            try db.execute(sql: "UPDATE chats SET state = ? WHERE id = ?", arguments: [text, chatId])
        }
    }

    public func chat(_ id: Int64) throws -> ChatInfo? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM chats WHERE id = ?", arguments: [id]).map(Store.chatInfo)
        }
    }

    public func chats(_ ids: [Int64]) throws -> [ChatInfo] {
        guard !ids.isEmpty else { return [] }
        return try db.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM chats WHERE id IN (\(placeholders)) ORDER BY id", arguments: StatementArguments(ids))
            return rows.map(Store.chatInfo)
        }
    }

    public func allChats() throws -> [ChatInfo] {
        try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM chats ORDER BY id").map(Store.chatInfo) }
    }

    private static func chatInfo(_ row: Row) -> ChatInfo {
        let photo: ChatPhoto?
        if let mediaId: String = row["photo_media_id"] {
            photo = ChatPhoto(mediaId: mediaId, width: row["photo_width"] ?? 0, height: row["photo_height"] ?? 0)
        } else {
            photo = nil
        }
        return ChatInfo(
            id: row["id"],
            type: ChatType(rawValue: row["type"]) ?? .supergroup,
            title: row["title"],
            username: row["username"],
            memberCount: row["member_count"],
            photo: photo,
            state: (row["state"] as String?).flatMap { try? JSONDecoder().decode(ChatState.self, from: Data($0.utf8)) }
        )
    }

    public func memberCountEventAt(chatId: Int64) throws -> Date? {
        try db.read { db in
            Store.date(try Double.fetchOne(db, sql: "SELECT member_count_event_at FROM chats WHERE id = ?", arguments: [chatId]))
        }
    }

    public func setMemberCountEventAt(chatId: Int64, _ date: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE chats SET member_count_event_at = ? WHERE id = ?", arguments: [date.timeIntervalSince1970, chatId])
        }
    }

    // MARK: Folders cache

    public func upsertFolder(_ folder: Folder, now: Date) throws {
        let ids = try encode(folder.chatIds)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO folders (id, title, chat_ids, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, chat_ids = excluded.chat_ids, updated_at = excluded.updated_at
                """, arguments: [folder.id, folder.title, ids, now.timeIntervalSince1970])
        }
    }

    public func deleteFolder(_ id: Int64) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id]) }
    }

    public func folders() throws -> [Folder] {
        let rows = try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY id") }
        return try rows.map { row in
            Folder(id: row["id"], title: row["title"], chatIds: try decode([Int64].self, row["chat_ids"]))
        }
    }

    public func folder(_ id: Int64) throws -> Folder? {
        try folders().first { $0.id == id }
    }

    // MARK: Events

    /// Appends and returns the assigned sequence number.
    public func appendEvent(_ event: Event) throws -> Int64 {
        let payload = try encode(StoredPayload(chat: event.chat, payload: event.payload))
        return try db.write { db in
            try db.execute(sql: """
                INSERT INTO events (v, type, chat_id, message_id, occurred_at, recorded_at, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    Event.formatVersion, event.type.rawValue, event.chatId, event.messageId,
                    event.occurredAt.timeIntervalSince1970, event.recordedAt.timeIntervalSince1970, payload,
                ])
            return db.lastInsertedRowID
        }
    }

    /// A page of the log after `since` (exclusive), ascending. `chatIds == nil` means every
    /// chat (admin); an empty set means nothing. Returns `limit + 1` rows at most so the caller
    /// can compute `has_more`.
    public func events(since: Int64, limit: Int, types: Set<EventType>?, chatIds: Set<Int64>?) throws -> [Event] {
        if let chatIds, chatIds.isEmpty { return [] }
        if let types, types.isEmpty { return [] }
        var sql = "SELECT * FROM events WHERE seq > ?"
        var arguments: [any DatabaseValueConvertible] = [since]
        if let types {
            sql += " AND type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            arguments.append(contentsOf: types.map(\.rawValue).sorted())
        }
        if let chatIds {
            sql += " AND chat_id IN (\(chatIds.map { _ in "?" }.joined(separator: ",")))"
            arguments.append(contentsOf: chatIds.sorted())
        }
        sql += " ORDER BY seq LIMIT ?"
        arguments.append(limit)
        let rows = try db.read { db in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)) }
        return try rows.map(eventFromRow)
    }

    /// Events by sequence number (a webhook retry re-sends exactly the same batch).
    public func events(seqs: [Int64]) throws -> [Event] {
        guard !seqs.isEmpty else { return [] }
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM events WHERE seq IN (\(seqs.map { _ in "?" }.joined(separator: ","))) ORDER BY seq", arguments: StatementArguments(seqs))
        }
        return try rows.map(eventFromRow)
    }

    private func eventFromRow(_ row: Row) throws -> Event {
        let stored = try decode(StoredPayload.self, row["payload"])
        var event = Event(
            seq: row["seq"],
            type: EventType(rawValue: row["type"]) ?? .messageNew,
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
            recordedAt: Date(timeIntervalSince1970: row["recorded_at"]),
            chat: stored.chat,
            payload: stored.payload
        )
        event.messageId = row["message_id"]
        return event
    }

    /// Count of events after `since` visible to a chat set / type set (webhook `pending_events`).
    public func eventCount(since: Int64, types: Set<EventType>?, chatIds: Set<Int64>?) throws -> Int64 {
        if let chatIds, chatIds.isEmpty { return 0 }
        if let types, types.isEmpty { return 0 }
        var sql = "SELECT COUNT(*) FROM events WHERE seq > ?"
        var arguments: [any DatabaseValueConvertible] = [since]
        if let types {
            sql += " AND type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            arguments.append(contentsOf: types.map(\.rawValue).sorted())
        }
        if let chatIds {
            sql += " AND chat_id IN (\(chatIds.map { _ in "?" }.joined(separator: ",")))"
            arguments.append(contentsOf: chatIds.sorted())
        }
        return try db.read { db in try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0 }
    }

    public func eventCount(recordedAfter date: Date) throws -> Int64 {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE recorded_at > ?", arguments: [date.timeIntervalSince1970]) ?? 0
        }
    }

    /// Newest `seq`, or 0 when the log is empty (or fully pruned: the counter keeps going).
    public func headSeq() throws -> Int64 {
        try db.read { db in
            if let max = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM events") { return max }
            return try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'events'") ?? 0
        }
    }

    /// Oldest retained `seq`, or nil when the log is empty.
    public func oldestSeq() throws -> Int64? {
        try db.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM events") }
    }

    /// The first `seq` recorded at or after `date`, or head + 1 when none.
    public func firstSeq(recordedAtOrAfter date: Date) throws -> Int64 {
        let head = try headSeq()
        return try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM events WHERE recorded_at >= ?", arguments: [date.timeIntervalSince1970]) ?? (head + 1)
        }
    }

    /// Deletes events with `seq < beforeSeq`. Returns how many.
    public func pruneEvents(beforeSeq: Int64) throws -> Int {
        try db.write { db in
            try db.execute(sql: "DELETE FROM events WHERE seq < ?", arguments: [beforeSeq])
            return db.changesCount
        }
    }

    /// Whether a `message.new` for this (chat, public message id) was already recorded.
    public func hasMessageEvent(chatId: Int64, messageId: Int64) throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM events WHERE chat_id = ? AND message_id = ? AND type = 'message.new')", arguments: [chatId, messageId]) ?? false
        }
    }

    // MARK: Chat cursors (TDLib internal message ids)

    public func cursor(chatId: Int64) throws -> Int64? {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT last_message_id FROM chat_cursors WHERE chat_id = ?", arguments: [chatId])
        }
    }

    public func cursors() throws -> [Int64: Int64] {
        let rows = try db.read { db in try Row.fetchAll(db, sql: "SELECT chat_id, last_message_id FROM chat_cursors") }
        var result: [Int64: Int64] = [:]
        for row in rows { result[row["chat_id"]] = row["last_message_id"] }
        return result
    }

    /// Advances the cursor; never moves it backwards.
    public func advanceCursor(chatId: Int64, messageId: Int64, now: Date) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO chat_cursors (chat_id, last_message_id, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(chat_id) DO UPDATE SET
                    last_message_id = MAX(last_message_id, excluded.last_message_id), updated_at = excluded.updated_at
                """, arguments: [chatId, messageId, now.timeIntervalSince1970])
        }
    }

    public func deleteCursor(chatId: Int64) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM chat_cursors WHERE chat_id = ?", arguments: [chatId]) }
    }

    // MARK: Access requests

    public func insertAccessRequest(_ request: AccessRequest) throws {
        try writeAccessRequest(request, insert: true)
    }

    public func updateAccessRequest(_ request: AccessRequest) throws {
        try writeAccessRequest(request, insert: false)
    }

    private func writeAccessRequest(_ r: AccessRequest, insert: Bool) throws {
        let scopes = try encode(r.scopes)
        let requested = try r.requestedChats.map { try encode($0) }
        try db.write { db in
            if insert {
                try db.execute(sql: """
                    INSERT INTO access_requests (id, status, name, description, scopes, requested_chats, webhook_url,
                        created_at, expires_at, resolved_at, denied_reason, grant_id, issued_token, issued_webhook_secret)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        r.id, r.status.rawValue, r.name, r.description, scopes, requested, r.webhookUrl,
                        r.createdAt.timeIntervalSince1970, r.expiresAt.timeIntervalSince1970, Store.seconds(r.resolvedAt),
                        r.deniedReason, r.grantId, r.issuedToken, r.issuedWebhookSecret,
                    ])
            } else {
                try db.execute(sql: """
                    UPDATE access_requests SET status = ?, resolved_at = ?, denied_reason = ?, grant_id = ?,
                        issued_token = ?, issued_webhook_secret = ?, expires_at = ?
                    WHERE id = ?
                    """, arguments: [
                        r.status.rawValue, Store.seconds(r.resolvedAt), r.deniedReason, r.grantId, r.issuedToken,
                        r.issuedWebhookSecret, r.expiresAt.timeIntervalSince1970, r.id,
                    ])
            }
        }
    }

    public func accessRequest(_ id: String) throws -> AccessRequest? {
        let row = try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM access_requests WHERE id = ?", arguments: [id]) }
        return try row.map(accessRequest(from:))
    }

    public func accessRequests(status: AccessRequestStatus?) throws -> [AccessRequest] {
        let rows = try db.read { db in
            if let status {
                return try Row.fetchAll(db, sql: "SELECT * FROM access_requests WHERE status = ? ORDER BY created_at", arguments: [status.rawValue])
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM access_requests ORDER BY created_at")
        }
        return try rows.map(accessRequest(from:))
    }

    public func deleteAccessRequest(_ id: String) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM access_requests WHERE id = ?", arguments: [id]) }
    }

    private func accessRequest(from row: Row) throws -> AccessRequest {
        var r = AccessRequest(
            id: row["id"],
            status: AccessRequestStatus(rawValue: row["status"]) ?? .pending,
            name: row["name"],
            description: row["description"],
            scopes: try decode([Scope].self, row["scopes"]),
            requestedChats: try (row["requested_chats"] as String?).map { try decode([Int64].self, $0) },
            webhookUrl: row["webhook_url"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"])
        )
        r.resolvedAt = Store.date(row["resolved_at"])
        r.deniedReason = row["denied_reason"]
        r.grantId = row["grant_id"]
        r.issuedToken = row["issued_token"]
        r.issuedWebhookSecret = row["issued_webhook_secret"]
        return r
    }

    // MARK: Grants

    public func insertGrant(_ grant: Grant) throws {
        try writeGrant(grant, insert: true)
    }

    public func updateGrant(_ grant: Grant) throws {
        try writeGrant(grant, insert: false)
    }

    private func writeGrant(_ g: Grant, insert: Bool) throws {
        let scopes = try encode(g.scopes)
        let mode: String
        let chatIds: String
        let folderId: Int64?
        switch g.chats {
        case .list(let ids):
            mode = "list"
            chatIds = try encode(ids)
            folderId = nil
        case .folder(let id):
            mode = "folder"
            chatIds = "[]"
            folderId = id
        }
        let w = g.webhook
        let arguments: StatementArguments = [
            g.name, g.description, scopes, mode, chatIds, folderId, g.tokenHash,
            w?.url, w?.secret, w?.state.rawValue, w?.cursorSeq, Store.seconds(w?.lastDeliveryAt), w?.lastError,
            Store.seconds(w?.pausedAt), Store.seconds(w?.failingSince),
            g.createdAt.timeIntervalSince1970, Store.seconds(g.lastSeenAt), Store.seconds(g.revokedAt), g.id,
        ]
        try db.write { db in
            if insert {
                try db.execute(sql: """
                    INSERT INTO grants (name, description, scopes, chat_mode, chat_ids, folder_id, token_hash,
                        webhook_url, webhook_secret, webhook_state, webhook_cursor_seq, webhook_last_delivery_at,
                        webhook_last_error, webhook_paused_at, webhook_failing_since, created_at, last_seen_at, revoked_at, id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: arguments)
            } else {
                try db.execute(sql: """
                    UPDATE grants SET name = ?, description = ?, scopes = ?, chat_mode = ?, chat_ids = ?, folder_id = ?,
                        token_hash = ?, webhook_url = ?, webhook_secret = ?, webhook_state = ?, webhook_cursor_seq = ?,
                        webhook_last_delivery_at = ?, webhook_last_error = ?, webhook_paused_at = ?, webhook_failing_since = ?,
                        created_at = ?, last_seen_at = ?, revoked_at = ?
                    WHERE id = ?
                    """, arguments: arguments)
            }
        }
    }

    public func grant(_ id: String) throws -> Grant? {
        let row = try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM grants WHERE id = ?", arguments: [id]) }
        return try row.map(grant(from:))
    }

    public func grant(tokenHash: String) throws -> Grant? {
        let row = try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM grants WHERE token_hash = ?", arguments: [tokenHash]) }
        return try row.map(grant(from:))
    }

    public func grants(includeRevoked: Bool) throws -> [Grant] {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: includeRevoked
                ? "SELECT * FROM grants ORDER BY created_at"
                : "SELECT * FROM grants WHERE revoked_at IS NULL ORDER BY created_at")
        }
        return try rows.map(grant(from:))
    }

    public func touchGrant(_ id: String, lastSeenAt: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE grants SET last_seen_at = ? WHERE id = ?", arguments: [lastSeenAt.timeIntervalSince1970, id])
        }
    }

    /// Revoked grants are kept 30 days for the activity view (docs/api.md), then deleted.
    public func deleteGrants(revokedBefore date: Date) throws -> Int {
        try db.write { db in
            try db.execute(sql: "DELETE FROM grants WHERE revoked_at IS NOT NULL AND revoked_at < ?", arguments: [date.timeIntervalSince1970])
            return db.changesCount
        }
    }

    private func grant(from row: Row) throws -> Grant {
        let chats: GrantChats
        if (row["chat_mode"] as String) == "folder" {
            chats = .folder(id: row["folder_id"] ?? 0)
        } else {
            chats = .list(try decode([Int64].self, row["chat_ids"]))
        }
        var webhook: Webhook?
        if let url: String = row["webhook_url"], let secret: String = row["webhook_secret"] {
            var w = Webhook(url: url, secret: secret, state: WebhookState(rawValue: row["webhook_state"] ?? "") ?? .active, cursorSeq: row["webhook_cursor_seq"] ?? 0)
            w.lastDeliveryAt = Store.date(row["webhook_last_delivery_at"])
            w.lastError = row["webhook_last_error"]
            w.pausedAt = Store.date(row["webhook_paused_at"])
            w.failingSince = Store.date(row["webhook_failing_since"])
            webhook = w
        }
        return Grant(
            id: row["id"],
            name: row["name"],
            description: row["description"],
            scopes: try decode([Scope].self, row["scopes"]),
            chats: chats,
            tokenHash: row["token_hash"],
            webhook: webhook,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            lastSeenAt: Store.date(row["last_seen_at"]),
            revokedAt: Store.date(row["revoked_at"])
        )
    }

    // MARK: Deliveries

    public func insertDelivery(_ d: Delivery) throws {
        let seqs = try encode(d.seqs)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO deliveries (id, grant_id, seqs, first_seq, last_seq, attempt, status, http_status, error, sent_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    d.id, d.grantId, seqs, d.firstSeq, d.lastSeq, d.attempt, d.status.rawValue, d.httpStatus, d.error,
                    d.sentAt.timeIntervalSince1970, Store.seconds(d.completedAt),
                ])
        }
    }

    public func updateDelivery(_ d: Delivery) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE deliveries SET attempt = ?, status = ?, http_status = ?, error = ?, sent_at = ?, completed_at = ? WHERE id = ?
                """, arguments: [d.attempt, d.status.rawValue, d.httpStatus, d.error, d.sentAt.timeIntervalSince1970, Store.seconds(d.completedAt), d.id])
        }
    }

    /// Newest first. Returns `limit + 1` rows at most.
    public func deliveries(grantId: String, limit: Int) throws -> [Delivery] {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM deliveries WHERE grant_id = ? ORDER BY sent_at DESC, id DESC LIMIT ?", arguments: [grantId, limit])
        }
        return try rows.map(delivery(from:))
    }

    /// The delivery whose result is unknown (daemon stopped mid-flight), if any.
    public func inFlightDelivery(grantId: String) throws -> Delivery? {
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM deliveries WHERE grant_id = ? AND status = 'in_flight' ORDER BY sent_at DESC LIMIT 1", arguments: [grantId])
        }
        return try row.map(delivery(from:))
    }

    public func deleteDeliveries(grantId: String) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM deliveries WHERE grant_id = ?", arguments: [grantId]) }
    }

    /// Successful deliveries' event counts since `date`, per grant (admin stats).
    public func eventsDelivered(grantId: String, since date: Date) throws -> Int64 {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT seqs FROM deliveries WHERE grant_id = ? AND status = 'succeeded' AND completed_at > ?", arguments: [grantId, date.timeIntervalSince1970])
        }
        return try rows.reduce(0) { $0 + Int64(try decode([Int64].self, $1["seqs"]).count) }
    }

    private func delivery(from row: Row) throws -> Delivery {
        Delivery(
            id: row["id"],
            grantId: row["grant_id"],
            seqs: try decode([Int64].self, row["seqs"]),
            attempt: row["attempt"],
            status: DeliveryStatus(rawValue: row["status"]) ?? .failed,
            httpStatus: row["http_status"],
            error: row["error"],
            sentAt: Date(timeIntervalSince1970: row["sent_at"]),
            completedAt: Store.date(row["completed_at"])
        )
    }

    // MARK: Media index

    /// Records a media object and the chat it was seen in. The media row is updated with the
    /// latest metadata; cache state is preserved.
    public func recordMedia(_ record: MediaRecord, chatId: Int64) throws {
        let m = record.media
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO media (media_id, remote_id, unique_id, kind, mime, size, width, height, duration_seconds, file_name)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id) DO UPDATE SET remote_id = excluded.remote_id, kind = excluded.kind, mime = excluded.mime,
                    size = excluded.size, width = excluded.width, height = excluded.height,
                    duration_seconds = excluded.duration_seconds, file_name = excluded.file_name
                """, arguments: [m.mediaId, record.remoteId, record.uniqueId, m.kind.rawValue, m.mime, m.size, m.width, m.height, m.durationSeconds, m.fileName])
            try db.execute(sql: "INSERT OR IGNORE INTO media_refs (media_id, chat_id) VALUES (?, ?)", arguments: [m.mediaId, chatId])
        }
    }

    public func media(_ mediaId: String) throws -> MediaRecord? {
        let row = try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM media WHERE media_id = ?", arguments: [mediaId]) }
        return row.map(Store.mediaRecord)
    }

    public func mediaChatIds(_ mediaId: String) throws -> Set<Int64> {
        Set(try db.read { db in try Int64.fetchAll(db, sql: "SELECT chat_id FROM media_refs WHERE media_id = ?", arguments: [mediaId]) })
    }

    public func setMediaCached(_ mediaId: String, localPath: String?, bytes: Int64, servedAt: Date?) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE media SET local_path = ?, cached_bytes = ?, last_served_at = COALESCE(?, last_served_at) WHERE media_id = ?", arguments: [localPath, bytes, Store.seconds(servedAt), mediaId])
        }
    }

    public func setMediaServed(_ mediaId: String, at date: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE media SET last_served_at = ? WHERE media_id = ?", arguments: [date.timeIntervalSince1970, mediaId])
        }
    }

    public func cachedMediaBytes() throws -> Int64 {
        try db.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(cached_bytes), 0) FROM media") ?? 0 }
    }

    /// Cached files, least recently served first.
    public func cachedMedia() throws -> [MediaRecord] {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM media WHERE local_path IS NOT NULL ORDER BY COALESCE(last_served_at, 0), media_id")
        }
        return rows.map(Store.mediaRecord)
    }

    private static func mediaRecord(_ row: Row) -> MediaRecord {
        MediaRecord(
            media: Media(
                mediaId: row["media_id"], kind: MediaKind(rawValue: row["kind"]) ?? .document, mime: row["mime"],
                size: row["size"], width: row["width"], height: row["height"], durationSeconds: row["duration_seconds"],
                fileName: row["file_name"]
            ),
            remoteId: row["remote_id"],
            uniqueId: row["unique_id"],
            localPath: row["local_path"],
            cachedBytes: row["cached_bytes"],
            lastServedAt: Store.date(row["last_served_at"])
        )
    }
}

/// What the `events.payload` column holds: the chat summary plus the type-specific payload.
/// The envelope fields (`seq`, type, timestamps) are columns of their own.
private struct StoredPayload: Codable {
    var chat: ChatSummary
    var payload: EventPayload
}
