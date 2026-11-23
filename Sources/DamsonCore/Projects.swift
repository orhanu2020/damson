import Foundation

// MARK: - The delivery process
//
//   brief -> Business Analysis (analysis and requirements) -> Design (design) -> Dev (build) -> Dev (review)
//         -> [approval] -> Platform (provision qa) -> Deployment (deploy qa) -> Test (test qa)
//         -> [approval] -> Platform (provision uat) -> Deployment (deploy uat) -> Test (test uat)
//         -> [approval] -> Platform (provision production) -> Deployment (deploy production)
//
// Teams never talk to each other directly: each step reads the files earlier steps left in the project folder
// and writes its own. Reports go to reports/. Platform and Deployment are general teams, not tied to the SDLC:
// what they do depends on each environment's settings (local, local Docker, AWS, Azure, GCP).
// "approval" steps are gates only the user can pass.

/// The teams that take part. Each is found by name, so users may name their teams as they like.
public enum TeamRole: String, Codable, CaseIterable, Sendable, Identifiable {
    case businessAnalysis, design, dev, test, deployment, platform
    public var id: String { rawValue }

    /// "projectManagement" (removed) is read as business analysis.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "projectManagement" ? .businessAnalysis : (TeamRole(rawValue: raw) ?? .businessAnalysis)
    }

    public var title: String {
        switch self {
        case .businessAnalysis: return "Business Analysis"
        case .design: return "Design"
        case .dev: return "Development"
        case .platform: return "Platform"
        case .deployment: return "Deployment"
        case .test: return "Test"
        }
    }

    /// Words that identify the team (matched against the team name, ignoring case and accents).
    var keywords: [String] {
        switch self {
        case .businessAnalysis: return ["business", "analy", "analiz", "requirement"]
        case .design: return ["design", "architect", "tasarim", "ux"]
        case .dev: return ["dev", "engineer", "software", "yazilim"]
        case .platform: return ["platform", "infra", "sre", "ops"]
        case .deployment: return ["deploy", "release"]
        case .test: return ["test", "qa", "quality"]
        }
    }

    /// Words that should not count, so "Dev" is not taken for "DevOps" or "Deployment" and so on.
    var excluded: [String] {
        switch self {
        case .dev: return ["test", "qa", "analy", "analiz", "business", "design", "architect", "ops", "deploy", "release", "platform", "infra"]
        case .platform: return ["deploy", "release"]
        default: return []
        }
    }
}

public enum StepKind: String, Codable, Sendable {
    case requirements, design, build, review, approval, provision, deploy, test
    /// A step the user defines: any team or agent, any instruction.
    case task

    /// "estimate" (removed) is read as design.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = StepKind(rawValue: raw == "estimate" ? "design" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown step kind \(raw)"))
        }
        self = kind
    }

    public static let palette: [StepKind] = [.requirements, .design, .build, .review, .approval, .provision, .deploy, .test, .task]

    public var label: String {
        switch self {
        case .requirements: return "Requirements"
        case .design: return "Design"
        case .build: return "Development"
        case .review: return "Code review"
        case .approval: return "Human approval"
        case .provision: return "Provision environment"
        case .deploy: return "Deploy"
        case .test: return "Test"
        case .task: return "Custom task"
        }
    }

    /// Steps that are about an environment.
    public var usesEnvironment: Bool { [.approval, .provision, .deploy, .test].contains(self) }

    public var role: TeamRole? {
        switch self {
        case .requirements: return .businessAnalysis
        case .design: return .design
        case .build, .review: return .dev
        case .approval, .task: return nil
        case .provision: return .platform
        case .deploy: return .deployment
        case .test: return .test
        }
    }

    public var icon: String {
        switch self {
        case .requirements: return "doc.text.magnifyingglass"
        case .design: return "pencil.and.ruler.fill"
        case .build: return "hammer.fill"
        case .review: return "eye.fill"
        case .approval: return "hand.raised.fill"
        case .provision: return "server.rack"
        case .deploy: return "shippingbox.fill"
        case .test: return "checkmark.seal.fill"
        case .task: return "gearshape.fill"
        }
    }

    /// Steps whose report may say FAILED. If it does, the flow stops. (A failing test report does not stop it:
    /// the user decides at the next approval.)
    public var stopsOnBadVerdict: Bool {
        switch self {
        case .review, .provision, .deploy: return true
        default: return false
        }
    }
}

public enum StepStatus: String, Codable, Sendable {
    case pending, running, waiting, done, failed, rejected
    /// Not run because the branch leading here was not taken.
    case skipped
}

