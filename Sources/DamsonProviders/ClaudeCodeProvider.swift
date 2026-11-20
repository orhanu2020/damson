import Foundation
import DamsonSupport

/// Runs Claude through the user's own Claude Code CLI (`claude -p`), so usage comes out of their Claude
/// subscription (Pro/Max) instead of an API key. The CLI must be installed and logged in.
///
/// Tools: the CLI's own tools are switched off. Damson's tools are described to the model in the prompt and the
/// model replies with `<tool_call>{...}</tool_call>`, which Damson runs through its own approval gate.
public final class ClaudeCodeProvider: LLMProvider, @unchecked Sendable {
    public static let providerID = "claude-subscription"
    public let id = ClaudeCodeProvider.providerID
    public let capabilities = ProviderCapabilities(toolUse: true, streaming: true, vision: false, structuredOutput: false, maxContextTokens: 200_000)

    /// Suggestions for the model picker. Any other model id can still be typed in.
    public static let knownModels: [String] = [
        "claude-haiku-5-5",
        "claude-sonnet-5-5",
        "claude-opus-5-5",
        "claude-fable-5-1",
    ]

    private static let location = Locked<(path: String, searchPath: String)?>(nil)

    public init() {}

    // MARK: Finding the CLI

    /// A GUI app does not inherit the terminal's PATH, so ask a login shell where `claude` and `node` live.
    static func locate() -> (path: String, searchPath: String)? {
        if let cached = location.current { return cached }
        let home = NSHomeDirectory()
        var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        var found: String?

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "echo __PATH__$PATH; echo __CLAUDE__$(command -v claude)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = Pipe()
        if (try? shell.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                if line.hasPrefix("__PATH__") { searchPath = String(line.dropFirst(8)) + ":" + searchPath }
                if line.hasPrefix("__CLAUDE__") { let p = String(line.dropFirst(10)); if !p.isEmpty { found = p } }
            }
        }
        let candidates = [found, "\(home)/.npm-global/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let result = (path, (path as NSString).deletingLastPathComponent + ":" + searchPath)
        location.withLock { $0 = result }
        return result
    }

    // MARK: Prompt building

    static func toolPrompt(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        var out = """


        TOOLS
        You can use the tools below. To use one, reply with exactly this on its own (you may write a short sentence before it):
        <tool_call>{"name": "TOOL_NAME", "input": {...}}</tool_call>
        Then stop and wait: the result is sent back to you as the next message beginning with [Tool result]. Never invent a result. Use at most one tool call per reply unless calls are independent.
        Available tools:
        """
        for t in tools {
            out += "\n- \(t.name): \(t.description)\n  input schema: \(t.inputSchema.jsonString())"
        }
        return out
    }

    static func transcript(_ messages: [Message]) -> String {
        var parts: [String] = []
        for m in messages {
            for block in m.content {
                switch block {
                case .text(let t):
                    if t.isEmpty { continue }
                    parts.append((m.role == .user ? "[User]\n" : "[You]\n") + t)
                case .toolUse(let call):
                    parts.append("[You]\n<tool_call>{\"name\": \"\(call.name)\", \"input\": \(call.input.jsonString())}</tool_call>")
                case .toolResult(_, let content, let isError):
                    parts.append("[Tool result\(isError ? " (error)" : "")]\n\(content)")
                }
            }
        }
        return parts.joined(separator: "\n\n") + "\n\n[You]\n"
    }

