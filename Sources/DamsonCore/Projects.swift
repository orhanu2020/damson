import Foundation

// MARK: - The delivery process
//
//   brief -> Business Analysis (requirements) -> Project Management (estimates) -> Dev (build + deploy to test env)
//         -> Test (new tests, run them, report)
//
// Teams never talk to each other directly. Each stage reads the files the previous stage left in `handoff/`
// and writes its own file there.

public enum StageKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case requirements, estimate, development, testing
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .requirements: return "Requirements"
        case .estimate: return "Estimates"
        case .development: return "Development and deploy"
        case .testing: return "Testing and report"
        }
    }

    public var teamLabel: String {
        switch self {
        case .requirements: return "Business Analysis"
        case .estimate: return "Project Management"
        case .development: return "Dev"
        case .testing: return "Test"
        }
    }

    public var icon: String {
        switch self {
        case .requirements: return "doc.text.magnifyingglass"
        case .estimate: return "calendar.badge.clock"
        case .development: return "hammer.fill"
        case .testing: return "checkmark.seal.fill"
        }
    }

    /// The file this stage must leave behind for the next one (relative to the project folder).
    public var outputFile: String {
        switch self {
        case .requirements: return "handoff/01-requirements.md"
        case .estimate: return "handoff/02-estimate.md"
        case .development: return "handoff/03-deploy-notice.md"
        case .testing: return "handoff/04-test-report.md"
        }
    }

    /// Words that identify the team for this stage (matched against the team name, ignoring case and accents).
    var teamKeywords: [String] {
        switch self {
        case .requirements: return ["business", "analy", "analiz", "requirement"]
        case .estimate: return ["project", "manage", "proje", "planning"]
        case .development: return ["dev", "engineer", "software", "yazilim"]
        case .testing: return ["test", "qa", "quality"]
        }
    }

    /// Words that should not count (so "Project Management" is not taken for a dev team, "Testing" not for "Dev").
    var teamExcluded: [String] {
        switch self {
        case .development: return ["test", "qa", "analy", "analiz", "business", "manage"]
        default: return []
        }
    }
}

public enum StageStatus: String, Codable, Sendable {
    case pending, running, done, failed
}

public struct ProjectStage: Codable, Identifiable, Equatable, Sendable {
    public var kind: StageKind
    public var status: StageStatus = .pending
    public var agentName: String = ""
    public var summary: String = ""
    public var error: String = ""
    public var id: String { kind.rawValue }
    public init(kind: StageKind) { self.kind = kind }
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var brief: String
    public var folder: String
    public var createdAt: Date
    public var stages: [ProjectStage]

    public init(id: String = UUID().uuidString, name: String, brief: String, folder: String) {
        self.id = id
        self.name = name
        self.brief = brief
        self.folder = folder
        self.createdAt = Date()
        self.stages = StageKind.allCases.map { ProjectStage(kind: $0) }
    }

    public var folderURL: URL { URL(fileURLWithPath: folder) }
    public var isFinished: Bool { stages.allSatisfy { $0.status == .done } }
}

public enum ProjectFlow {
    static func fold(_ s: String) -> String { CompanyCommandParser.fold(s) }

    /// The team that does this stage, found by name.
    public static func team(for kind: StageKind, in company: Company) -> Team? {
        for team in company.teams {
            let name = fold(team.name)
            if kind.teamExcluded.contains(where: { name.contains($0) }) { continue }
            if kind.teamKeywords.contains(where: { name.contains($0) }) { return team }
        }
        return nil
    }

    public static func slug(_ name: String) -> String {
        let s = fold(name).map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "project" : joined
    }

    public static let folders = ["handoff", "app", "tests", "test-env"]

    /// What the agent is told to do. Everything it needs comes from files, not from the previous team's chat.
    public static func instruction(for kind: StageKind, project: Project) -> String {
        let header = """
        You are working on the project "\(project.name)". Your working directory is the project folder; use relative paths.
        Folders: handoff/ (files passed between teams), app/ (the application source), tests/ (automated tests), test-env/ (the test environment).
        Do the job with your tools, thoroughly. Do not ask the user questions; where something is unclear, make a reasonable assumption and write it down.
        When you are done, reply with a short plain summary (3 to 6 sentences) of what you produced.

        """
        switch kind {
        case .requirements:
            return header + """
            YOUR ROLE: business analysis. Turn the business brief into clear requirements for the application.
            1. Read handoff/00-brief.md.
            2. Write handoff/01-requirements.md in Markdown with these sections: Overview and goals; Users and stakeholders; Functional requirements (numbered REQ-001, REQ-002 ... each one testable); Non-functional requirements; Acceptance criteria per requirement; Out of scope; Assumptions and open questions.
            The Dev team will build the application only from this file, and the Test team will derive tests from it, so make it precise and complete.
            """
        case .estimate:
            return header + """
            YOUR ROLE: project management. Create the time and resource estimates.
            1. Read handoff/01-requirements.md.
            2. Write handoff/02-estimate.md in Markdown with: work breakdown (one line per requirement or group, with effort in person-days); total effort; required roles and team size; milestones and a timeline in working days; main risks with mitigations; assumptions; your confidence level in the estimate.
            """
        case .development:
            return header + """
            YOUR ROLE: development. Build the application that fulfils the requirements, then deploy it to the test environment.
            1. Read handoff/01-requirements.md and handoff/02-estimate.md.
            2. Implement the application in app/. Choose a simple, dependable stack. Run it or build it to check that it works.
            3. Deploy it to the test environment: put the runnable result in test-env/ (and start it on a local port if it is a server or web app, using the shell).
            4. Write handoff/03-deploy-notice.md for the Test team: version; which requirements (REQ ids) are implemented and which are not; how to reach or run the test environment (URL, commands); test data and logins if any; how to run any checks you already did; known limitations.
            This file is the only way the Test team learns that the deployment is ready, so it must be accurate.
            """
        case .testing:
            return header + """
            YOUR ROLE: testing. Test the newly deployed features and report.
            1. Read handoff/01-requirements.md and handoff/03-deploy-notice.md.
            2. Create new automated tests for the new features in tests/ (one or more runnable test files, each test tied to a REQ id).
            3. Run the tests against the test environment described in the deploy notice, using the shell. Record the real results.
            4. Write handoff/04-test-report.md in Markdown with: summary and verdict (PASS or FAIL); environment and version tested; a table of test cases (REQ id, test, result); defects found with steps to reproduce; requirements not covered; recommendations.
            Report only what you actually ran. Never claim a test passed that you did not run.
            """
        }
    }
}

/// Saves the project list.
public enum ProjectStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson/projects.json")
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
