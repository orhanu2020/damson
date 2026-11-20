import Foundation
import SQLite3

public enum DBValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

public enum DBError: Error, LocalizedError {
    case open(String)
    case sql(String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open database: \(m)"
        case .sql(let m): return "Database error: \(m)"
        }
    }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal serialized SQLite wrapper (system sqlite3, no external dependencies).
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(path: String) throws {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DBError.open(message)
        }
        self.handle = db
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    private func errorMessage() -> String {
        guard let handle = handle else { return "closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    public func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(err)
            throw DBError.sql(message)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [DBValue]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        }
    }

    /// Runs INSERT/UPDATE/DELETE. Returns the last inserted row id.
    @discardableResult
    public func run(_ sql: String, _ params: [DBValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sql(errorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.sql(errorMessage())
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ params: [DBValue] = []) throws -> [[String: DBValue]] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sql(errorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)

        var rows: [[String: DBValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.sql(errorMessage()) }
            var row: [String: DBValue] = [:]
            let count = sqlite3_column_count(stmt)
            for c in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT:
                    row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT:
                    if let cstr = sqlite3_column_text(stmt, c) {
                        row[name] = .text(String(cString: cstr))
                    } else {
                        row[name] = .null
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
