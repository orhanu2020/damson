import Foundation
import DamsonSupport
import DamsonProviders

/// Observe = looks only. Change = modifies the Mac or an online account (needs approval).
public enum ActionClass: String, Codable, Sendable {
    case observe
    case change
}

/// How a task's changes are approved. A project mode picks one; `inherit` follows the Settings trust level.
public enum TaskPolicy: Sendable, Equatable {
    /// The Settings trust level.
    case inherit
    /// Every change asks.
    case ask
    /// Like trusted workspace, with the task's own folder as the workspace (never less than the Settings level).
    case workspace
    /// Writing files inside the task's folder skips the card; everything else asks.
    case acceptEdits
    /// Nothing may change except these files (relative to the task's folder); other changes are refused without asking.
    case plan(writable: [String])
    /// Every change runs without asking, dangerous commands included.
    case bypass
}

public struct ToolContext: Sendable {
    public var taskID: String
    public var subtaskID: String
    /// Per-task scratch directory. Writes inside it are free; everything else needs approval.
    public var scratchDir: URL
    /// The user's workspace folder (shell starts here, relative paths resolve here). Nil = use the scratch folder.
    public var workspaceDir: URL?
    public var policy: TaskPolicy

    public init(taskID: String, subtaskID: String, scratchDir: URL, workspaceDir: URL? = nil, policy: TaskPolicy = .inherit) {
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.scratchDir = scratchDir
        self.workspaceDir = workspaceDir
        self.policy = policy
    }

    /// Where commands start and relative paths resolve.
    public var baseDir: URL { workspaceDir ?? scratchDir }
}

public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    /// Deny by default: anything not confidently Observe must return .change.
    func classify(_ input: JSONValue, context: ToolContext) -> ActionClass
    /// Exact, human-readable description of what will happen. Shown in approval prompts.
    func describe(_ input: JSONValue) -> String
    /// Key for "approve for this task" grants (narrower than the whole tool where sensible).
    func grantKey(_ input: JSONValue) -> String
    func run(_ input: JSONValue, context: ToolContext) async throws -> String
}

public extension Tool {
    func grantKey(_ input: JSONValue) -> String { spec.name }
}

public enum ToolError: Error, LocalizedError {
    case invalidInput(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return "Invalid input: \(m)"
        case .failed(let m): return m
        }
    }
}

public final class ToolRegistry: @unchecked Sendable {
    private let tools = Locked<[String: Tool]>([:])

    public init() {}

    public func register(_ tool: Tool) {
        tools.withLock { $0[tool.spec.name] = tool }
    }

    public func tool(named name: String) -> Tool? {
        return tools.current[name]
    }

    public var specs: [ToolSpec] {
        return tools.current.values.map { $0.spec }.sorted { $0.name < $1.name }
    }

    public var names: [String] {
        return tools.current.keys.sorted()
    }
}

// MARK: - Approvals and the policy gate

public struct ApprovalRequest: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var taskID: String
    public var subtaskID: String
    public var tool: String
    /// The literal action (command, path, URL), not a model-written summary.
    public var summary: String
    public var createdAt: Date

    public init(id: String, taskID: String, subtaskID: String, tool: String, summary: String, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.tool = tool
        self.summary = summary
        self.createdAt = createdAt
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case approveOnce
    case approveForTask
    case deny
}

public protocol Approver: Sendable {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision
}

public struct AuditRecord: Sendable {
    public var taskID: String
    public var subtaskID: String
    public var tool: String
    public var summary: String
    public var actionClass: ActionClass
    public var decision: String
    public var succeeded: Bool
}

public struct ToolOutcome: Sendable {
    public var output: String
    public var isError: Bool
    public var actionClass: ActionClass
    public var wasDenied: Bool
}