public struct FlowStep: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: StepKind
    /// The environment this step is about (qa, uat, production), if any.
    public var env: String?
    public var status: StepStatus = .pending
    public var agentName: String = ""
    public var summary: String = ""
    public var error: String = ""
    /// What the user wrote when deciding a gate.
    public var note: String = ""
    /// A name the user gave the step (empty: the default title).
    public var name: String = ""
    /// Where the step sits on the process canvas.
    public var x: Double = 0
    public var y: Double = 0
    /// For custom tasks: the team that does it, or one specific agent.
    public var customRole: TeamRole?
    /// The agents who do the step, in order (the next one improves on the previous one's work).
    /// Empty: the first agent of the step's team.
    public var agentIDs: [String] = []
    public var agentID: String? {
        get { agentIDs.first }
        set { agentIDs = newValue.map { [$0] } ?? [] }
    }
    /// More instructions from the user, added to the step's own.
    public var extra: String = ""
    /// For custom tasks: the file the result goes to (empty: reports/<id>.md).
    public var outputName: String = ""
    /// The report this step wrote says FAILED. Edges marked "on fail" are followed.
    public var badVerdict: Bool = false
    /// Rework: which round this step is on (0 = first time) and the report it has to act on.
    public var round: Int = 0
    public var feedback: String = ""
    /// A description for people (shown on the canvas); for approvals it is what the user is asked to check.
    public var about: String = ""

    public init(kind: StepKind, env: String? = nil, id: String? = nil) {
        self.kind = kind
        self.env = env
        self.id = id ?? env.map { "\(kind.rawValue)-\($0)" } ?? kind.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, env, status, agentName, summary, error, note, name, x, y, customRole, agentIDs, extra, outputName, badVerdict, round, feedback, about
    }

    private enum LegacyKeys: String, CodingKey { case agentID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(StepKind.self, forKey: .kind)
        env = try c.decodeIfPresent(String.self, forKey: .env)
        status = try c.decodeIfPresent(StepStatus.self, forKey: .status) ?? .pending
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        customRole = try c.decodeIfPresent(TeamRole.self, forKey: .customRole)
        if let list = try c.decodeIfPresent([String].self, forKey: .agentIDs) {
            agentIDs = list
        } else if let old = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .agentID) {
            agentIDs = [old]
        }
        extra = try c.decodeIfPresent(String.self, forKey: .extra) ?? ""
        outputName = try c.decodeIfPresent(String.self, forKey: .outputName) ?? ""
        badVerdict = try c.decodeIfPresent(Bool.self, forKey: .badVerdict) ?? false
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        feedback = try c.decodeIfPresent(String.self, forKey: .feedback) ?? ""
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
    }

    /// The team that does the step (nil for approvals and for tasks given to one agent).
    public var role: TeamRole? { kind == .task ? customRole : kind.role }

    public var title: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let e = env ?? ""
        switch kind {
        case .requirements: return "Requirements"
        case .design: return "Design"
        case .build: return "Development"
        case .review: return "Code review"
        case .approval: return e.isEmpty ? "Approval" : "Approval to move to \(e)"
        case .provision: return e.isEmpty ? "Provision environment" : "Provision \(e)"
        case .deploy: return e.isEmpty ? "Deploy" : "Deploy to \(e)"
        case .test: return e.isEmpty ? "Test" : "Test in \(e)"
        case .task: return "Task"
        }
    }

    /// The file this step must leave behind (relative to the project folder). Approvals leave none.
    public var outputFile: String? {
        let e = env ?? ""
        switch kind {
        case .requirements: return "handoff/01-analysis-and-requirements.md"
        case .design: return "handoff/02-design.md"
        case .build: return "handoff/03-build-notice.md"
        case .review: return "reports/review-report.md"
        case .approval: return nil
        case .provision: return "environments/\(e.isEmpty ? id : e).md"
        case .deploy: return "deploy/\(e.isEmpty ? id : e)-notice.md"
        case .test: return "reports/\(e.isEmpty ? id : e)-test-report.md"
        case .task: return outputName.trimmingCharacters(in: .whitespaces).isEmpty ? "reports/\(id).md" : outputName
        }
    }
}

/// When an edge is followed: after any outcome, only when the step did not report a failure, or only when it did.
public enum EdgeCondition: String, Codable, CaseIterable, Sendable {
    case always, pass, fail
    public var label: String {
        switch self {
        case .always: return "Always"
        case .pass: return "On pass"
        case .fail: return "On fail"
        }
    }
}

/// Which side of a step an arrow starts or ends at.
public enum FlowSide: String, Codable, CaseIterable, Sendable {
    case top, right, bottom, left
    public var label: String { rawValue.capitalized }
}

public struct FlowEdge: Codable, Identifiable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var condition: EdgeCondition = .always
    /// A loop back to an earlier step (always "on fail"): the work goes back for rework, at most `ProjectFlow.maxLoops` times.
    public var loop: Bool = false
    /// How many times this loop has been taken.
    public var rounds: Int = 0
    /// Text shown on the arrow.
    public var label: String = ""
    /// Where the arrow leaves the first step and enters the second (nil: automatic, right to left).
    public var fromSide: FlowSide?
    public var toSide: FlowSide?
    public var id: String { "\(from)->\(to)" }

    public init(from: String, to: String, condition: EdgeCondition = .always, loop: Bool = false) {
        self.from = from; self.to = to; self.condition = loop ? .fail : condition; self.loop = loop
    }

    enum CodingKeys: String, CodingKey { case from, to, condition, loop, rounds, label, fromSide, toSide }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        condition = try c.decodeIfPresent(EdgeCondition.self, forKey: .condition) ?? .always
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        fromSide = try c.decodeIfPresent(FlowSide.self, forKey: .fromSide)
        toSide = try c.decodeIfPresent(FlowSide.self, forKey: .toSide)
    }
}

