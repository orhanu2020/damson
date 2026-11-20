import Foundation

/// A tiny lock-protected box. Use instead of raw NSLock inside async code.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    public var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Well-known locations used by Damson.
public enum AppPaths {
    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static var databaseURL: URL {
        supportDir.appendingPathComponent("damson.sqlite")
    }

    public static var mcpConfigURL: URL {
        supportDir.appendingPathComponent("mcp.json")
    }

    /// Per-task scratch directory. Helpers may write here without approval.
    public static func scratchDir(taskID: String) -> URL {
        let dir = supportDir
            .appendingPathComponent("scratch", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public extension String {
    /// Truncates to `limit` characters, appending a note about how much was cut.
    func truncated(to limit: Int) -> String {
        if count <= limit { return self }
        let cut = count - limit
        return String(prefix(limit)) + "\n[...truncated \(cut) characters]"
    }
}

/// Optional diagnostics file. Off unless a path is set in Settings. Never logs API keys.
public enum DebugLog {
    private static let path = Locked<String?>(nil)

    public static func setPath(_ newPath: String?) {
        let trimmed = (newPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        path.withLock { (p: inout String?) in
            p = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        }
    }

    public static var isEnabled: Bool { path.current != nil }

    public static func write(_ message: @autoclosure () -> String) {
        guard let file = path.current else { return }
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message() + "\n"
        if let handle = FileHandle(forWritingAtPath: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: file, atomically: false, encoding: .utf8)
        }
    }
}