    /// Splits a finished reply into plain text and tool calls.
    static func parse(_ full: String) -> (text: String, calls: [ToolCall]) {
        var calls: [ToolCall] = []
        var text = full
        let pattern = try? NSRegularExpression(pattern: "<tool_call>(.*?)</tool_call>", options: [.dotMatchesLineSeparators])
        let ns = full as NSString
        let matches = pattern?.matches(in: full, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches.reversed() {
            let body = ns.substring(with: m.range(at: 1)).data(using: .utf8) ?? Data()
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let name = obj["name"] as? String {
                let input = (obj["input"] as? [String: Any]).map { JSONValue(any: $0) } ?? .object([:])
                calls.insert(ToolCall(id: "toolu_" + UUID().uuidString.prefix(12).lowercased(), name: name, input: input), at: 0)
            }
            text = (text as NSString).replacingCharacters(in: m.range, with: "")
        }
        // An unfinished "<tool_call>" (cut off) is dropped from the text.
        if let r = text.range(of: "<tool_call>") { text = String(text[..<r.lowerBound]) }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    // MARK: LLMProvider

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var final: LLMResponse?
        for try await event in stream(request) { if case .done(let r) = event { final = r } }
        guard let final else { throw LLMError.decoding("no reply from the Claude Code CLI") }
        return final
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        return AsyncThrowingStream<LLMEvent, Error> { continuation in
            let process = Process()
            let task = Task {
                do {
                    guard let cli = Self.locate() else {
                        throw LLMError.subscription("The Claude Code CLI was not found. Install it (npm install -g @anthropic-ai/claude-code), run `claude` once and sign in with your Claude account.")
                    }
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("damson-claude-cli")
                    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

                    process.executableURL = URL(fileURLWithPath: cli.path)
                    process.currentDirectoryURL = scratch
                    process.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                         "--model", request.model, "--tools", "", "--setting-sources", "",
                                         "--no-session-persistence",
                                         "--system-prompt", request.system + Self.toolPrompt(request.tools)]
                    var env = ProcessInfo.processInfo.environment
                    // An API key in the environment would make the CLI bill the API instead of the subscription.
                    env["ANTHROPIC_API_KEY"] = nil
                    env["ANTHROPIC_AUTH_TOKEN"] = nil
                    env["PATH"] = cli.searchPath
                    process.environment = env
                    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                    process.standardInput = stdin
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    stdin.fileHandleForWriting.write(Self.transcript(request.messages).data(using: .utf8) ?? Data())
                    try? stdin.fileHandleForWriting.close()

                    var full = ""
                    var emitted = full.startIndex
                    var resultText: String?
                    var usage = Usage.zero
                    var errorText: String?
                    let marker = "<tool_call>"

                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                        let type = obj["type"] as? String
                        if type == "stream_event",
                           let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                           let delta = ev["delta"] as? [String: Any], let t = delta["text"] as? String {
                            full += t
                            // Stream plain text; hold back anything that might be the start of a tool call.
                            var limit = full.endIndex
                            if let r = full.range(of: marker) {
                                limit = r.lowerBound
                            } else {
                                for k in stride(from: min(marker.count - 1, full.count), through: 1, by: -1) where full.hasSuffix(String(marker.prefix(k))) {
                                    limit = full.index(full.endIndex, offsetBy: -k); break
                                }
                            }
                            if limit > emitted {
                                continuation.yield(.textDelta(String(full[emitted..<limit])))
                                emitted = limit
                            }
                        } else if type == "result" {
                            resultText = obj["result"] as? String
                            if obj["is_error"] as? Bool == true { errorText = resultText ?? "The Claude Code CLI reported an error." }
                            if let u = obj["usage"] as? [String: Any] {
                                let i = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                                usage = Usage(inputTokens: i, outputTokens: u["output_tokens"] as? Int ?? 0)
                            }
                        }
                    }
                    process.waitUntilExit()
                    if let errorText { throw LLMError.subscription(errorText) }
                    if resultText == nil && full.isEmpty {
                        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        throw LLMError.subscription(err.isEmpty ? "The Claude Code CLI returned nothing. Is it signed in? Run `claude` in Terminal." : err)
                    }
                    let parsed = Self.parse(full.isEmpty ? (resultText ?? "") : full)
                    // Text the hold-back kept (e.g. a false alarm "<tool"): send what was not yet emitted.
                    let already = String(full[..<emitted])
                    if parsed.text.hasPrefix(already.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.text.count > already.trimmingCharacters(in: .whitespacesAndNewlines).count {
                        let rest = String(parsed.text.dropFirst(already.trimmingCharacters(in: .whitespacesAndNewlines).count))
                        continuation.yield(.textDelta(rest))
                    }
                    var blocks: [ContentBlock] = []
                    if !parsed.text.isEmpty { blocks.append(.text(parsed.text)) }
                    for call in parsed.calls {
                        blocks.append(.toolUse(call))
                        continuation.yield(.toolCall(call))
                    }
                    let message = Message(role: .assistant, content: blocks.isEmpty ? [.text("")] : blocks)
                    continuation.yield(.done(LLMResponse(message: message, usage: usage, stopReason: parsed.calls.isEmpty ? .endTurn : .toolUse)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }
}