/// A free note on the process canvas (documentation only, never run).
public struct FlowNote: Codable, Identifiable, Equatable, Sendable {
    public enum Color: String, Codable, CaseIterable, Sendable { case yellow, blue, green, pink }
    public var id: String
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double = 200
    public var height: Double = 110
    public var color: Color = .yellow

    public init(id: String = UUID().uuidString, text: String = "", x: Double, y: Double) {
        self.id = id; self.text = text; self.x = x; self.y = y
    }
}

// MARK: - Environments

public enum DeployTarget: String, Codable, CaseIterable, Sendable, Identifiable {
    case local, localDocker, aws, azure, gcp
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: return "Local (no containers)"
        case .localDocker: return "Local Docker"
        case .aws: return "AWS"
        case .azure: return "Azure"
        case .gcp: return "Google Cloud"
        }
    }

    public struct Option: Sendable { public let key: String; public let label: String; public let placeholder: String }

    /// The settings this target offers.
    public var options: [Option] {
        switch self {
        case .local:
            return [Option(key: "start", label: "Start command", placeholder: "python3 app/main.py"),
                    Option(key: "port", label: "Port", placeholder: "8080")]
        case .localDocker:
            return [Option(key: "compose", label: "Compose file", placeholder: "docker-compose.yml"),
                    Option(key: "container", label: "Container name", placeholder: "app-qa"),
                    Option(key: "port", label: "Host port", placeholder: "8080")]
        case .aws:
            return [Option(key: "profile", label: "AWS CLI profile", placeholder: "default"),
                    Option(key: "region", label: "Region", placeholder: "eu-west-1"),
                    Option(key: "service", label: "Service", placeholder: "ECS Fargate, App Runner, EC2, Lambda ..."),
                    Option(key: "stack", label: "Stack or resource prefix", placeholder: "myapp-qa")]
        case .azure:
            return [Option(key: "subscription", label: "Subscription", placeholder: "subscription name or id"),
                    Option(key: "region", label: "Region", placeholder: "westeurope"),
                    Option(key: "service", label: "Service", placeholder: "Container Apps, App Service, AKS ..."),
                    Option(key: "resourceGroup", label: "Resource group", placeholder: "myapp-qa-rg")]
        case .gcp:
            return [Option(key: "project", label: "Project id", placeholder: "my-gcp-project"),
                    Option(key: "region", label: "Region", placeholder: "europe-west1"),
                    Option(key: "service", label: "Service", placeholder: "Cloud Run, GKE, Compute Engine ..."),
                    Option(key: "prefix", label: "Resource prefix", placeholder: "myapp-qa")]
        }
    }

    /// What the Platform and Deployment agents are told about this kind of target.
    var guidance: String {
        switch self {
        case .local:
            return "Run the application directly on this Mac with the shell, in the background, on the configured port. Record how it was started (command, PID, port) so it can be stopped."
        case .localDocker:
            return "Use Docker on this Mac (docker and docker compose via the shell). Write a Dockerfile and the compose file in app/ if they are missing. Verify with docker ps and a request to the host port. If docker is not installed or not running, stop and report FAILED with that reason."
        case .aws:
            return "Use the aws CLI with the given profile and region. Check what already exists before creating anything (never create duplicates), use the AWS skills you have, keep the footprint small, and note anything that costs money. If the CLI is missing or not signed in, stop and report FAILED."
        case .azure:
            return "Use the az CLI with the given subscription, region and resource group. Check what already exists before creating anything, keep the footprint small, and note anything that costs money. If az is missing or not signed in, stop and report FAILED."
        case .gcp:
            return "Use the gcloud CLI with the given project and region. Check what already exists before creating anything, keep the footprint small, and note anything that costs money. If gcloud is missing or not signed in, stop and report FAILED."
        }
    }
}

