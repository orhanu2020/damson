import Foundation
import DamsonSupport
import DamsonProviders

// MARK: - Helpers

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ more: Data) {
        lock.lock()
        data.append(more)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PathUtil {
    public static func resolve(_ path: String, base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    public static func isInside(_ url: URL, directory: URL) -> Bool {
        let dir = directory.resolvingSymlinksInPath().standardizedFileURL.path
        // Resolve symlinks on the deepest existing ancestor so a link cannot escape the directory.
        var probe = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            tail.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        var resolved = probe.resolvingSymlinksInPath()
        for part in tail { resolved = resolved.appendingPathComponent(part) }
        let path = resolved.standardizedFileURL.path
        return path == dir || path.hasPrefix(dir + "/")
    }
}

/// Runs a process and returns merged stdout/stderr plus the exit status.
func runProcess(executable: String, arguments: [String], cwd: URL, timeout: TimeInterval, environment: [String: String]) async throws -> (output: String, status: Int32, timedOut: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    let buffer = LockedData()
    let timedOutFlag = Locked<Bool>(false)

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { buffer.append(chunk) }
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(output: String, status: Int32, timedOut: Bool), Error>) in
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            buffer.append(rest)
            continuation.resume(returning: (buffer.string, p.terminationStatus, timedOutFlag.current))
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(throwing: error)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOutFlag.withLock { $0 = true }
                process.terminate()
            }
        }
    }
}

func sanitizedEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    for (k, v) in ProcessInfo.processInfo.environment {
        let upper = k.uppercased()
        if upper.contains("KEY") || upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD") { continue }
        env[k] = v
    }
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
    return env
}

// MARK: - Shell

public struct ShellTool: Tool {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public var spec: ToolSpec {
        ToolSpec(name: "shell",
                 description: "Run a shell command on the user's Mac (zsh). Read-only commands (ls, cat, grep, git status, ...) run immediately. Anything that could change files, settings or accounts requires the user's approval. Commands start in the user's workspace folder.",
                 inputSchema: JSONValue.schema([("command", "string", "The shell command to run")], required: ["command"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        guard let command = input.string("command") else { return .change }
        return ShellClassifier.classify(command)
    }

    public func describe(_ input: JSONValue) -> String {
        return "Run shell command: \(input.string("command") ?? "(none)")"
    }

    public func grantKey(_ input: JSONValue) -> String {
        let first = (input.string("command") ?? "").split(separator: " ").first.map(String.init) ?? ""
        return "shell:\(first)"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let command = input.string("command"), !command.isEmpty else {
            throw ToolError.invalidInput("command is required")
        }
        let result = try await runProcess(executable: "/bin/zsh", arguments: ["-c", command],
                                          cwd: context.baseDir, timeout: timeout, environment: sanitizedEnvironment())
        var out = result.output
        if result.timedOut { out += "\n[command timed out after \(Int(timeout))s and was stopped]" }
        if result.status != 0 { out += "\n[exit status \(result.status)]" }
        return out.isEmpty ? "(no output)" : out
    }
}

// MARK: - Files

public struct ReadFileTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "read_file",
                 description: "Read a text file (up to ~200 KB). Relative paths resolve inside the workspace folder; ~ expands to the home folder.",
                 inputSchema: JSONValue.schema([("path", "string", "File path")], required: ["path"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        guard let path = input.string("path") else { return .change }
        return ShellClassifier.isSensitivePath(path) ? .change : .observe
    }

    public func describe(_ input: JSONValue) -> String {
        return "Read file: \(input.string("path") ?? "(none)")"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let path = input.string("path") else { throw ToolError.invalidInput("path is required") }
        let url = PathUtil.resolve(path, base: context.baseDir)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 200_000) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.failed("File is not UTF-8 text")
        }
        return text
    }
}

public struct ListDirTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "list_dir",
                 description: "List the entries of a directory (names, types, sizes).",
                 inputSchema: JSONValue.schema([("path", "string", "Directory path")], required: ["path"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        guard let path = input.string("path") else { return .change }
        return ShellClassifier.isSensitivePath(path) ? .change : .observe
    }

    public func describe(_ input: JSONValue) -> String {
        return "List directory: \(input.string("path") ?? "(none)")"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let path = input.string("path") else { throw ToolError.invalidInput("path is required") }
        let url = PathUtil.resolve(path, base: context.baseDir)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        var lines: [String] = []
        for name in names.prefix(500) {
            let full = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
            let attrs = try? FileManager.default.attributesOfItem(atPath: full.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            lines.append(isDir.boolValue ? "\(name)/" : "\(name)  (\(size) bytes)")
        }
        if names.count > 500 { lines.append("[... \(names.count - 500) more entries]") }
        return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
    }
}

public struct WriteFileTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "write_file",
                 description: "Create or overwrite a text file. Writing inside the task scratch folder (the default for relative paths) is free; writing anywhere else needs the user's approval.",
                 inputSchema: JSONValue.schema([("path", "string", "File path"), ("content", "string", "Full file contents")],
                                               required: ["path", "content"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        guard let path = input.string("path") else { return .change }
        let url = PathUtil.resolve(path, base: context.baseDir)
        return PathUtil.isInside(url, directory: context.scratchDir) ? .observe : .change
    }

    public func describe(_ input: JSONValue) -> String {
        let content = input.string("content") ?? ""
        return "Write \(content.count) characters to file: \(input.string("path") ?? "(none)")"
    }

    public func grantKey(_ input: JSONValue) -> String {
        let path = (input.string("path") ?? "") as NSString
        return "write_file:\(path.deletingLastPathComponent)"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let path = input.string("path"), let content = input.string("content") else {
            throw ToolError.invalidInput("path and content are required")
        }
        let url = PathUtil.resolve(path, base: context.baseDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) characters to \(url.path)"
    }
}

// MARK: - Web fetch

public struct WebFetchTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "web_fetch",
                 description: "HTTP GET a public web page and return its text (HTML tags removed). For pages needing JavaScript use the browser_* tools.",
                 inputSchema: JSONValue.schema([("url", "string", "http(s) URL")], required: ["url"]))
    }

    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") { return true }
        if h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") || h == "0.0.0.0" || h == "::1" { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    /// Public http(s) URLs of reasonable length are Observe. Local-network targets, odd schemes and
    /// very long URLs (which could smuggle data out) need approval.
    public static func classifyURL(_ text: String?) -> ActionClass {
        guard let text = text, text.count <= 400, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !isLocalHost(host), url.user == nil else { return .change }
        return .observe
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        return Self.classifyURL(input.string("url"))
    }

    public func describe(_ input: JSONValue) -> String {
        return "Fetch web page: \(input.string("url") ?? "(none)")"
    }

    static func htmlToText(_ html: String) -> String {
        var text = html
        let patterns = ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->", "<[^>]+>"]
        for p in patterns {
            text = text.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let urlString = input.string("url"), let url = URL(string: urlString) else {
            throw ToolError.invalidInput("a valid url is required")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh) Damson/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(1_500_000), as: UTF8.self)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let text = contentType.contains("html") ? Self.htmlToText(body) : body
        return "HTTP \(status)\n" + text
    }
}
