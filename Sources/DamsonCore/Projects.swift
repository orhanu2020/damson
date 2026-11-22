import Foundation

// MARK: - The delivery process
//
//   brief -> Business Analysis (requirements) -> Project Management (estimate) -> Dev (build) -> Dev (review)
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
    case businessAnalysis, projectManagement, dev, platform, deployment, test
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .businessAnalysis: return "Business Analysis"
        case .projectManagement: return "Project Management"
        case .dev: return "Dev"
        case .platform: return "Platform"
        case .deployment: return "Deployment"
        case .test: return "Test"
        }
    }

    /// Words that identify the team (matched against the team name, ignoring case and accents).
    var keywords: [String] {
        switch self {
        case .businessAnalysis: return ["business", "analy", "analiz", "requirement"]
        case .projectManagement: return ["project", "manage", "proje", "planning"]
        case .dev: return ["dev", "engineer", "software", "yazilim"]
        case .platform: return ["platform", "infra", "sre", "ops"]
        case .deployment: return ["deploy", "release"]
        case .test: return ["test", "qa", "quality"]
        }
    }

    /// Words that should not count, so "Dev" is not taken for "DevOps" or "Deployment" and so on.
    var excluded: [String] {
        switch self {
        case .dev: return ["test", "qa", "analy", "analiz", "business", "manage", "ops", "deploy", "release", "platform", "infra"]
        case .platform: return ["deploy", "release"]
        default: return []
        }
    }
}

public enum StepKind: String, Codable, Sendable {
    case requirements, estimate, build, review, approval, provision, deploy, test
    /// A step the user defines: any team or agent, any instruction.
    case task

    public static let palette: [StepKind] = [.requirements, .estimate, .build, .review, .approval, .provision, .deploy, .test, .task]

