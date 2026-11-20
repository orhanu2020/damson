import Foundation
import Security
import DamsonSupport

public struct StoredEvent: Sendable {
    public let seq: Int64
    public let taskID: String?
    public let type: String
    public let payload: String
    public let at: Date
}

public struct StoredMessage: Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let source: String
    public let at: Date
}

public struct UsageTotals: Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
}

/// Persistence for an append-only event log (audit trail),
/// conversation messages and token usage. Secrets never go here.
public final class DamsonStore: @unchecked Sendable {
    public let db: Database

    public init(path: String? = nil) throws {
        let location = path ?? AppPaths.databaseURL.path
        db = try Database(path: location)
        try migrate()
    }

    public static func inMemory() throws -> DamsonStore {
        return try DamsonStore(path: ":memory:")
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT,
            type TEXT NOT NULL,
            payload TEXT NOT NULL,
            at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_task ON events(task_id);
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            source TEXT NOT NULL,
            at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT,
            role TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tokens_in INTEGER NOT NULL,
            tokens_out INTEGER NOT NULL,
            at REAL NOT NULL
        );
        """)
    }

    // MARK: Events (audit log)

    @discardableResult
    public func appendEvent(taskID: String?, type: String, payload: String) throws -> Int64 {
        return try db.run("INSERT INTO events (task_id, type, payload, at) VALUES (?, ?, ?, ?)",
                          [taskID.map { DBValue.text($0) } ?? DBValue.null,
                           .text(type), .text(payload), .double(Date().timeIntervalSince1970)])
    }

    public func events(taskID: String?, limit: Int = 500) throws -> [StoredEvent] {
        let rows: [[String: DBValue]]
        if let taskID = taskID {
            rows = try db.query("SELECT * FROM events WHERE task_id = ? ORDER BY seq ASC LIMIT ?", [.text(taskID), .int(Int64(limit))])
        } else {
            rows = try db.query("SELECT * FROM events ORDER BY seq DESC LIMIT ?", [.int(Int64(limit))])
        }
        return rows.map { row in
            StoredEvent(seq: row["seq"]?.intValue ?? 0,
                        taskID: row["task_id"]?.textValue,
                        type: row["type"]?.textValue ?? "",
                        payload: row["payload"]?.textValue ?? "",
                        at: Date(timeIntervalSince1970: row["at"]?.doubleValue ?? 0))
        }
    }

    // MARK: Conversation

    public func saveMessage(id: String, role: String, text: String, source: String) throws {
        try db.run("INSERT OR REPLACE INTO messages (id, role, text, source, at) VALUES (?, ?, ?, ?, ?)",
                   [.text(id), .text(role), .text(text), .text(source), .double(Date().timeIntervalSince1970)])
    }

    public func recentMessages(limit: Int = 100) throws -> [StoredMessage] {
        let rows = try db.query("SELECT * FROM messages ORDER BY at DESC LIMIT ?", [.int(Int64(limit))])
        let mapped = rows.map { row in
            StoredMessage(id: row["id"]?.textValue ?? "",
                          role: row["role"]?.textValue ?? "",
                          text: row["text"]?.textValue ?? "",
                          source: row["source"]?.textValue ?? "",
                          at: Date(timeIntervalSince1970: row["at"]?.doubleValue ?? 0))
        }
        return mapped.reversed()
    }

    // MARK: Usage

    public func recordUsage(taskID: String?, role: String, provider: String, model: String, tokensIn: Int, tokensOut: Int) throws {
        try db.run("INSERT INTO usage (task_id, role, provider, model, tokens_in, tokens_out, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [taskID.map { DBValue.text($0) } ?? DBValue.null,
                    .text(role), .text(provider), .text(model),
                    .int(Int64(tokensIn)), .int(Int64(tokensOut)), .double(Date().timeIntervalSince1970)])
    }

    public func usageTotals(taskID: String?) throws -> UsageTotals {
        let rows: [[String: DBValue]]
        if let taskID = taskID {
            rows = try db.query("SELECT COALESCE(SUM(tokens_in),0) AS i, COALESCE(SUM(tokens_out),0) AS o FROM usage WHERE task_id = ?", [.text(taskID)])
        } else {
            rows = try db.query("SELECT COALESCE(SUM(tokens_in),0) AS i, COALESCE(SUM(tokens_out),0) AS o FROM usage")
        }
        let row = rows.first ?? [:]
        return UsageTotals(inputTokens: Int(row["i"]?.intValue ?? 0), outputTokens: Int(row["o"]?.intValue ?? 0))
    }
}
