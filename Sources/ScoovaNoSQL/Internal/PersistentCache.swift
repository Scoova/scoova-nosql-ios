//
//  PersistentCache.swift
//  ScoovaNoSQL
//
//  Local SQLite-backed cache to match Firestore's offline-first semantics:
//  every read goes through the cache first (instant), every write hits the
//  cache before the network so the UI sees the change immediately, and any
//  write that fails the network round-trip gets persisted in the pending-
//  writes queue and replayed once connectivity returns.
//

import Foundation
import SQLite3

/// Thread-safe SQLite wrapper. The whole DB is a single file at
/// `~/Library/Caches/ScoovaNoSQL/{projectId}_{databaseId}.sqlite`. All
/// queries serialize through `queue` so we don't have to maintain a
/// connection pool — at this access pattern (a handful of small writes
/// per UI event) the simplicity is worth the perf trade.
final class PersistentCache: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: String
    private let queue = DispatchQueue(label: "scoova.nosql.cache", qos: .userInitiated)

    init(projectId: String, databaseId: String) throws {
        let fm = FileManager.default
        let base = try fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("ScoovaNoSQL", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeProject = projectId.replacingOccurrences(of: "/", with: "_")
        let safeDb = databaseId.replacingOccurrences(of: "/", with: "_")
        self.path = base
            .appendingPathComponent("\(safeProject)_\(safeDb).sqlite")
            .path
        try open()
        try migrate()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    private func open() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw ScoovaNoSQLError.network("cache open failed: \(msg)")
        }
        // WAL mode for concurrent readers + faster writes
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS documents (
            collection TEXT NOT NULL,
            doc_id     TEXT NOT NULL,
            data       TEXT NOT NULL,
            updated_at REAL NOT NULL,
            cached_at  REAL NOT NULL,
            tombstone  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (collection, doc_id)
        );
        CREATE INDEX IF NOT EXISTS idx_documents_collection
            ON documents(collection, tombstone);

        -- Query result indexes — for `getDocuments` we need ordering by
        -- the result that the server returned, but we want the underlying
        -- doc rows shared with point lookups. Sequence preserves insert
        -- order from the last successful server fetch.
        CREATE TABLE IF NOT EXISTS query_results (
            query_hash TEXT NOT NULL,
            doc_id     TEXT NOT NULL,
            sequence   INTEGER NOT NULL,
            fetched_at REAL NOT NULL,
            PRIMARY KEY (query_hash, doc_id)
        );
        CREATE INDEX IF NOT EXISTS idx_query_results_seq
            ON query_results(query_hash, sequence);

        -- Writes that haven't been confirmed by the server yet. Replay
        -- order is by created_at ASC.
        CREATE TABLE IF NOT EXISTS pending_writes (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            op         TEXT NOT NULL,    -- 'set', 'update', 'delete'
            collection TEXT NOT NULL,
            doc_id     TEXT NOT NULL,
            merge      INTEGER NOT NULL DEFAULT 0,
            data       TEXT,             -- nil for delete
            created_at REAL NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_pending_writes_order
            ON pending_writes(created_at);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ScoovaNoSQLError.network("cache migrate failed: \(msg)")
        }
    }

    // MARK: - Documents

    /// Cached document data. Returns nil for tombstones (deleted docs).
    func document(collection: String, id: String) -> [String: Any]? {
        queue.sync {
            let sql = """
                SELECT data FROM documents
                 WHERE collection = ? AND doc_id = ? AND tombstone = 0
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let json = String(cString: sqlite3_column_text(stmt, 0))
            return deserialize(json)
        }
    }

    /// Replace the cached doc.
    func setDocument(collection: String, id: String, data: [String: Any]) {
        queue.sync {
            guard let json = serialize(data) else { return }
            let now = Date().timeIntervalSince1970
            let sql = """
                INSERT OR REPLACE INTO documents
                    (collection, doc_id, data, updated_at, cached_at, tombstone)
                VALUES (?, ?, ?, ?, ?, 0)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_bind_double(stmt, 5, now)
            _ = sqlite3_step(stmt)
        }
    }

    /// Merge fields into the cached doc. If no row exists, behaves as set.
    func mergeDocument(collection: String, id: String, data: [String: Any]) {
        queue.sync {
            let now = Date().timeIntervalSince1970
            // Read-merge-write under the lock so concurrent merges don't lose.
            let read = """
                SELECT data FROM documents
                 WHERE collection = ? AND doc_id = ?
            """
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, read, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            var existing: [String: Any] = [:]
            if sqlite3_step(stmt) == SQLITE_ROW {
                let json = String(cString: sqlite3_column_text(stmt, 0))
                existing = deserialize(json) ?? [:]
            }
            sqlite3_finalize(stmt)

            for (k, v) in data { existing[k] = v }
            guard let merged = serialize(existing) else { return }

            let write = """
                INSERT OR REPLACE INTO documents
                    (collection, doc_id, data, updated_at, cached_at, tombstone)
                VALUES (?, ?, ?, ?, ?, 0)
            """
            var ws: OpaquePointer?
            defer { sqlite3_finalize(ws) }
            sqlite3_prepare_v2(db, write, -1, &ws, nil)
            sqlite3_bind_text(ws, 1, collection, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ws, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ws, 3, merged, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(ws, 4, now)
            sqlite3_bind_double(ws, 5, now)
            _ = sqlite3_step(ws)
        }
    }

    /// Soft-delete (tombstone) so the doc reads as nil but query result
    /// indexes still know it existed (deletion will be re-fetched next sync).
    func deleteDocument(collection: String, id: String) {
        queue.sync {
            let sql = """
                UPDATE documents
                   SET tombstone = 1, data = '{}', updated_at = ?
                 WHERE collection = ? AND doc_id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, collection, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Query results

    /// Replace the cached document-id list for a given query (called on a
    /// successful server fetch). Doc bodies should be stored via
    /// `setDocument` per row first.
    func setQueryResults(_ queryHash: String, docIds: [String]) {
        queue.sync {
            let now = Date().timeIntervalSince1970
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            var del: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM query_results WHERE query_hash = ?", -1, &del, nil)
            sqlite3_bind_text(del, 1, queryHash, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(del)
            sqlite3_finalize(del)

            let ins = """
                INSERT INTO query_results (query_hash, doc_id, sequence, fetched_at)
                VALUES (?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, ins, -1, &stmt, nil)
            for (i, id) in docIds.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, queryHash, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, Int64(i))
                sqlite3_bind_double(stmt, 4, now)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    /// Return the cached document ids for a query (in original order),
    /// plus their bodies. Tombstoned rows are skipped.
    func queryResults(_ queryHash: String) -> [(id: String, data: [String: Any])] {
        queue.sync {
            let sql = """
                SELECT d.doc_id, d.data
                  FROM query_results q
                  JOIN documents d
                    ON q.doc_id = d.doc_id
                 WHERE q.query_hash = ?
                   AND d.tombstone = 0
                 ORDER BY q.sequence ASC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, queryHash, -1, SQLITE_TRANSIENT)
            var out: [(String, [String: Any])] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let json = String(cString: sqlite3_column_text(stmt, 1))
                if let data = deserialize(json) {
                    out.append((id, data))
                }
            }
            return out
        }
    }

    // MARK: - Pending writes

    struct PendingWrite {
        let id: Int64
        let op: String       // "set" | "update" | "delete"
        let collection: String
        let docId: String
        let merge: Bool
        let data: [String: Any]?
        let retryCount: Int
    }

    /// Enqueue a write that failed to reach the server (or was issued
    /// while offline). Returns the row id so callers can correlate retries.
    @discardableResult
    func enqueueWrite(
        op: String, collection: String, docId: String,
        merge: Bool, data: [String: Any]?
    ) -> Int64 {
        queue.sync {
            let sql = """
                INSERT INTO pending_writes
                    (op, collection, doc_id, merge, data, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, op, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, collection, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, docId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, merge ? 1 : 0)
            if let data, let json = serialize(data) {
                sqlite3_bind_text(stmt, 5, json, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            _ = sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func pendingWrites() -> [PendingWrite] {
        queue.sync {
            let sql = """
                SELECT id, op, collection, doc_id, merge, data, retry_count
                  FROM pending_writes
                 ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var out: [PendingWrite] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let op = String(cString: sqlite3_column_text(stmt, 1))
                let col = String(cString: sqlite3_column_text(stmt, 2))
                let doc = String(cString: sqlite3_column_text(stmt, 3))
                let merge = sqlite3_column_int(stmt, 4) != 0
                let dataPtr = sqlite3_column_text(stmt, 5)
                let data: [String: Any]? = dataPtr.map {
                    deserialize(String(cString: $0)) ?? [:]
                }
                let retry = Int(sqlite3_column_int(stmt, 6))
                out.append(PendingWrite(
                    id: id, op: op, collection: col, docId: doc,
                    merge: merge, data: data, retryCount: retry
                ))
            }
            return out
        }
    }

    func removePendingWrite(id: Int64) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "DELETE FROM pending_writes WHERE id = ?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
    }

    func recordPendingWriteFailure(id: Int64, error: String) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, """
                UPDATE pending_writes
                   SET retry_count = retry_count + 1, last_error = ?
                 WHERE id = ?
            """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, error, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Helpers

    /// Stable canonical hash of a query's filters/orders/limit so
    /// `getDocuments` calls that produce the same server-side result
    /// share a cache entry.
    static func hashQuery(
        collection: String,
        filters: [(field: String, op: String, value: String)],
        orders: [(field: String, descending: Bool)],
        limit: Int?
    ) -> String {
        var parts: [String] = ["col=\(collection)"]
        for f in filters {
            parts.append("w:\(f.field)|\(f.op)|\(f.value)")
        }
        for o in orders {
            parts.append("o:\(o.field)|\(o.descending ? "desc" : "asc")")
        }
        if let l = limit { parts.append("l:\(l)") }
        // Stable order — sort once filters / orders are stringified.
        // We don't sort filters/orders themselves because their order is
        // semantically meaningful (the server applies them in sequence).
        return parts.joined(separator: ";")
    }

    private func serialize(_ data: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(
            withJSONObject: data,
            options: [.fragmentsAllowed, .sortedKeys]
        ) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func deserialize(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return obj
    }
}

// SQLite's SQLITE_TRANSIENT constant isn't exposed in the Swift overlay;
// declare it locally so the bind_text calls above can copy the string.
private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)