    public var label: String {
        switch self {
        case .requirements: return "Requirements"
        case .estimate: return "Estimates"
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
        case .estimate: return .projectManagement
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
        case .estimate: return "calendar.badge.clock"
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
    public var agentID: String?
    /// More instructions from the user, added to the step's own.
    public var extra: String = ""
    /// For custom tasks: the file the result goes to (empty: reports/<id>.md).
    public var outputName: String = ""
    /// The report this step wrote says FAILED. Edges marked "on fail" are followed.
    public var badVerdict: Bool = false

    public init(kind: StepKind, env: String? = nil, id: String? = nil) {
        self.kind = kind
        self.env = env
        self.id = id ?? env.map { "\(kind.rawValue)-\($0)" } ?? kind.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, env, status, agentName, summary, error, note, name, x, y, customRole, agentID, extra, outputName, badVerdict
    }

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
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        extra = try c.decodeIfPresent(String.self, forKey: .extra) ?? ""
        outputName = try c.decodeIfPresent(String.self, forKey: .outputName) ?? ""
        badVerdict = try c.decodeIfPresent(Bool.self, forKey: .badVerdict) ?? false
    }

    /// The team that does the step (nil for approvals and for tasks given to one agent).
    public var role: TeamRole? { kind == .task ? customRole : kind.role }

    public var title: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let e = env ?? ""
        switch kind {
        case .requirements: return "Requirements"
        case .estimate: return "Estimates"
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
        case .requirements: return "handoff/01-requirements.md"
        case .estimate: return "handoff/02-estimate.md"
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

public struct FlowEdge: Codable, Identifiable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var condition: EdgeCondition = .always
    public var id: String { "\(from)->\(to)" }
    public init(from: String, to: String, condition: EdgeCondition = .always) {
        self.from = from; self.to = to; self.condition = condition
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

    enum CodingKeys: String, CodingKey { case id, name, brief, folder, createdAt, steps, edges, environments, teamIDs, agentIDs }

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
            for e in edges where e.to == id && seen.insert(e.from).inserted {
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

    /// True if connecting `from` to `to` would close a loop (the process must stay a graph without cycles).
    public func wouldCycle(from: String, to: String) -> Bool {
        if from == to { return true }
        var seen = Set<String>()
        var stack = [to]
        while let id = stack.popLast() {
            if id == from { return true }
            guard seen.insert(id).inserted else { continue }
            stack += edges.filter { $0.from == id }.map { $0.to }
        }
        return false
    }

    /// Connects two steps. Returns false for a duplicate, a missing step or a loop.
    @discardableResult
    public mutating func connect(from: String, to: String, condition: EdgeCondition = .always) -> Bool {
        guard step(from) != nil, step(to) != nil, !edges.contains(where: { $0.from == from && $0.to == to }),
              !wouldCycle(from: from, to: to) else { return false }
        edges.append(FlowEdge(from: from, to: to, condition: condition))
        return true
    }

    /// The step and everything after it.
    public func downstream(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        var stack = [id]
        while let n = stack.popLast() {
            for e in edges where e.from == n && result.insert(e.to).inserted { stack.append(e.to) }
        }
        return result
    }
}

public enum Verdict: Equatable, Sendable { case pass, fail, unknown }

public enum ProjectFlow {
    static func fold(_ s: String) -> String { CompanyCommandParser.fold(s) }

    public static let environmentNames = ["qa", "uat", "production"]
    public static let folders = ["handoff", "app", "tests", "environments", "deploy", "reports"]

    /// brief -> requirements -> estimate -> build -> review, then for each environment:
    /// approval, provision, deploy (and test, except in the last environment).
    public static func defaultSteps(environments: [String]) -> [FlowStep] {
        var steps = [FlowStep(kind: .requirements), FlowStep(kind: .estimate), FlowStep(kind: .build), FlowStep(kind: .review)]
        for (i, env) in environments.enumerated() {
            steps += [FlowStep(kind: .approval, env: env), FlowStep(kind: .provision, env: env), FlowStep(kind: .deploy, env: env)]
            if i < environments.count - 1 { steps.append(FlowStep(kind: .test, env: env)) }
        }
        arrange(&steps)
        return steps
    }

    public static let columnWidth = 220.0
    public static let rowHeight = 120.0

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

    /// The steps in a line, each followed by the next.
    public static func chain(_ steps: [FlowStep]) -> [FlowEdge] {
        zip(steps, steps.dropFirst()).map { FlowEdge(from: $0.id, to: $1.id) }
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
            let states = project.edges.filter { $0.to == step.id }.map { state(of: $0, in: project) }
            if states.isEmpty { return true }
            return !states.contains(.blocked) && !states.contains(.unresolved) && states.contains(.open)
        }.map { $0.id }
    }

    /// Pending steps that will never run because every branch leading to them was not taken.
    public static func toSkip(in project: Project) -> [String] {
        project.steps.filter { step in
            guard step.status == .pending else { return false }
            let states = project.edges.filter { $0.to == step.id }.map { state(of: $0, in: project) }
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
    public static func agent(for step: FlowStep, in company: Company) -> (team: Team, person: Person)? {
        if let id = step.agentID {
            for team in company.teams { if let person = team.members.first(where: { $0.id == id }) { return (team, person) } }
            return nil
        }
        guard let role = step.role, let team = team(for: role, in: company), !team.members.isEmpty else { return nil }
        let person = (step.kind == .review && team.members.count > 1) ? team.members[1] : team.members[0]
        return (team, person)
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
        Folders: handoff/ (requirements, estimate, build notice), app/ (application source), tests/ (automated tests), environments/ (one file per environment: how it is provisioned and reached), deploy/ (one deploy notice per environment), reports/ (review and test reports, release report).
        Do the job with your tools, thoroughly. Do not ask the user questions; where something is unclear, make a reasonable assumption and write it down.
        When you are done, reply with a short plain summary (3 to 6 sentences) of what you produced.

        """
    }

    /// What the agent is told to do for a step. Everything it needs comes from files, not from another team's chat.
    public static func instruction(for step: FlowStep, project: Project) -> String {
        let base = baseInstruction(for: step, project: project)
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
            YOUR ROLE: business analysis. Turn the business brief into clear requirements for the application.
            1. Read handoff/00-brief.md.
            2. Write handoff/01-requirements.md in Markdown with these sections: Overview and goals; Users and stakeholders; Functional requirements (numbered REQ-001, REQ-002 ... each one testable); Non-functional requirements; Acceptance criteria per requirement; Out of scope; Assumptions and open questions.
            Dev will build only from this file, and Test will derive tests from it, so make it precise and complete.
            """
        case .estimate:
            return h + """
            YOUR ROLE: project management. Create the time and resource estimates.
            1. Read handoff/01-requirements.md.
            2. Write handoff/02-estimate.md in Markdown with: work breakdown (one line per requirement or group, effort in person-days); total effort; required roles and team size; milestones and a timeline in working days; main risks with mitigations; assumptions; your confidence level.
            """
        case .build:
            return h + """
            YOUR ROLE: development. Build the application that fulfils the requirements. Do not deploy it: another team does that.
            1. Read handoff/01-requirements.md and handoff/02-estimate.md.
            2. Implement the application in app/. Choose a simple, dependable stack. Include a Dockerfile and a docker-compose.yml so it can run in a container. Run or build it to check that it works, and add unit tests.
            3. Write handoff/03-build-notice.md: version; which requirements (REQ ids) are implemented and which are not; how to build and run it; configuration it needs; known limitations.
            """
        case .review:
            return h + """
            YOUR ROLE: code review. Review the code in app/ against handoff/01-requirements.md. Read handoff/03-build-notice.md first.
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
            1. Read handoff/01-requirements.md and deploy/\(e)-notice.md.
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
        (.projectManagement, [AgentPreset(name: "Daniel Brooks", role: "Project Manager", model: "claude-sonnet-5-5",
            skills: ["superpowers:writing-plans", "engineering:architecture"], tools: fileTools)]),
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
        func person(_ a: AgentPreset) -> Person {
            Person(id: newID(), name: a.name, role: a.role, skills: a.skills.filter { knownSkills.contains($0) },
                   model: a.model, disabledTools: allTools.filter { !a.tools.contains($0) })
        }
        for (role, agents) in presets {
            if let existing = team(for: role, in: company), let ti = company.teams.firstIndex(where: { $0.id == existing.id }) {
                for (i, a) in agents.enumerated() {
                    if i < company.teams[ti].members.count {
                        if company.teams[ti].members[i].skills.isEmpty {
                            let p = person(a)
                            company.teams[ti].members[i].skills = p.skills
                            company.teams[ti].members[i].disabledTools = p.disabledTools
                            company.teams[ti].members[i].model = company.teams[ti].members[i].model ?? p.model
                        }
                    } else if company.teams[ti].members.count < Company.maxMembers {
                        company.teams[ti].members.append(person(a))
                    }
                }
            } else if company.teams.count < Company.maxTeams {
                company.teams.append(Team(id: newID(), name: role.title, members: agents.map(person)))
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