public struct EnvSettings: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var target: DeployTarget
    public var options: [String: String]
    public var id: String { name }

    public init(name: String, target: DeployTarget = .localDocker, options: [String: String] = [:]) {
        self.name = name
        self.target = target
        self.options = options
    }

    /// "Local Docker (compose: docker-compose.yml, port: 8081)" for prompts and screens.
    public var summary: String {
        let parts = target.options.compactMap { o -> String? in
            guard let v = options[o.key], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return "\(o.label): \(v)"
        }
        return parts.isEmpty ? target.title : "\(target.title) (\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Project

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The high-level requirements the business analysis agent works from.
    public var brief: String
    public var folder: String
    public var createdAt: Date
    /// The process: steps are the nodes, edges the connections.
    public var steps: [FlowStep]
    public var edges: [FlowEdge]
    public var environments: [EnvSettings]
    /// The teams working on this project (empty: all teams) and extra individual agents.
    public var teamIDs: [String] = []
    public var agentIDs: [String] = []
    public var notes: [FlowNote] = []

    public init(id: String = UUID().uuidString, name: String, brief: String, folder: String) {
        self.id = id
        self.name = name
        self.brief = brief
        self.folder = folder
        self.createdAt = Date()
        self.environments = ProjectFlow.environmentNames.map { EnvSettings(name: $0) }
        self.steps = ProjectFlow.defaultSteps(environments: ProjectFlow.environmentNames)
        self.edges = ProjectFlow.chain(steps)
    }

    enum CodingKeys: String, CodingKey { case id, name, brief, folder, createdAt, steps, edges, environments, teamIDs, agentIDs, notes }

    /// Older projects get the standard process (not started) or, if they have steps but no layout, the steps in a chain.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        brief = try c.decode(String.self, forKey: .brief)
        folder = try c.decode(String.self, forKey: .folder)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        environments = try c.decodeIfPresent([EnvSettings].self, forKey: .environments) ?? ProjectFlow.environmentNames.map { EnvSettings(name: $0) }
        var loaded = try c.decodeIfPresent([FlowStep].self, forKey: .steps) ?? ProjectFlow.defaultSteps(environments: environments.map { $0.name })
        if loaded.allSatisfy({ $0.x == 0 && $0.y == 0 }) { ProjectFlow.arrange(&loaded) }
        steps = loaded
        edges = try c.decodeIfPresent([FlowEdge].self, forKey: .edges) ?? ProjectFlow.chain(loaded)
        teamIDs = try c.decodeIfPresent([String].self, forKey: .teamIDs) ?? []
        agentIDs = try c.decodeIfPresent([String].self, forKey: .agentIDs) ?? []
        notes = try c.decodeIfPresent([FlowNote].self, forKey: .notes) ?? []
    }

    public var folderURL: URL { URL(fileURLWithPath: folder) }
    public var isFinished: Bool { !steps.isEmpty && steps.allSatisfy { $0.status == .done || $0.status == .skipped } }
    public func environment(_ name: String) -> EnvSettings { environments.first { $0.name == name } ?? EnvSettings(name: name) }
    public func step(_ id: String) -> FlowStep? { steps.first { $0.id == id } }
    public func usesTeam(_ id: String) -> Bool { teamIDs.isEmpty || teamIDs.contains(id) }

    /// The report a gate asks the user to read: the closest earlier review or test report (following the edges back).
    public func reportBefore(_ index: Int) -> String? {
        guard steps.indices.contains(index) else { return nil }
        var seen = Set<String>()
        var queue = [steps[index].id]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for e in edges where !e.loop && e.to == id && seen.insert(e.from).inserted {
                if let s = step(e.from) {
                    if s.kind == .review || s.kind == .test { return s.outputFile }
                    queue.append(s.id)
                }
            }
        }
        return nil
    }

    // MARK: Editing the process

    /// Adds a step with a unique id at a canvas position and returns its id.
    @discardableResult
    public mutating func addStep(kind: StepKind, env: String? = nil, at point: CGPoint) -> String {
        let environment = kind.usesEnvironment ? (env ?? environments.first?.name) : nil
        var step = FlowStep(kind: kind, env: environment)
        var candidate = step.id
        var n = 2
        while steps.contains(where: { $0.id == candidate }) { candidate = "\(step.id)-\(n)"; n += 1 }
        step = FlowStep(kind: kind, env: environment, id: candidate)
        step.x = Double(point.x)
        step.y = Double(point.y)
        steps.append(step)
        return candidate
    }

    public mutating func removeStep(_ id: String) {
        steps.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id }
    }

    /// The steps in process order: following the connections, ties broken by position on the canvas.
    public var orderedSteps: [FlowStep] {
        var remaining = steps
        var done = Set<String>()
        var result: [FlowStep] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { s in edges.filter { !$0.loop && $0.to == s.id }.allSatisfy { done.contains($0.from) || step($0.from) == nil } }
            let next = (ready.isEmpty ? remaining : ready).min { ($0.y, $0.x) < ($1.y, $1.x) }!
            result.append(next); done.insert(next.id)
            remaining.removeAll { $0.id == next.id }
        }
        return result
    }

    /// A copy of a step (without progress) next to the original. Returns the new id.
    @discardableResult
    public mutating func duplicateStep(_ id: String) -> String? {
        guard let original = step(id) else { return nil }
        let newID = addStep(kind: original.kind, env: original.env, at: CGPoint(x: original.x + 40, y: original.y + 40))
        if let i = steps.firstIndex(where: { $0.id == newID }) {
            steps[i].name = original.name; steps[i].customRole = original.customRole; steps[i].agentIDs = original.agentIDs
            steps[i].extra = original.extra; steps[i].outputName = original.outputName; steps[i].about = original.about
        }
        return newID
    }

    /// Puts a new step in the middle of a connection: a -> new -> b.
    @discardableResult
    public mutating func insertStep(kind: StepKind, on edgeID: String) -> String? {
        guard let i = edges.firstIndex(where: { $0.id == edgeID }), !edges[i].loop,
              let a = step(edges[i].from), let b = step(edges[i].to) else { return nil }
        let edge = edges.remove(at: i)
        let id = addStep(kind: kind, env: b.env ?? a.env, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 20))
        var first = FlowEdge(from: a.id, to: id, condition: edge.condition)
        first.label = edge.label
        edges.append(first)
        edges.append(FlowEdge(from: id, to: b.id))
        return id
    }

    /// True if connecting `from` to `to` would close a loop (following the ordinary connections).
    public func wouldCycle(from: String, to: String) -> Bool {
        if from == to { return true }
        var seen = Set<String>()
        var stack = [to]
        while let id = stack.popLast() {
            if id == from { return true }
            guard seen.insert(id).inserted else { continue }
            stack += edges.filter { !$0.loop && $0.from == id }.map { $0.to }
        }
        return false
    }

    /// Connects two steps. Returns false for a duplicate or a missing step. A connection back to an earlier step
    /// becomes a rework loop.
    @discardableResult
    public mutating func connect(from: String, to: String, condition: EdgeCondition = .always, fromSide: FlowSide? = nil, toSide: FlowSide? = nil) -> Bool {
        guard step(from) != nil, step(to) != nil, !edges.contains(where: { $0.from == from && $0.to == to }), from != to else { return false }
        // Connecting a step back to an earlier one makes a rework loop (on fail), not an ordinary connection.
        var edge = FlowEdge(from: from, to: to, condition: condition, loop: wouldCycle(from: from, to: to))
        edge.fromSide = fromSide
        edge.toSide = toSide
        edges.append(edge)
        return true
    }

    /// Moves one or both ends of a connection to another step or another side. Returns false (and changes nothing)
    /// if the result would be a duplicate or a connection to itself.
    @discardableResult
    public mutating func reconnect(_ edgeID: String, from: String? = nil, to: String? = nil, fromSide: FlowSide?, toSide: FlowSide?) -> String? {
        guard let i = edges.firstIndex(where: { $0.id == edgeID }) else { return nil }
        let old = edges.remove(at: i)
        let newFrom = from ?? old.from, newTo = to ?? old.to
        guard step(newFrom) != nil, step(newTo) != nil, newFrom != newTo,
              !edges.contains(where: { $0.from == newFrom && $0.to == newTo }) else {
            edges.insert(old, at: i)
            return nil
        }
        var edge = FlowEdge(from: newFrom, to: newTo, condition: old.condition, loop: wouldCycle(from: newFrom, to: newTo))
        edge.label = old.label; edge.rounds = old.loop == edge.loop ? old.rounds : 0
        edge.fromSide = fromSide; edge.toSide = toSide
        edges.insert(edge, at: i)
        return edge.id
    }

    /// The step and everything after it.
    public func downstream(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        var stack = [id]
        while let n = stack.popLast() {
            for e in edges where !e.loop && e.from == n && result.insert(e.to).inserted { stack.append(e.to) }
        }
        return result
    }
}

