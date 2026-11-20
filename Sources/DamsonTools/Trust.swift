import Foundation
import DamsonSupport
import DamsonProviders

/// How much Damson's helpers may do without asking. Only the user can change this (Settings).
public enum TrustLevel: String, Codable, CaseIterable, Sendable {
    /// Every change asks for approval (default).
    case ask
    /// File and build commands that stay inside the workspace folder run without asking.
    case workspace
    /// Everything runs without asking, except the hard-block list, which always asks.
    case full

    public var title: String {
        switch self {
        case .ask: return "Ask for every change"
        case .workspace: return "Trusted workspace"
        case .full: return "Full trust"
        }
    }

    public var explanation: String {
        switch self {
        case .ask:
            return "Reading and looking is free. Anything that changes your Mac or an online account shows an approval card."
        case .workspace:
            return "File and build commands inside your workspace folder run without asking. Opening apps, anything outside the workspace, and online actions still ask."
        case .full:
            return "No approval cards, including opening apps and typing in Terminal. Dangerous commands (sudo, disk tools, recursive deletes outside the workspace, secrets, pipe-to-shell, force pushes) still ask."
        }
    }
}

/// Decides whether a Change may skip the approval card. Models can never raise their own trust.
public final class TrustPolicy: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable {
        case autoApprove
        case askUser
    }

    private struct State {
        var level: TrustLevel = .ask
        var workspace: URL? = nil
    }

    private let state = Locked<State>(State())

    public init() {}

    public func configure(level: TrustLevel, workspacePath: String) {
        let trimmed = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        state.withLock {
            $0.level = level
            $0.workspace = url
        }
    }

    public var level: TrustLevel { state.current.level }
    public var workspace: URL? { state.current.workspace }

    public func verdict(tool: String, input: JSONValue, context: ToolContext) -> Verdict {
        let s = state.current
        if s.level == .ask { return .askUser }

        switch tool {
        case "shell", "terminal_run":
            guard let command = input.string("command") else { return .askUser }
            if ShellClassifier.isHardBlocked(command, workspace: s.workspace) { return .askUser }
            if s.level == .full { return .autoApprove }
            guard let workspace = s.workspace else { return .askUser }
            return ShellClassifier.isWorkspaceSafe(command, workspace: workspace) ? .autoApprove : .askUser

        case "write_file":
            guard let path = input.string("path") else { return .askUser }
            if ShellClassifier.isSensitivePath(path) { return .askUser }
            let url = PathUtil.resolve(path, base: context.baseDir)
            let insideWorkspace = s.workspace.map { PathUtil.isInside(url, directory: $0) } ?? false
            if !insideWorkspace && ShellClassifier.isSystemPath(url.path) { return .askUser }
            if s.level == .full { return .autoApprove }
            return insideWorkspace ? .autoApprove : .askUser

        default:
            // Browser actions, MCP tools and anything else: only full trust skips the card.
            return s.level == .full ? .autoApprove : .askUser
        }
    }
}
