import Foundation

// MARK: - Neutral message types (no vendor types leak past the provider layer)

public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(ToolCall)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// A picture the user attached (PNG or JPEG bytes).
    case image(mediaType: String, data: Data)
}

public enum MessageRole: String, Sendable, Codable {
    case user
    case assistant
}

public struct Message: Sendable, Equatable {
    public var role: MessageRole
    public var content: [ContentBlock]

    public init(role: MessageRole, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public init(role: MessageRole, text: String) {
        self.role = role
        self.content = [.text(text)]
    }

    /// All text blocks joined together.
    public var text: String {
        var parts: [String] = []
        for block in content {
            if case .text(let t) = block { parts.append(t) }
        }
        return parts.joined()
    }

    public var toolCalls: [ToolCall] {
        var calls: [ToolCall] = []
        for block in content {
            if case .toolUse(let c) = block { calls.append(c) }
        }
        return calls
    }

    /// True when this is a user message made only of tool results.
    public var isToolResultMessage: Bool {
        guard role == .user, !content.isEmpty else { return false }
        for block in content {
            if case .toolResult = block { continue }
            return false
        }
        return true
    }
}

public struct Usage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let zero = Usage()

    public var total: Int { inputTokens + outputTokens }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

public enum StopReason: String, Sendable, Codable {
    case endTurn
    case toolUse
    case maxTokens
    case other
}

/// A Claude skill folder (with a SKILL.md) an agent may use.
public struct SkillRef: Sendable, Equatable {
    public var name: String
    public var directory: URL
    public init(name: String, directory: URL) { self.name = name; self.directory = directory }
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [Message]
    public var tools: [ToolSpec]
    public var maxTokens: Int
    public var temperature: Double?
    /// nil = the model's default. Only used by providers that support a reasoning switch (Ollama).
    public var thinking: Bool?
    /// Skills the agent may load (Claude provider only), and other known skill names it must not.
    public var skills: [SkillRef] = []
    public var blockedSkills: [String] = []

    public init(model: String, system: String = "", messages: [Message], tools: [ToolSpec] = [], maxTokens: Int = 2048, temperature: Double? = nil, thinking: Bool? = nil) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinking = thinking
    }
}

public struct LLMResponse: Sendable {
    public var message: Message
    public var usage: Usage
    public var stopReason: StopReason

    public init(message: Message, usage: Usage = .zero, stopReason: StopReason = .endTurn) {
        self.message = message
        self.usage = usage
        self.stopReason = stopReason
    }

    public var text: String { message.text }
    public var toolCalls: [ToolCall] { message.toolCalls }
}

public enum LLMEvent: Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    /// Always the last event. Its message is the authoritative final result.
    case done(LLMResponse)
}

public struct ProviderCapabilities: Sendable {
    public var toolUse: Bool
    public var streaming: Bool
    public var vision: Bool
    public var structuredOutput: Bool
    public var maxContextTokens: Int

    public init(toolUse: Bool, streaming: Bool, vision: Bool, structuredOutput: Bool, maxContextTokens: Int) {
        self.toolUse = toolUse
        self.streaming = streaming
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.maxContextTokens = maxContextTokens
    }
}

public enum LLMError: Error, LocalizedError {
    case http(Int, String)
    case decoding(String)
    case network(String)
    case unknownProvider(String)
    case subscription(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "The model service returned an error (\(code)): \(body)"
        case .decoding(let m):
            return "Could not read the model response: \(m)"
        case .network(let m):
            return "Network problem: \(m)"
        case .subscription(let m):
            return m
        case .unknownProvider(let p):
            return "Unknown model provider: \(p)"
        }
    }
}

// MARK: - Provider protocol

public protocol LLMProvider: Sendable {
    var id: String { get }
    var capabilities: ProviderCapabilities { get }
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

public extension LLMProvider {
    /// Default streaming: run `complete` and replay the result as events.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        return AsyncThrowingStream<LLMEvent, Error> { continuation in
            let task = Task {
                do {
                    let response = try await self.complete(request)
                    if !response.text.isEmpty { continuation.yield(.textDelta(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