public enum Verdict: Equatable, Sendable { case pass, fail, unknown }

public enum ProjectFlow {
    static func fold(_ s: String) -> String { CompanyCommandParser.fold(s) }

    public static let environmentNames = ["qa", "uat", "production"]
    public static let folders = ["handoff", "app", "tests", "environments", "deploy", "reports"]

    /// brief -> requirements -> design -> build -> review, then for each environment:
    /// approval, provision, deploy (and test, except in the last environment).
    public static func defaultSteps(environments: [String]) -> [FlowStep] {
        var steps = [FlowStep(kind: .requirements), FlowStep(kind: .design), FlowStep(kind: .build), FlowStep(kind: .review)]
        for (i, env) in environments.enumerated() {
            steps += [FlowStep(kind: .approval, env: env), FlowStep(kind: .provision, env: env), FlowStep(kind: .deploy, env: env)]
            if i < environments.count - 1 { steps.append(FlowStep(kind: .test, env: env)) }
        }
        arrange(&steps)
        return steps
    }

    public static let columnWidth = 210.0
    public static let rowHeight = 170.0

    /// Lays steps out in rows of four, in order.
    public static func arrange(_ steps: inout [FlowStep]) {
        // The first row holds the four build steps; every environment starts a new row.
        var row = 0, col = 0
        var lastEnv: String?
        for i in steps.indices {
            let env = steps[i].env
            if i > 0 && (col >= 4 || (env != nil && env != lastEnv && steps[i].kind == .approval)) { row += 1; col = 0 }
            steps[i].x = 40 + Double(col) * columnWidth
            steps[i].y = 40 + Double(row) * rowHeight
            col += 1
            if env != nil { lastEnv = env }
        }
    }

    /// How many times a review or test may send the work back to Dev.
    public static let maxLoops = 3

    /// The steps in a line, each followed by the next. After a review or a test the line continues only when it passed;
    /// when it failed, the work goes back to the Dev build step (up to `maxLoops` times).
    public static func chain(_ steps: [FlowStep]) -> [FlowEdge] {
        var edges = zip(steps, steps.dropFirst()).map { a, b in
            FlowEdge(from: a.id, to: b.id, condition: (a.kind == .review || a.kind == .test) ? .pass : .always)
        }
        if let build = steps.first(where: { $0.kind == .build }) {
            for step in steps where (step.kind == .review || step.kind == .test) && step.id != build.id {
                edges.append(FlowEdge(from: step.id, to: build.id, loop: true))
            }
        }
        return edges
    }

    private enum EdgeState { case open, dead, unresolved, blocked }

    private static func state(of edge: FlowEdge, in project: Project) -> EdgeState {
        guard let source = project.step(edge.from) else { return .dead }
        switch source.status {
        case .done:
            let taken = edge.condition == .always || (edge.condition == .pass) == !source.badVerdict
            return taken ? .open : .dead
        case .skipped: return .dead
        case .failed, .rejected: return .blocked
        case .pending, .running, .waiting: return .unresolved
        }
    }

