import Foundation
import DamsonSupport

/// The jobs Damson gives to models. Each can be routed to a different model or vendor.
public enum AgentRole: String, Codable, CaseIterable, Sendable {
    case conversation

    public var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        }
    }
}

public struct ModelRoute: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    /// Reasoning on/off for local models that support it. nil = the model's own default.
    public var thinking: Bool?

    public init(provider: String, model: String, thinking: Bool? = nil) {
        self.provider = provider
        self.model = model
        self.thinking = thinking
    }

    enum CodingKeys: String, CodingKey { case provider, model, thinking }

    /// Settings saved before the subscription switch say "anthropic": that now means the Claude subscription.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let p = try c.decode(String.self, forKey: .provider)
        provider = p == "anthropic" ? ClaudeCodeProvider.providerID : p
        model = try c.decode(String.self, forKey: .model)
        thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking)
    }
}

public struct RoutingTable: Codable, Equatable, Sendable {
    public var routes: [String: ModelRoute]

    public init(routes: [String: ModelRoute]) {
        self.routes = routes
    }

    /// Model IDs are configuration, not code: change them in Settings without a release.
    public static let claudeDefault = RoutingTable(routes: [
        AgentRole.conversation.rawValue: ModelRoute(provider: ClaudeCodeProvider.providerID, model: "claude-haiku-5-5"),
    ])

    /// The conversation role on a local Ollama model. Thinking is off to keep replies fast.
    public static func allLocal(assistant: String) -> RoutingTable {
        return RoutingTable(routes: [
            AgentRole.conversation.rawValue: ModelRoute(provider: "ollama", model: assistant, thinking: false),
        ])
    }

    public var usesProviders: Set<String> {
        return Set(AgentRole.allCases.map { route(for: $0).provider })
    }

    public func route(for role: AgentRole) -> ModelRoute {
        if let explicit = routes[role.rawValue] { return explicit }
        return ModelRoute(provider: ClaudeCodeProvider.providerID, model: "claude-sonnet-5-5")
    }

    public mutating func set(_ role: AgentRole, _ route: ModelRoute) {
        routes[role.rawValue] = route
    }
}

public final class ProviderRegistry: @unchecked Sendable {
    private let providers = Locked<[String: LLMProvider]>([:])

    public init() {}

    public func register(_ provider: LLMProvider) {
        providers.withLock { $0[provider.id] = provider }
    }

    public func provider(id: String) -> LLMProvider? {
        return providers.current[id]
    }

    public var ids: [String] {
        return providers.current.keys.sorted()
    }
}

/// Resolves a role to a provider + model through the routing table, and records usage.
public final class ModelGateway: @unchecked Sendable {
    public let registry: ProviderRegistry
    private let routing: @Sendable () -> RoutingTable
    private let usageHandler = Locked<(@Sendable (AgentRole, String, String, Usage) -> Void)?>(nil)

    public init(registry: ProviderRegistry, routing: @escaping @Sendable () -> RoutingTable) {
        self.registry = registry
        self.routing = routing
    }

    public func setUsageHandler(_ handler: @escaping @Sendable (AgentRole, String, String, Usage) -> Void) {
        usageHandler.withLock { $0 = handler }
    }

    public func routeLabel(for role: AgentRole) -> String {
        let r = routing().route(for: role)
        return "\(r.provider):\(r.model)"
    }

    private func build(role: AgentRole, system: String, messages: [Message], tools: [ToolSpec], maxTokens: Int, route override: ModelRoute? = nil, skills: [SkillRef] = [], blockedSkills: [String] = []) throws -> (LLMProvider, LLMRequest) {
        let route = override ?? routing().route(for: role)
        guard let provider = registry.provider(id: route.provider) else {
            throw LLMError.unknownProvider(route.provider)
        }
        var effectiveTools = tools
        if !provider.capabilities.toolUse { effectiveTools = [] }
        var request = LLMRequest(model: route.model, system: system, messages: messages, tools: effectiveTools, maxTokens: maxTokens, thinking: route.thinking)
        request.skills = skills
        request.blockedSkills = blockedSkills
        return (provider, request)
    }

    public func complete(role: AgentRole, system: String, messages: [Message], tools: [ToolSpec] = [], maxTokens: Int = 2048) async throws -> LLMResponse {
        let (provider, request) = try build(role: role, system: system, messages: messages, tools: tools, maxTokens: maxTokens)
        let response = try await provider.complete(request)
        usageHandler.current?(role, provider.id, request.model, response.usage)
        return response
    }

    public func stream(role: AgentRole, system: String, messages: [Message], tools: [ToolSpec] = [], maxTokens: Int = 1024, route override: ModelRoute? = nil, skills: [SkillRef] = [], blockedSkills: [String] = []) -> AsyncThrowingStream<LLMEvent, Error> {
        return AsyncThrowingStream<LLMEvent, Error> { continuation in
            let task = Task {
                do {
                    let (provider, request) = try self.build(role: role, system: system, messages: messages, tools: tools, maxTokens: maxTokens, route: override, skills: skills, blockedSkills: blockedSkills)
                    for try await event in provider.stream(request) {
                        if case .done(let response) = event {
                            self.usageHandler.current?(role, provider.id, request.model, response.usage)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A provider driven by a closure. Used by tests and by "demo mode".
public final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let capabilities = ProviderCapabilities(toolUse: true, streaming: false, vision: false, structuredOutput: false, maxContextTokens: 100_000)
    private let handler: @Sendable (LLMRequest) async throws -> LLMResponse

    public init(id: String = ClaudeCodeProvider.providerID, handler: @escaping @Sendable (LLMRequest) async throws -> LLMResponse) {
        self.id = id
        self.handler = handler
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        return try await handler(request)
    }
}
