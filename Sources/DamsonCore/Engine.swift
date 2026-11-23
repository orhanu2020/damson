import Foundation
import DamsonSupport
import DamsonProviders
import DamsonStore
import DamsonTools

/// Holds the running conversation. An actor so voice and text can't corrupt it.
actor ConversationState {
    private var history: [Message] = []

    func snapshot() -> [Message] { history }

    func append(_ messages: [Message]) {
        history.append(contentsOf: messages)
    }

    func clear() { history.removeAll() }

    /// Keeps the last `maxMessages`, and never starts in the middle of a tool exchange.
    func trim(maxMessages: Int) {
        if history.count > maxMessages {
            history.removeFirst(history.count - maxMessages)
        }
        while let first = history.first, first.role != .user || first.isToolResultMessage {
            history.removeFirst()
        }
    }
}

/// Damson: the composition root. Owns the conversation, the tool gate and the providers.
public final class DamsonEngine: @unchecked Sendable {
    public let bus = EventBus()
    public let store: DamsonStore
    public let registry = ProviderRegistry()
    public let gateway: ModelGateway
    public let tools = ToolRegistry()
    public let approvals = ApprovalCenter()
    public let gate: PolicyGate
    public let mcp = MCPManager()

    private let settingsBox: Locked<DamsonSettings>
    private let personChats = Locked<[String: ConversationState]>([:])

    public init(store: DamsonStore, settings: DamsonSettings) {
        self.store = store
        let box = Locked<DamsonSettings>(settings)
        self.settingsBox = box

        registry.register(ClaudeCodeProvider())
        registry.register(OllamaProvider(baseURL: {
            URL(string: box.current.ollamaURL) ?? URL(string: "http://localhost:11434")!
        }))
        let gateway = ModelGateway(registry: registry, routing: { box.current.routing })
        self.gateway = gateway

        let gate = PolicyGate(registry: tools, approver: approvals)
        self.gate = gate
        gate.trust.configure(level: settings.trustLevel, workspacePath: settings.workspacePath)

        registerBuiltinTools()
        wireCallbacks()
    }

    private func registerBuiltinTools() {
        tools.register(ShellTool())
        tools.register(TerminalTool())
        tools.register(ReadFileTool())
        tools.register(ListDirTool())
        tools.register(WriteFileTool())
        tools.register(WebFetchTool())
        tools.register(BrowserNavigateTool())
        tools.register(BrowserReadTool())
        tools.register(BrowserLinksTool())
        tools.register(BrowserClickTool())
        tools.register(BrowserTypeTool())
    }

    private func wireCallbacks() {
        let bus = self.bus
        let store = self.store
        let approvals = self.approvals

        gateway.setUsageHandler { role, provider, model, usage in
            try? store.recordUsage(taskID: nil, role: role.rawValue, provider: provider, model: model,
                                   tokensIn: usage.inputTokens, tokensOut: usage.outputTokens)
        }

        gate.setAuditSink { record in
            let payload = JSONValue.object([
                "tool": .string(record.tool),
                "summary": .string(record.summary),
                "class": .string(record.actionClass.rawValue),
                "decision": .string(record.decision),
                "ok": .bool(record.succeeded),
                "subtask": .string(record.subtaskID),
            ]).jsonString()
            try? store.appendEvent(taskID: record.taskID, type: "tool", payload: payload)
        }

        approvals.onRequested = { request in
            bus.publish(.approvalRequested(request))
            try? store.appendEvent(taskID: request.taskID, type: "approval_requested", payload: request.summary)
        }

        approvals.onResolved = { request, decision in
            bus.publish(.approvalResolved(request, decision))
            try? store.appendEvent(taskID: request.taskID, type: "approval_resolved", payload: "\(decision.rawValue): \(request.summary)")
        }
    }

    // MARK: Settings

    public var settings: DamsonSettings { settingsBox.current }

    public func updateSettings(_ new: DamsonSettings) {
        settingsBox.withLock { $0 = new }
        gate.trust.configure(level: new.trustLevel, workspacePath: new.workspacePath)
    }

    public func loadMCP() async -> [String] {
        return await mcp.load(into: tools)
    }

    // MARK: Approvals

    public func pendingApprovals() -> [ApprovalRequest] { approvals.pendingRequests() }

    public func resolveApproval(id: String, decision: ApprovalDecision) {
        approvals.resolve(id: id, decision: decision)
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.filter { $0.isLetter || $0 == " " || $0 == "'" }
        let collapsed = kept.split(separator: " ").joined(separator: " ")
        return collapsed.replacingOccurrences(of: "'", with: "")
    }

    /// Exact spoken/typed phrases only. Approvals are never decided by a model.
    static func approvalDecision(for text: String) -> ApprovalDecision? {
        let n = normalize(text)
        let forTask: Set<String> = ["approve for this task", "approve for the task", "approve all for this task", "yes approve for this task", "approve for task"]
        let once: Set<String> = ["approve", "approved", "approve it", "i approve", "yes approve", "go ahead", "yes go ahead", "do it", "yes do it", "yes", "yes please", "approve once"]
        let deny: Set<String> = ["deny", "denied", "no", "no deny", "reject", "dont", "do not", "dont do it", "stop", "cancel that", "negative", "no thanks"]
        if forTask.contains(n) { return .approveForTask }
        if once.contains(n) { return .approveOnce }
        if deny.contains(n) { return .deny }
        return nil
    }

    private func personState(_ id: String) -> ConversationState {
        personChats.withLock { (d: inout [String: ConversationState]) -> ConversationState in
            if let s = d[id] { return s }
            let s = ConversationState()
            d[id] = s
            return s
        }
    }

    public func clearPersonChat(_ person: Person) async {
        await personState(person.id).clear()
    }

