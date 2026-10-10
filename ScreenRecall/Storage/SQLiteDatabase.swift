import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case sqlite(Int32, String)
    case unsupportedVersion(Int32)

    var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message): "SQLite \(code): \(message)"
        case .unsupportedVersion(let version): "数据库版本 \(version) 高于当前应用支持的版本"
        }
    }
}

enum SQLValue {
    case integer(Int64), real(Double), text(String), null
}

/// 只由 PersistentCaptureSink actor 持有；所有调用都在其串行隔离内执行。
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let pointer { sqlite3_close(pointer) }
            throw DatabaseError.sqlite(result, message)
        }
        handle = pointer
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA busy_timeout = 3000")
            try migrate()
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(result) }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error(result) }
            rows.append(try map(statement))
        }
        return rows
    }

    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        try query(sql, values) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func changes() -> Int32 { sqlite3_changes(handle) }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error(result) }
        do {
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                let code: Int32
                switch value {
                case .integer(let number): code = sqlite3_bind_int64(statement, position, number)
                case .real(let number): code = sqlite3_bind_double(statement, position, number)
                case .text(let string):
                    code = string.withCString { sqlite3_bind_text(statement, position, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                case .null: code = sqlite3_bind_null(statement, position)
                }
                guard code == SQLITE_OK else { throw error(code) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func error(_ code: Int32) -> DatabaseError {
        DatabaseError.sqlite(code, String(cString: sqlite3_errmsg(handle)))
    }

    private func migrate() throws {
        let version = Int32(try scalarInt("PRAGMA user_version"))
        guard version <= 2 else { throw DatabaseError.unsupportedVersion(version) }
        if version == 0 { try transaction {
            try execute("""
                CREATE TABLE settings (
                  id INTEGER PRIMARY KEY CHECK(id = 1),
                  epoch INTEGER NOT NULL DEFAULT 0,
                  total_bytes INTEGER NOT NULL DEFAULT 0 CHECK(total_bytes >= 0)
                )
                """)
            try execute("INSERT INTO settings(id) VALUES(1)")
            try execute("""
                CREATE TABLE batches (
                  id TEXT PRIMARY KEY,
                  scheduled_at REAL NOT NULL,
                  started_at REAL NOT NULL,
                  ended_at REAL,
                  expected_count INTEGER NOT NULL CHECK(expected_count >= 0),
                  success_count INTEGER NOT NULL DEFAULT 0 CHECK(success_count >= 0),
                  status TEXT NOT NULL CHECK(status IN ('capturing','complete','partial','failed','skipped','interrupted','deleting')),
                  error_summary TEXT,
                  epoch INTEGER NOT NULL,
                  generation INTEGER NOT NULL
                )
                """)
            try execute("CREATE INDEX batches_time_desc ON batches(started_at DESC, id DESC)")
            try execute("CREATE INDEX batches_time_asc ON batches(started_at ASC, id ASC)")
            try execute("CREATE INDEX batches_status ON batches(status, started_at)")
            try execute("""
                CREATE TABLE frames (
                  batch_id TEXT NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
                  display_order INTEGER NOT NULL,
                  display_id INTEGER NOT NULL,
                  pixel_width INTEGER NOT NULL,
                  pixel_height INTEGER NOT NULL,
                  point_pixel_scale REAL NOT NULL,
                  capture_started_at REAL,
                  capture_ended_at REAL,
                  status TEXT NOT NULL CHECK(status IN ('pending','success','failed','interrupted')),
                  error TEXT,
                  asset_id TEXT UNIQUE,
                  PRIMARY KEY(batch_id, display_order)
                )
                """)
            try execute("CREATE INDEX frames_by_batch ON frames(batch_id, display_order)")
            try execute("""
                CREATE TABLE assets (
                  id TEXT PRIMARY KEY,
                  batch_id TEXT NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
                  display_order INTEGER NOT NULL,
                  relative_path TEXT NOT NULL UNIQUE,
                  staging_path TEXT NOT NULL,
                  format TEXT NOT NULL,
                  byte_count INTEGER NOT NULL CHECK(byte_count > 0),
                  pixel_width INTEGER NOT NULL CHECK(pixel_width > 0),
                  pixel_height INTEGER NOT NULL CHECK(pixel_height > 0),
                  encoding_version INTEGER NOT NULL,
                  created_at REAL NOT NULL,
                  capture_started_at REAL NOT NULL,
                  capture_ended_at REAL NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('staging','ready','deleting','missing')),
                  accounted INTEGER NOT NULL DEFAULT 0 CHECK(accounted IN (0,1)),
                  epoch INTEGER NOT NULL
                )
                """)
            try execute("CREATE INDEX assets_state ON assets(state, created_at)")
            try execute("CREATE INDEX assets_batch ON assets(batch_id, display_order)")
            try execute("PRAGMA user_version = 1")
        } }
        if version <= 1 { try transaction {
            try execute("ALTER TABLE frames ADD COLUMN layout_x REAL NOT NULL DEFAULT 0")
            try execute("ALTER TABLE frames ADD COLUMN layout_y REAL NOT NULL DEFAULT 0")
            try execute("ALTER TABLE frames ADD COLUMN layout_width REAL NOT NULL DEFAULT 0")
            try execute("ALTER TABLE frames ADD COLUMN layout_height REAL NOT NULL DEFAULT 0")
            try execute("ALTER TABLE frames ADD COLUMN is_mirrored INTEGER NOT NULL DEFAULT 0 CHECK(is_mirrored IN (0,1))")
            try execute("PRAGMA user_version = 2")
        } }
    }
}
