import Foundation
import DamsonSupport
import DamsonProviders

public struct MCPServerConfig: Codable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]?

    public init(name: String, command: String, args: [String] = [], env: [String: String]? = nil) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

struct MCPConfigFile: Codable {
    var servers: [MCPServerConfig]
}

public struct MCPToolInfo: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnlyHint: Bool
}

public enum MCPError: Error, LocalizedError {
    case notRunning
    case server(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "MCP server is not running"
        case .server(let m): return "MCP server error: \(m)"
        case .timeout: return "MCP server did not respond in time"
        }
    }
}

/// A minimal MCP client speaking JSON-RPC over a child process's stdio (newline-delimited).
public final class MCPServerConnection: @unchecked Sendable {
    public let config: MCPServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private let state = Locked<State>(State())

    private struct State {
        var nextID = 1
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var buffer = Data()
    }

    public init(config: MCPServerConfig) {
        self.config = config
    }

    public func start() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [config.command] + config.args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (k, v) in config.env ?? [:] { env[k] = v }
        p.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self?.receive(chunk)
        }
        p.terminationHandler = { [weak self] _ in
            self?.failAll(MCPError.notRunning)
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting

        let initResult = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Damson"), "version": .string("0.1")]),
        ]))
        _ = initResult
        try send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    private func failAll(_ error: Error) {
        let continuations = state.withLock { s -> [CheckedContinuation<JSONValue, Error>] in
            let all = Array(s.pending.values)
            s.pending.removeAll()
            return all
        }
        for c in continuations { c.resume(throwing: error) }
    }

    private func receive(_ chunk: Data) {
        var lines: [Data] = []
        state.withLock { s in
            s.buffer.append(chunk)
            while let idx = s.buffer.firstIndex(of: 0x0A) {
                lines.append(Data(s.buffer[s.buffer.startIndex..<idx]))
                s.buffer.removeSubrange(s.buffer.startIndex...idx)
            }
        }
        for line in lines where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let id = obj["id"] as? Int else { continue }   // notifications and server requests are ignored
            let continuation = state.withLock { s in s.pending.removeValue(forKey: id) }
            guard let c = continuation else { continue }
            if let err = obj["error"] as? [String: Any] {
                c.resume(throwing: MCPError.server(err["message"] as? String ?? "unknown"))
            } else {
                let result: Any = obj["result"] ?? [String: Any]()
                c.resume(returning: JSONValue(any: result))
            }
        }
    }

    private func send(_ message: JSONValue) throws {
        guard let stdin = stdin else { throw MCPError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: message.any)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            let id = state.withLock { s -> Int in
                let n = s.nextID
                s.nextID += 1
                s.pending[n] = continuation
                return n
            }
            do {
                try send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
            } catch {
                let c = state.withLock { s in s.pending.removeValue(forKey: id) }
                c?.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self = self else { return }
                let c = self.state.withLock { s in s.pending.removeValue(forKey: id) }
                c?.resume(throwing: MCPError.timeout)
            }
        }
    }

    public func listTools() async throws -> [MCPToolInfo] {
        let result = try await request(method: "tools/list", params: .object([:]))
        var infos: [MCPToolInfo] = []
        for t in result["tools"]?.arrayValue ?? [] {
            guard let name = t.string("name") else { continue }
            let readOnly = t["annotations"]?["readOnlyHint"]?.boolValue ?? false
            infos.append(MCPToolInfo(name: name,
                                     description: t.string("description") ?? "",
                                     inputSchema: t["inputSchema"] ?? JSONValue.schema([]),
                                     readOnlyHint: readOnly))
        }
        return infos
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        let result = try await request(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
        var parts: [String] = []
        for item in result["content"]?.arrayValue ?? [] {
            if let text = item.string("text") { parts.append(text) }
        }
        let text = parts.isEmpty ? result.jsonString() : parts.joined(separator: "\n")
        if result["isError"]?.boolValue == true { throw ToolError.failed(text) }
        return text
    }
}

/// Wraps one MCP server tool as a Damson Tool. Only tools that declare readOnlyHint are Observe.
public struct MCPTool: Tool {
    let connection: MCPServerConnection
    let info: MCPToolInfo
    let serverName: String

    static func sanitize(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String(s.map { allowed.contains($0) ? $0 : "_" })
    }

    public var spec: ToolSpec {
        let name = String(("mcp_" + Self.sanitize(serverName) + "_" + Self.sanitize(info.name)).prefix(64))
        return ToolSpec(name: name, description: "[MCP \(serverName)] \(info.description)", inputSchema: info.inputSchema)
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        return info.readOnlyHint ? .observe : .change
    }

    public func describe(_ input: JSONValue) -> String {
        return "MCP server '\(serverName)' tool '\(info.name)' with arguments: \(input.jsonString().truncated(to: 400))"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        return try await connection.callTool(name: info.name, arguments: input)
    }
}

/// Starts the servers in ~/Library/Application Support/Damson/mcp.json and registers their tools.
public final class MCPManager: @unchecked Sendable {
    private let connections = Locked<[MCPServerConnection]>([])

    public init() {}

    @discardableResult
    public func load(into registry: ToolRegistry, configURL: URL = AppPaths.mcpConfigURL) async -> [String] {
        var log: [String] = []
        for c in connections.current { c.stop() }
        connections.withLock { $0.removeAll() }

        guard let data = try? Data(contentsOf: configURL),
              let file = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            return ["No MCP config at \(configURL.path)"]
        }
        for server in file.servers {
            let connection = MCPServerConnection(config: server)
            do {
                try await connection.start()
                let tools = try await connection.listTools()
                for info in tools {
                    registry.register(MCPTool(connection: connection, info: info, serverName: server.name))
                }
                connections.withLock { $0.append(connection) }
                log.append("MCP '\(server.name)': \(tools.count) tools")
            } catch {
                connection.stop()
                log.append("MCP '\(server.name)' failed: \(error.localizedDescription)")
            }
        }
        return log
    }

    public func shutdown() {
        for c in connections.current { c.stop() }
    }
}