    /// Runs one assigned piece of project work as `person`: a tool loop with no chat history and no user turns.
    /// All paths resolve inside `directory`, and writes there are free; everything else still goes through approval.
    /// Returns the agent's closing summary. Throws if the model cannot be reached.
    public func runTask(as person: Person, company: Company, instruction: String, directory: URL,
                        stage: String, maxSteps: Int = 40, policy: TaskPolicy = .inherit,
                        onTool: @escaping @Sendable (String) -> Void) async throws -> String {
        let cfg = settings
        let system = Prompts.person(person, company: company, style: cfg.style, verbosity: .detailed, now: Date(), work: true)
        let route = person.model.map { ModelRoute(provider: ClaudeCodeProvider.providerID, model: $0) }
        let specs = tools.specs.filter { !person.disabledTools.contains($0.name) }
        let sel = SkillStore.selection(for: person.skills, all: SkillStore.list())
        let context = ToolContext(taskID: "project-\(directory.lastPathComponent)", subtaskID: stage,
                                  scratchDir: directory, workspaceDir: directory, policy: policy)
        var messages: [Message] = [Message(role: .user, text: instruction)]
        var lastText = ""
        for _ in 0..<maxSteps {
            try Task.checkCancellation()
            var finalResponse: LLMResponse?
            var roundText = ""
            for try await event in gateway.stream(role: .conversation, system: system, messages: messages,
                                                  tools: specs, maxTokens: 8000, route: route, skills: sel.refs, blockedSkills: sel.blocked) {
                switch event {
                case .textDelta(let d): roundText += d
                case .toolCall: break
                case .done(let r): finalResponse = r
                }
            }
            guard let response = finalResponse else { break }
            if !roundText.isEmpty { lastText = roundText }
            messages.append(response.message)
            let calls = response.toolCalls
            if calls.isEmpty { return lastText.trimmingCharacters(in: .whitespacesAndNewlines) }
            var results: [ContentBlock] = []
            for call in calls {
                try Task.checkCancellation()
                onTool(tools.tool(named: call.name)?.describe(call.input) ?? call.name)
                let outcome = await gate.execute(call, context: context)
                results.append(.toolResult(toolUseID: call.id, content: outcome.output, isError: outcome.isError))
            }
            messages.append(Message(role: .user, content: results))
        }
        return lastText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n[Stopped: reached the step limit.]"
    }

    /// If `text` is an exact approve/deny phrase and an approval is waiting, resolves it. Returns what was decided.
    public func resolveApprovalByWords(_ text: String) -> ApprovalDecision? {
        guard let oldest = approvals.pendingRequests().first, let decision = Self.approvalDecision(for: text) else { return nil }
        approvals.resolve(id: oldest.id, decision: decision)
        return decision
    }

    /// One turn of a direct chat with a person from the Company tab. Each person keeps their own history
    /// and may use their enabled tools; every tool call goes through the policy gate (changes need approval).
    public func chat(with person: Person, company: Company, text: String, images: [Data] = [],
                     onSentence: @escaping @Sendable (String) -> Void,
                     onTool: @escaping @Sendable (String) -> Void = { _ in }) async -> String {
        let cfg = settings
        let state = personState(person.id)
        var userBlocks: [ContentBlock] = [.text(text.isEmpty && !images.isEmpty ? "(picture)" : text)]
        for data in images { userBlocks.append(.image(mediaType: "image/png", data: data)) }
        var newMessages: [Message] = [Message(role: .user, content: userBlocks)]
        let system = Prompts.person(person, company: company, style: cfg.style, verbosity: cfg.verbosity, now: Date())
        let route = person.model.map { ModelRoute(provider: ClaudeCodeProvider.providerID, model: $0) }
        let specs = tools.specs.filter { !person.disabledTools.contains($0.name) }
        let sel = SkillStore.selection(for: person.skills, all: SkillStore.list())

        let scratch = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson/scratch/\(person.id)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let context = ToolContext(taskID: "agent-\(person.id)", subtaskID: "chat", scratchDir: scratch, workspaceDir: cfg.workspaceURL)

        var reply = ""
        let maxSteps = 8
        do {
            for _ in 0..<maxSteps {
                let history = await state.snapshot() + newMessages
                var splitter = SentenceSplitter()
                var finalResponse: LLMResponse?
                var roundText = ""
                for try await event in gateway.stream(role: .conversation, system: system, messages: history,
                                                      tools: specs, maxTokens: 1024, route: route, skills: sel.refs, blockedSkills: sel.blocked) {
                    switch event {
                    case .textDelta(let delta):
                        roundText += delta
                        for sentence in splitter.push(delta) { onSentence(sentence) }
                    case .toolCall: break
                    case .done(let response): finalResponse = response
                    }
                }
                if let rest = splitter.flush() { onSentence(rest) }
                if !roundText.isEmpty { reply += (reply.isEmpty ? "" : " ") + roundText }
                guard let response = finalResponse else { break }
                newMessages.append(response.message)
                let calls = response.toolCalls
                if calls.isEmpty { break }
                var results: [ContentBlock] = []
                for call in calls {
                    try Task.checkCancellation()
                    onTool(tools.tool(named: call.name)?.describe(call.input) ?? call.name)
                    let outcome = await gate.execute(call, context: context)
                    results.append(.toolResult(toolUseID: call.id, content: outcome.output, isError: outcome.isError))
                }
                newMessages.append(Message(role: .user, content: results))
            }
        } catch {
            if !(Task.isCancelled || error is CancellationError) {
                let message = "I'm sorry, I couldn't reach the model. \(error.localizedDescription)"
                onSentence(message)
                reply += message
            }
        }
        if let last = newMessages.last, last.role == .assistant {
            await state.append(newMessages)
            await state.trim(maxMessages: 40)
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