/// Every tool call passes through here. Helpers can look at anything; changes need the user.
public final class PolicyGate: @unchecked Sendable {
    private let registry: ToolRegistry
    private let approver: Approver
    private let grants = Locked<[String: Set<String>]>([:])
    /// Set from Settings only. Decides which Changes may skip the approval card.
    public let trust = TrustPolicy()
    private let auditSink = Locked<(@Sendable (AuditRecord) -> Void)?>(nil)
    public static let maxOutputCharacters = 12_000

    public init(registry: ToolRegistry, approver: Approver) {
        self.registry = registry
        self.approver = approver
    }

    public func setAuditSink(_ sink: @escaping @Sendable (AuditRecord) -> Void) {
        auditSink.withLock { $0 = sink }
    }

    public func revokeGrants(taskID: String) {
        grants.withLock { _ = $0.removeValue(forKey: taskID) }
    }

    private func hasGrant(taskID: String, key: String) -> Bool {
        return grants.current[taskID]?.contains(key) ?? false
    }

    private func addGrant(taskID: String, key: String) {
        grants.withLock { dict in
            var set = dict[taskID] ?? Set<String>()
            set.insert(key)
            dict[taskID] = set
        }
    }

    private func audit(_ record: AuditRecord) {
        auditSink.current?(record)
    }

    public func execute(_ call: ToolCall, context: ToolContext) async -> ToolOutcome {
        guard let tool = registry.tool(named: call.name) else {
            return ToolOutcome(output: "Unknown tool: \(call.name)", isError: true, actionClass: .change, wasDenied: false)
        }
        let actionClass = tool.classify(call.input, context: context)
        let summary = tool.describe(call.input)
        DebugLog.write("tool requested: \(summary) [\(actionClass.rawValue)]")
        var decisionLabel = "auto"

        if actionClass == .change {
            let key = tool.grantKey(call.input)
            let verdict = trust.verdict(tool: tool.spec.name, input: call.input, context: context)
            if case .deny(let message) = verdict {
                audit(AuditRecord(taskID: context.taskID, subtaskID: context.subtaskID, tool: tool.spec.name,
                                  summary: summary, actionClass: actionClass, decision: "refused-by-mode", succeeded: false))
                return ToolOutcome(output: message, isError: true, actionClass: actionClass, wasDenied: true)
            }
            if hasGrant(taskID: context.taskID, key: key) {
                decisionLabel = "task-grant"
            } else if verdict == .autoApprove {
                decisionLabel = "trusted-\(trust.level.rawValue)"
            } else {
                let request = ApprovalRequest(id: UUID().uuidString, taskID: context.taskID, subtaskID: context.subtaskID,
                                              tool: tool.spec.name, summary: summary, createdAt: Date())
                let decision = await approver.requestApproval(request)
                switch decision {
                case .deny:
                    audit(AuditRecord(taskID: context.taskID, subtaskID: context.subtaskID, tool: tool.spec.name,
                                      summary: summary, actionClass: actionClass, decision: "denied", succeeded: false))
                    return ToolOutcome(output: "DENIED by the user. Do not retry this action. Choose a different approach, or report that this step needs the user's approval.",
                                       isError: true, actionClass: actionClass, wasDenied: true)
                case .approveForTask:
                    addGrant(taskID: context.taskID, key: key)
                    decisionLabel = "approved-for-task"
                case .approveOnce:
                    decisionLabel = "approved-once"
                }
            }
        }

        do {
            let output = try await tool.run(call.input, context: context)
            audit(AuditRecord(taskID: context.taskID, subtaskID: context.subtaskID, tool: tool.spec.name,
                              summary: summary, actionClass: actionClass, decision: decisionLabel, succeeded: true))
            return ToolOutcome(output: output.truncated(to: Self.maxOutputCharacters), isError: false, actionClass: actionClass, wasDenied: false)
        } catch {
            audit(AuditRecord(taskID: context.taskID, subtaskID: context.subtaskID, tool: tool.spec.name,
                              summary: summary, actionClass: actionClass, decision: decisionLabel, succeeded: false))
            return ToolOutcome(output: "Error: \(error.localizedDescription)", isError: true, actionClass: actionClass, wasDenied: false)
        }
    }
}