    /// Pending steps that can run now: no incoming edge, or all incoming edges decided and at least one taken.
    public static func ready(in project: Project) -> [String] {
        project.steps.filter { step in
            guard step.status == .pending else { return false }
            let states = project.edges.filter { !$0.loop && $0.to == step.id }.map { state(of: $0, in: project) }
            if states.isEmpty { return true }
            return !states.contains(.blocked) && !states.contains(.unresolved) && states.contains(.open)
        }.map { $0.id }
    }

    /// Pending steps that will never run because every branch leading to them was not taken.
    public static func toSkip(in project: Project) -> [String] {
        project.steps.filter { step in
            guard step.status == .pending else { return false }
            let states = project.edges.filter { !$0.loop && $0.to == step.id }.map { state(of: $0, in: project) }
            return !states.isEmpty && states.allSatisfy { $0 == .dead }
        }.map { $0.id }
    }

    /// The team for a role, found by name.
    public static func team(for role: TeamRole, in company: Company) -> Team? {
        for team in company.teams {
            let name = fold(team.name)
            if role.excluded.contains(where: { name.contains($0) }) { continue }
            if role.keywords.contains(where: { name.contains($0) }) { return team }
        }
        return nil
    }

    /// The agent that does a step. Review is done by a different Dev agent than the build when there is one.
    /// Everybody who does a step, in order: the agents chosen for it, or else the team's default agent.
    public static func agents(for step: FlowStep, in company: Company) -> [(team: Team, person: Person)] {
        if step.agentIDs.isEmpty { return agent(for: step, in: company).map { [$0] } ?? [] }
        return step.agentIDs.compactMap { id in
            for team in company.teams { if let person = team.members.first(where: { $0.id == id }) { return (team, person) } }
            return nil
        }
    }

    /// The capabilities agents are grouped by.
    public static var capabilities: [String] { TeamRole.allCases.map { $0.title } }

    /// What an agent is good at: the one set on the agent, else the role of the team it is in, else "General".
    public static func capability(of person: Person, in company: Company) -> String {
        if !person.capability.trimmingCharacters(in: .whitespaces).isEmpty {
            return person.capability.caseInsensitiveCompare("dev") == .orderedSame ? "Development" : person.capability
        }
        for role in TeamRole.allCases {
            if let team = team(for: role, in: company), team.members.contains(where: { $0.id == person.id }) { return role.title }
        }
        return "General"
    }

    public static func agent(for step: FlowStep, in company: Company) -> (team: Team, person: Person)? {
        if let id = step.agentID {
            for team in company.teams { if let person = team.members.first(where: { $0.id == id }) { return (team, person) } }
            return nil
        }
        // No agent chosen: the first agent with the step's capability (review prefers a second one).
        guard let role = step.role else { return nil }
        let pool = company.teams.flatMap { t in t.members.map { (team: t, person: $0) } }
            .filter { capability(of: $0.person, in: company).caseInsensitiveCompare(role.title) == .orderedSame }
        guard !pool.isEmpty else { return nil }
        return (step.kind == .review && pool.count > 1) ? pool[1] : pool[0]
    }

    public static func slug(_ name: String) -> String {
        let s = fold(name).map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "project" : joined
    }

