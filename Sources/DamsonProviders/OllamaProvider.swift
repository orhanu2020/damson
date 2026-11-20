import Foundation
import DamsonSupport

/// Removes <think>...</think> reasoning that some local models print inline, even when it
/// arrives split across streamed chunks.
struct ThinkTagFilter {
    private var buffer = ""
    private var inThink = false
    private static let open = "<think>"
    private static let close = "</think>"

    private static func partialSuffixLength(_ text: String, tag: String) -> Int {
        var best = 0
        let limit = min(tag.count - 1, text.count)
        if limit < 1 { return 0 }
        for k in 1...limit where text.hasSuffix(String(tag.prefix(k))) {
            best = k
        }
        return best
    }

    mutating func push(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while true {
            if inThink {
                if let r = buffer.range(of: Self.close) {
                    buffer = String(buffer[r.upperBound...])
                    inThink = false
                    while let first = buffer.first, first.isNewline { buffer.removeFirst() }
                    continue
                }
                let keep = Self.partialSuffixLength(buffer, tag: Self.close)
                buffer = String(buffer.suffix(keep))
                break
            } else {
                if let r = buffer.range(of: Self.open) {
                    out += String(buffer[..<r.lowerBound])
                    buffer = String(buffer[r.upperBound...])
                    inThink = true
                    continue
                }
                let keep = Self.partialSuffixLength(buffer, tag: Self.open)
                out += String(buffer.dropLast(keep))
                buffer = String(buffer.suffix(keep))
                break
            }
        }
        return out
    }

    mutating func flush() -> String {
        let rest = inThink ? "" : buffer
        buffer = ""
        inThink = false
        return rest
    }

    static func strip(_ text: String) -> String {
        var f = ThinkTagFilter()
        var out = f.push(text)
        out += f.flush()
        return out
    }
}

/// Local-model adapter for Ollama (http://localhost:11434 by default).
/// Proves the vendor-agnostic design: same neutral types, different wire format.
public final class OllamaProvider: LLMProvider, @unchecked Sendable {
    public let id = "ollama"
    public let capabilities = ProviderCapabilities(toolUse: true, streaming: true, vision: false, structuredOutput: true, maxContextTokens: 32_000)

    private let baseURL: @Sendable () -> URL
    private let session: URLSession
    private let counter = Locked<Int>(0)

    public init(baseURL: @escaping @Sendable () -> URL = { URL(string: "http://localhost:11434")! },
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Names of the models installed in the local Ollama (empty if Ollama is not running).
    public static func installedModels(baseURL: URL, session: URLSession = .shared) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: Encoding

    static func body(for request: LLMRequest, stream: Bool) -> [String: Any] {
        // Map tool_use ids to names so tool results can be labelled.
        var namesByID: [String: String] = [:]
        for m in request.messages {
            for c in m.toolCalls { namesByID[c.id] = c.name }
        }

        var messages: [[String: Any]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for m in request.messages {
            if m.role == .assistant {
                var entry: [String: Any] = ["role": "assistant", "content": m.text]
                let calls = m.toolCalls
                if !calls.isEmpty {
                    var encoded: [[String: Any]] = []
                    for c in calls {
                        encoded.append(["function": ["name": c.name, "arguments": c.input.any]])
                    }
                    entry["tool_calls"] = encoded
                }
                messages.append(entry)
            } else {
                var textParts: [String] = []
                for block in m.content {
                    switch block {
                    case .text(let t):
                        textParts.append(t)
                    case .toolResult(let toolUseID, let content, _):
                        var entry: [String: Any] = ["role": "tool", "content": content]
                        if let name = namesByID[toolUseID] { entry["tool_name"] = name }
                        messages.append(entry)
                    case .toolUse:
                        break
                    }
                }
                if !textParts.isEmpty {
                    messages.append(["role": "user", "content": textParts.joined(separator: "\n")])
                }
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": stream,
            "options": ["num_predict": request.maxTokens],
        ]
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = []
            for t in request.tools {
                tools.append([
                    "type": "function",
                    "function": ["name": t.name, "description": t.description, "parameters": t.inputSchema.any],
                ])
            }
            body["tools"] = tools
        }
        if let think = request.thinking {
            body["think"] = think
        }
        if let temp = request.temperature {
            var options = body["options"] as? [String: Any] ?? [:]
            options["temperature"] = temp
            body["options"] = options
        }
        return body
    }

    private func makeRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: baseURL().appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, stream: stream))
        return req
    }

    // MARK: Decoding

    private func nextCallID() -> String {
        let n = counter.withLock { (v: inout Int) -> Int in
            v += 1
            return v
        }
        return "ollama_call_\(n)"
    }

    private func parseMessage(_ obj: [String: Any]) -> (text: String, calls: [ToolCall]) {
        var text = ""
        var calls: [ToolCall] = []
        if let message = obj["message"] as? [String: Any] {
            text = message["content"] as? String ?? ""
            if let rawCalls = message["tool_calls"] as? [[String: Any]] {
                for raw in rawCalls {
                    guard let fn = raw["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                    let args: Any = fn["arguments"] ?? [String: Any]()
                    calls.append(ToolCall(id: nextCallID(), name: name, input: JSONValue(any: args)))
                }
            }
        }
        return (text, calls)
    }

    private func usage(from obj: [String: Any]) -> Usage {
        Usage(inputTokens: obj["prompt_eval_count"] as? Int ?? 0, outputTokens: obj["eval_count"] as? Int ?? 0)
    }

    // MARK: LLMProvider

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let req = try makeRequest(request, stream: false)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw LLMError.network("Could not reach Ollama: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.network("No HTTP response") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("Ollama response was not an object")
        }
        let parsed = parseMessage(obj)
        var content: [ContentBlock] = []
        let visible = ThinkTagFilter.strip(parsed.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty { content.append(.text(visible)) }
        for c in parsed.calls { content.append(.toolUse(c)) }
        return LLMResponse(message: Message(role: .assistant, content: content),
                           usage: usage(from: obj),
                           stopReason: parsed.calls.isEmpty ? .endTurn : .toolUse)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        return AsyncThrowingStream<LLMEvent, Error> { continuation in
            let task = Task {
                do {
                    let req = try self.makeRequest(request, stream: true)
                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw LLMError.network("No HTTP response") }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                    }
                    var fullText = ""
                    var thinkFilter = ThinkTagFilter()
                    var calls: [ToolCall] = []
                    var finalUsage = Usage.zero
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                        else { continue }
                        let parsed = self.parseMessage(obj)
                        if !parsed.text.isEmpty {
                            let visible = thinkFilter.push(parsed.text)
                            if !visible.isEmpty {
                                fullText += visible
                                continuation.yield(.textDelta(visible))
                            }
                        }
                        for c in parsed.calls {
                            calls.append(c)
                            continuation.yield(.toolCall(c))
                        }
                        if obj["done"] as? Bool == true { finalUsage = self.usage(from: obj) }
                    }
                    let tail = thinkFilter.flush()
                    if !tail.isEmpty {
                        fullText += tail
                        continuation.yield(.textDelta(tail))
                    }
                    var content: [ContentBlock] = []
                    if !fullText.isEmpty { content.append(.text(fullText)) }
                    for c in calls { content.append(.toolUse(c)) }
                    let final = LLMResponse(message: Message(role: .assistant, content: content),
                                            usage: finalUsage,
                                            stopReason: calls.isEmpty ? .endTurn : .toolUse)
                    continuation.yield(.done(final))
                    continuation.finish()
                } catch {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
