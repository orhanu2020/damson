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
        /// Refused without asking (a project in plan mode); the text goes back to the model.
        case deny(String)
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
        var level = s.level
        var workspace = s.workspace
        let folder = context.baseDir.standardizedFileURL

        switch context.policy {
        case .inherit:
            break
        case .ask:
            return .askUser
        case .plan(let writable):
            if tool == "write_file", let path = input.string("path") {
                let url = PathUtil.resolve(path, base: context.baseDir).standardizedFileURL.path
                if writable.contains(where: { PathUtil.resolve($0, base: context.baseDir).standardizedFileURL.path == url }) { return .autoApprove }
            }
            return .deny("PLAN MODE: this project is in plan mode, so nothing may be changed except writing your own output file. Do not retry this. Describe in your output file what you would do (files, commands, risks) instead.")
        case .acceptEdits:
            guard tool == "write_file", let path = input.string("path"), !ShellClassifier.isSensitivePath(path) else { return .askUser }
            return PathUtil.isInside(PathUtil.resolve(path, base: context.baseDir), directory: folder) ? .autoApprove : .askUser
        case .workspace:
            if level == .ask { level = .workspace }
            workspace = folder
        case .bypass:
            // Everything is accepted, including the commands that always ask elsewhere.
            return .autoApprove
        }

        if level == .ask { return .askUser }

        switch tool {
        case "shell", "terminal_run":
            guard let command = input.string("command") else { return .askUser }
            if ShellClassifier.isHardBlocked(command, workspace: workspace) { return .askUser }
            if level == .full { return .autoApprove }
            guard let workspace else { return .askUser }
            return ShellClassifier.isWorkspaceSafe(command, workspace: workspace) ? .autoApprove : .askUser

        case "write_file":
            guard let path = input.string("path") else { return .askUser }
            if ShellClassifier.isSensitivePath(path) { return .askUser }
            let url = PathUtil.resolve(path, base: context.baseDir)
            let insideWorkspace = workspace.map { PathUtil.isInside(url, directory: $0) } ?? false
            if !insideWorkspace && ShellClassifier.isSystemPath(url.path) { return .askUser }
            if level == .full { return .autoApprove }
            return insideWorkspace ? .autoApprove : .askUser

        default:
            // Browser actions, MCP tools and anything else: only full trust skips the card.
            return level == .full ? .autoApprove : .askUser
        }
    }
}