    /// Reads the closing line of a report: "Verdict: PASS", "Status: FAILED", "Verdict: CHANGES REQUESTED" ...
    /// Only lines that start with "Verdict:" or "Status:" count (markdown marks allowed), and the last one wins,
    /// so ordinary sentences that mention a status are ignored.
    public static func verdict(of report: String) -> Verdict {
        for line in report.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "*#>-_ \t`"))
            let l = trimmed.lowercased()
            guard l.hasPrefix("verdict") || l.hasPrefix("status"), let colon = l.firstIndex(of: ":") else { continue }
            let value = l[l.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t`"))
            if ["fail", "changes", "reject", "blocked", "not "].contains(where: { value.contains($0) }) { return .fail }
            if ["pass", "approved", "ready", "deployed", "success"].contains(where: { value.contains($0) }) { return .pass }
        }
        return .unknown
    }

    // MARK: Instructions

    private static func header(_ project: Project) -> String {
        """
        You are working on the project "\(project.name)". Your working directory is the project folder; use relative paths.
        Folders: handoff/ (analysis and requirements, design, build notice), app/ (application source), tests/ (automated tests), environments/ (one file per environment: how it is provisioned and reached), deploy/ (one deploy notice per environment), reports/ (review and test reports, release report).
        Do the job with your tools, thoroughly. Do not ask the user questions; where something is unclear, make a reasonable assumption and write it down.
        When you are done, reply with a short plain summary (3 to 6 sentences) of what you produced.

        """
    }

    /// What the agent is told to do for a step. Everything it needs comes from files, not from another team's chat.
    public static func instruction(for step: FlowStep, project: Project) -> String {
        var base = baseInstruction(for: step, project: project)
        if step.round > 0, !step.feedback.isEmpty, step.kind != .approval {
            base += """


            REWORK ROUND \(step.round) OF \(maxLoops). Your earlier work came back: \(step.feedback) reports problems.
            Read \(step.feedback) first. Fix every problem it lists (code in app/, tests in tests/), run everything again, and update your own output file so it says what you changed in this round and why.
            """
        }
        let extra = step.extra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty, step.kind != .task, step.kind != .approval else { return base }
        return base + "\n\nADDITIONAL INSTRUCTIONS FROM THE USER:\n" + extra
    }

    private static func baseInstruction(for step: FlowStep, project: Project) -> String {
        let h = header(project)
        let e = step.env ?? ""
        let env = project.environment(e)
        let envBlock = """
        ENVIRONMENT: \(e). Deployment target: \(env.summary).
        \(env.target.guidance)
        The settings above are the user's choices: use them exactly. Where a setting is empty, choose a sensible default and write it down.

        """
        switch step.kind {
        case .requirements:
            return h + """
            YOUR ROLE: business analysis. Analyse the business brief and write the analysis and requirements document for the application.
            1. Read handoff/00-brief.md.
            2. Write handoff/01-analysis-and-requirements.md in Markdown with these sections: Business analysis (problem, goals, users and stakeholders, current process, scope); Overview and goals; Users and stakeholders; Functional requirements (numbered REQ-001, REQ-002 ... each one testable); Non-functional requirements; Acceptance criteria per requirement; Out of scope; Assumptions and open questions.
            The Design team designs from this file, Dev builds from it, and Test will derive tests from it, so make it precise and complete.
            """
        case .design:
            return h + """
            YOUR ROLE: design. Turn the analysis and requirements document into a design Dev can build from.
            1. Read handoff/01-analysis-and-requirements.md (and handoff/00-brief.md for context).
            2. Write handoff/02-design.md in Markdown with: solution overview; architecture and main components; technology stack with reasons; data model; interfaces (screens or API endpoints) with the main flows; how each requirement (REQ id) is covered; security and error handling approach; how it is built, run and containerised; risks and open decisions.
            Dev will build from this file together with the requirements, so be concrete and keep it consistent with the REQ ids.
            """
        case .build:
            return h + """
            YOUR ROLE: development. Build the application that fulfils the requirements. Do not deploy it: another team does that.
            1. Read handoff/01-analysis-and-requirements.md and handoff/02-design.md. Follow the design; where you must deviate, say why in the build notice.
            2. Implement the application in app/. Choose a simple, dependable stack. Include a Dockerfile and a docker-compose.yml so it can run in a container. Run or build it to check that it works, and add unit tests.
            3. Write handoff/03-build-notice.md: version; which requirements (REQ ids) are implemented and which are not; how to build and run it; configuration it needs; known limitations.
            """
        case .review:
            return h + """
            YOUR ROLE: code review. Review the code in app/ against handoff/01-analysis-and-requirements.md. Read handoff/03-build-notice.md first.
            Check correctness, requirement coverage, error handling, security, tests, and that it builds and runs. Fix problems you find directly in the code, and run it again afterwards.
            Write reports/review-report.md in Markdown: what you reviewed; findings and what you fixed; remaining issues; then a last line exactly like "Verdict: APPROVED" or "Verdict: CHANGES REQUESTED" (only if a real problem remains that you could not fix).
            """
        case .approval:
            return ""
        case .task:
            let file = step.outputFile ?? "reports/\(step.id).md"
            let extra = step.extra.trimmingCharacters(in: .whitespacesAndNewlines)
            return h + """
            YOUR TASK: \(step.title).
            \(extra.isEmpty ? "No further instructions were given: do what the title says, using the files in the project folder." : extra)
            Earlier steps leave their results in handoff/, reports/, environments/ and deploy/; read what you need.
            Write your result to \(file). If your task is a check that can fail, end the file with a last line exactly like "Verdict: PASS" or "Verdict: FAIL".
            """
        case .provision:
            return h + envBlock + """
            YOUR ROLE: platform engineering. Make sure the \(e) environment exists and is ready to receive the application. If it already exists, check it and change nothing that works. Do not deploy the application: Deployment does that.
            1. Read handoff/03-build-notice.md for what the application needs (runtime, ports, services, configuration).
            2. Provision or verify the environment for this target: runtime, network, storage, access, configuration and monitoring as needed.
            3. Write environments/\(e).md: what exists, how it is reached (URLs, ports, names), how to inspect and stop it, what you created or found, and anything that costs money.
            End the file with a last line exactly like "Status: READY" or "Status: FAILED" (then explain the reason above it).
            """
        case .deploy:
            let production = project.steps.last(where: { $0.kind == .deploy })?.id == step.id
            return h + envBlock + """
            YOUR ROLE: deployment. Deploy the reviewed application from app/ to the \(e) environment, which Platform has prepared (read environments/\(e).md; if it says FAILED or is missing, stop and report FAILED).
            1. Read handoff/03-build-notice.md, reports/review-report.md and environments/\(e).md.
            2. Deploy this version, then check that it is healthy (start-up, a request to its main endpoint, logs). If the deploy fails, try to roll back to the previous state.
            3. Write deploy/\(e)-notice.md for the next team: version deployed; how to reach it (URL or host and port); test data and logins if any; what was checked after deploying; rollback instructions.
            End the file with a last line exactly like "Status: DEPLOYED" or "Status: FAILED" (then explain the reason above it).
            \(production ? "4. This is production, the last step. Also write reports/production-release.md: a short release report (what was released, when, where, health checks, how to roll back), with the same Status line." : "")
            """
        case .test:
            return h + """
            YOUR ROLE: testing. Test the application deployed to \(e) and report.
            1. Read handoff/01-analysis-and-requirements.md and deploy/\(e)-notice.md.
            2. Create or extend automated tests in tests/ for the features (each test tied to a REQ id).
            3. Run them against the \(e) environment described in the deploy notice, using the shell. Record the real results.
            4. Write reports/\(e)-test-report.md in Markdown with: summary; environment and version tested; a table of test cases (REQ id, test, result); defects with steps to reproduce; requirements not covered; recommendations; and a last line exactly like "Verdict: PASS" or "Verdict: FAIL".
            Report only what you actually ran. Never claim a test passed that you did not run.
            """
        }
    }
}

// MARK: - Teams and agents of the process

public struct AgentPreset: Sendable {
    public let name: String, role: String, model: String
    public let skills: [String], tools: [String]
}

extension ProjectFlow {
    private static let fileTools = ["read_file", "write_file", "list_dir"]
    private static let workTools = ["shell", "read_file", "write_file", "list_dir"]

    /// Each team of the process with its agents: model, Claude skills (plugin skills as "plugin:skill") and the tools they need.
    public static let presets: [(role: TeamRole, agents: [AgentPreset])] = [
        (.businessAnalysis, [AgentPreset(name: "Emma Clarke", role: "Business Analyst", model: "claude-sonnet-5-5",
            skills: ["superpowers:brainstorming", "engineering:system-design"], tools: fileTools + ["web_fetch"])]),
        (.design, [AgentPreset(name: "Daniel Brooks", role: "Solution Designer", model: "claude-sonnet-5-5",
            skills: ["engineering:architecture", "engineering:system-design", "superpowers:writing-plans"], tools: fileTools)]),
        (.dev, [
            AgentPreset(name: "Alex Morgan", role: "Senior Developer", model: "claude-opus-5-5",
                skills: ["superpowers:test-driven-development", "superpowers:systematic-debugging", "superpowers:executing-plans"], tools: workTools),
            AgentPreset(name: "Sophie Turner", role: "Code Reviewer", model: "claude-sonnet-5-5",
                skills: ["superpowers:requesting-code-review", "engineering:code-review"], tools: workTools)]),
        (.platform, [AgentPreset(name: "Ryan Mitchell", role: "Platform Engineer", model: "claude-sonnet-5-5",
            skills: ["aws-cdk", "aws-cloudformation", "aws-compute", "aws-containers", "aws-networking", "aws-iam", "aws-security", "aws-observability"], tools: workTools)]),
        (.deployment, [AgentPreset(name: "Olivia Hayes", role: "Release Engineer", model: "claude-sonnet-5-5",
            skills: ["aws-deployment", "engineering:deploy-checklist", "engineering:incident-response"], tools: workTools)]),
        (.test, [AgentPreset(name: "Noah Bennett", role: "QA Engineer", model: "claude-sonnet-5-5",
            skills: ["engineering:testing-strategy", "superpowers:verification-before-completion"], tools: workTools)]),
    ]

    /// Creates missing teams and agents, and configures existing agents that have no skills yet.
    public static func applyPresets(to company: inout Company, knownSkills: Set<String>, allTools: [String], newID: () -> String) {
        func person(_ a: AgentPreset, _ role: TeamRole) -> Person {
            Person(id: newID(), name: a.name, role: a.role, skills: a.skills.filter { knownSkills.contains($0) },
                   model: a.model, disabledTools: allTools.filter { !a.tools.contains($0) }, capability: role.title)
        }
        for (role, agents) in presets {
            for a in agents {
                // An agent with the same name is the same agent: keep it (and give it its capability), never add a second one.
                if let ti = company.teams.firstIndex(where: { $0.members.contains { $0.name.caseInsensitiveCompare(a.name) == .orderedSame } }),
                   let mi = company.teams[ti].members.firstIndex(where: { $0.name.caseInsensitiveCompare(a.name) == .orderedSame }) {
                    if company.teams[ti].members[mi].capability.isEmpty { company.teams[ti].members[mi].capability = role.title }
                    if company.teams[ti].members[mi].skills.isEmpty {
                        let p = person(a, role)
                        company.teams[ti].members[mi].skills = p.skills
                        company.teams[ti].members[mi].disabledTools = p.disabledTools
                        company.teams[ti].members[mi].model = company.teams[ti].members[mi].model ?? p.model
                    }
                    continue
                }
                if let existing = team(for: role, in: company), let ti = company.teams.firstIndex(where: { $0.id == existing.id }),
                   company.teams[ti].members.count < Company.maxMembers {
                    company.teams[ti].members.append(person(a, role))
                } else if let ti = company.teams.firstIndex(where: { $0.members.count < Company.maxMembers }) {
                    company.teams[ti].members.append(person(a, role))
                } else if company.teams.count < Company.maxTeams {
                    company.teams.append(Team(id: newID(), name: role.title, members: [person(a, role)]))
                }
            }
        }
    }
}

/// Saves the project list.
public enum ProjectStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson/projects.json")
    }

    /// When projects.json was last written, so the app can notice changes made by someone else.
    public static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    public static func load() -> [Project] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Project].self, from: data)) ?? []
    }

    public static func save(_ projects: [Project]) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(projects) { try? data.write(to: url, options: .atomic) }
    }
}
