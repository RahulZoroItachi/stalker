import Foundation
import SQLite3

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case sql(String)
    case missingId

    public var description: String {
        switch self {
        case .open(let m):  return "cannot open database: \(m)"
        case .sql(let m):   return "sql error: \(m)"
        case .missingId:    return "cannot update an interval that has no id"
        }
    }
}

/// SQLite tells us to copy bound strings rather than borrow them.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The archive. Append-only in spirit: rows are inserted when an interval opens
/// and updated in place while it stays open. The sampler is the only writer,
/// which is why no busy-timeout or retry logic is needed. Spec §4, §6.
public final class Store {
    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=3000;")
    }

    deinit { if let db { sqlite3_close(db) } }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    public func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS interval (
          id           INTEGER PRIMARY KEY,
          kind         TEXT    NOT NULL,
          started_at   INTEGER NOT NULL,
          ended_at     INTEGER NOT NULL,
          bundle_id    TEXT,
          app_name     TEXT,
          context_kind TEXT,
          context      TEXT,
          title        TEXT,
          samples      INTEGER NOT NULL,
          active       INTEGER NOT NULL,
          engaged      INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ix_interval_time ON interval(started_at);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');
        """)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.sql(msg)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, i) }
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    public func insert(_ iv: Interval) throws -> Int64 {
        let stmt = try prepare("""
        INSERT INTO interval
          (kind, started_at, ended_at, bundle_id, app_name, context_kind, context, title,
           samples, active, engaged)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11);
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, iv.kind.rawValue)
        sqlite3_bind_int64(stmt, 2, Int64(iv.startedAt))
        sqlite3_bind_int64(stmt, 3, Int64(iv.endedAt))
        bind(stmt, 4, iv.bundleId)
        bind(stmt, 5, iv.appName)
        bind(stmt, 6, iv.contextKind?.rawValue)
        bind(stmt, 7, iv.context)
        bind(stmt, 8, iv.title)
        sqlite3_bind_int64(stmt, 9, Int64(iv.samples))
        sqlite3_bind_int64(stmt, 10, Int64(iv.active))
        sqlite3_bind_int64(stmt, 11, Int64(iv.engaged))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func update(_ iv: Interval) throws {
        guard let id = iv.id else { throw StoreError.missingId }
        let stmt = try prepare("""
        UPDATE interval SET ended_at=?1, title=?2, samples=?3, active=?4, engaged=?5
        WHERE id=?6;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(iv.endedAt))
        bind(stmt, 2, iv.title)
        sqlite3_bind_int64(stmt, 3, Int64(iv.samples))
        sqlite3_bind_int64(stmt, 4, Int64(iv.active))
        sqlite3_bind_int64(stmt, 5, Int64(iv.engaged))
        sqlite3_bind_int64(stmt, 6, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func row(_ stmt: OpaquePointer?) -> Interval {
        Interval(
            id: sqlite3_column_int64(stmt, 0),
            kind: Kind(rawValue: text(stmt, 1) ?? "gap") ?? .gap,
            startedAt: Int(sqlite3_column_int64(stmt, 2)),
            endedAt: Int(sqlite3_column_int64(stmt, 3)),
            bundleId: text(stmt, 4),
            appName: text(stmt, 5),
            contextKind: text(stmt, 6).flatMap(ContextKind.init(rawValue:)),
            context: text(stmt, 7),
            title: text(stmt, 8),
            samples: Int(sqlite3_column_int64(stmt, 9)),
            active: Int(sqlite3_column_int64(stmt, 10)),
            engaged: Int(sqlite3_column_int64(stmt, 11))
        )
    }

    private static let selectColumns =
        "id, kind, started_at, ended_at, bundle_id, app_name, context_kind, context, title, samples, active, engaged"

    /// Most recently started interval — the one the sampler may still be extending.
    public func lastInterval() throws -> Interval? {
        let stmt = try prepare("SELECT \(Store.selectColumns) FROM interval ORDER BY started_at DESC, id DESC LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? row(stmt) : nil
    }

    /// All intervals overlapping [from, to).
    public func intervals(from: Int, to: Int) throws -> [Interval] {
        let stmt = try prepare("""
        SELECT \(Store.selectColumns) FROM interval
        WHERE ended_at > ?1 AND started_at < ?2
        ORDER BY started_at ASC, id ASC;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(from))
        sqlite3_bind_int64(stmt, 2, Int64(to))
        var out: [Interval] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }
}
