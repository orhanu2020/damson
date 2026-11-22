import Foundation

/// A person in the company view. For now every person is backed by the same stand-in agent.
public struct Person: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    /// Professional capabilities, e.g. "Backend & APIs". They shape how this person answers.
    public var skills: [String]
    /// Claude model id this agent runs on (via your Claude subscription). nil = the conversation model from Settings.
    public var model: String?
    /// Tools this agent may NOT use. Empty = all tools (changes still need your approval).
    public var disabledTools: [String]

    public init(id: String, name: String, role: String, skills: [String] = [], model: String? = nil, disabledTools: [String] = []) {
        self.disabledTools = disabledTools
        self.id = id
        self.name = name
        self.role = role
        self.skills = skills
        self.model = model
    }

    enum CodingKeys: String, CodingKey { case id, name, role, skills, model, disabledTools }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decode(String.self, forKey: .role)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model)
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }

    public var firstName: String {
        return String(name.split(separator: " ").first ?? Substring(name))
    }

    public var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(letters).uppercased(with: Locale(identifier: "tr_TR"))
    }
}

/// A starter skill. Seeded as a real SKILL.md (see SkillStore); also the shape of skills from older company files.
public struct Skill: Identifiable, Codable, Equatable, Sendable {
    public var name: String
    public var instructions: String
    public var id: String { name }

    public init(name: String, instructions: String) {
        self.name = name
        self.instructions = instructions
    }

    /// The "when to use" line Claude reads to decide whether to load the skill.
    public var description: String {
        let first = instructions.split(separator: ".").first.map(String.init) ?? instructions
        return "Use when the work calls for \(name.lowercased()). \(first)."
    }

    public static let builtins: [Skill] = [
        Skill(name: "Software development", instructions: "Design and reason about code carefully. Prefer simple, tested solutions; explain trade-offs and show short code sketches in words."),
        Skill(name: "Backend & APIs", instructions: "Think in terms of data models, API contracts, error handling, security and scaling when advising on server-side work."),
        Skill(name: "Mobile apps", instructions: "Advise on iOS and Android app design, platform conventions, performance and release practice."),
        Skill(name: "Testing & QA", instructions: "Look for edge cases and failure modes first. Propose concrete test cases and how to verify a fix."),
        Skill(name: "UI design", instructions: "Judge layout, hierarchy, typography, color and consistency. Give specific, actionable visual feedback."),
        Skill(name: "UX research", instructions: "Frame questions about users: goals, pain points, interviews and usability tests. Distinguish evidence from assumption."),
        Skill(name: "Marketing strategy", instructions: "Reason about audience, positioning, channels and measurable goals. Prefer concrete campaign ideas over generalities."),
        Skill(name: "Copywriting", instructions: "Write clear, persuasive copy in the requested tone. Offer a few variants when asked for a draft."),
        Skill(name: "Social media", instructions: "Suggest platform-appropriate posts, timing and engagement ideas; keep a consistent brand voice."),
        Skill(name: "Data analysis", instructions: "Ask what decision the numbers serve, suggest the right metrics and checks, and state the limits of the data."),
        Skill(name: "Project management", instructions: "Break work into steps, owners, risks and deadlines. Keep plans short and realistic."),
        Skill(name: "Finance & budgeting", instructions: "Reason about budgets, costs and trade-offs with clear arithmetic. You are not a licensed financial adviser."),
        Skill(name: "Legal & compliance", instructions: "Point out common legal and compliance concerns in plain language. You are not a lawyer; recommend professional review for real decisions."),
        Skill(name: "Customer support", instructions: "Respond with empathy, find the root cause, and give clear next steps."),
        Skill(name: "Sales", instructions: "Focus on customer needs, objections and next steps; suggest concise outreach and follow-up."),
        Skill(name: "Research & summarizing", instructions: "Summarize material faithfully and briefly, separate facts from opinion, and flag what is unknown."),
        Skill(name: "Requirements analysis", instructions: "Turn a business brief into precise, numbered, testable requirements with acceptance criteria. State assumptions instead of leaving gaps."),
        Skill(name: "Time & effort estimation", instructions: "Break work into items, estimate effort in person-days with ranges, list resources, milestones and risks, and state your confidence honestly."),
        Skill(name: "Test automation", instructions: "Write runnable automated tests tied to requirements, run them for real, and report only actual results with reproducible defects."),
        Skill(name: "Deployment & DevOps", instructions: "Build, package and deploy applications to a test environment reliably, and document how to reach and run them."),
        Skill(name: "Translation", instructions: "Translate accurately between Turkish and English (and other languages on request), keeping tone and meaning."),
    ]
}

public struct Team: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var members: [Person]

    public init(id: String, name: String, members: [Person]) {
        self.id = id
        self.name = name
        self.members = members
    }
}

public struct Company: Codable, Equatable, Sendable {
    public var name: String
    public var teams: [Team]
    /// Skills stored inside older company files. Read once so they can be moved to SKILL.md folders; never written back.
    public var legacySkills: [Skill] = []

    public init(name: String, teams: [Team]) {
        self.name = name
        self.teams = teams
    }

    enum CodingKeys: String, CodingKey { case name, teams, skillLibrary }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        teams = try c.decode([Team].self, forKey: .teams)
        legacySkills = try c.decodeIfPresent([Skill].self, forKey: .skillLibrary) ?? []
        // Skills are named like Claude skills now (lowercase-with-hyphens).
        for t in teams.indices { for m in teams[t].members.indices {
            teams[t].members[m].skills = teams[t].members[m].skills.map { SkillStore.slug($0) }
        } }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(teams, forKey: .teams)
    }

    public var allPeople: [Person] { teams.flatMap { $0.members } }

    /// Limits so the office stays readable.
    public static let maxTeams = 8
    public static let maxMembers = 12

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Damson/company.json")
    }

    public static func load() -> Company? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Company.self, from: data)
    }

    public func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    public static let sample = Company(name: "Damson Inc.", teams: [
        Team(id: "software", name: "Software", members: [
            Person(id: "ayse", name: "Ayşe Kaya", role: "Team Lead"),
            Person(id: "mehmet", name: "Mehmet Demir", role: "Backend Developer"),
            Person(id: "zeynep", name: "Zeynep Arslan", role: "Mobile Developer"),
            Person(id: "can", name: "Can Yıldız", role: "Test Engineer"),
        ]),
        Team(id: "design", name: "Design", members: [
            Person(id: "elif", name: "Elif Şahin", role: "Design Director"),
            Person(id: "burak", name: "Burak Aydın", role: "UI Designer"),
            Person(id: "selin", name: "Selin Çelik", role: "UX Researcher"),
        ]),
        Team(id: "marketing", name: "Marketing", members: [
            Person(id: "deniz", name: "Deniz Koç", role: "Marketing Director"),
            Person(id: "ahmet", name: "Ahmet Polat", role: "Content Writer"),
            Person(id: "ece", name: "Ece Güneş", role: "Social Media Specialist"),
        ]),
    ])
}

/// What a spoken or typed command picked out.
public struct CompanyCommand: Equatable, Sendable {
    public var people: [Person]
    public var teams: [Team]
    public var text: String

    public init(people: [Person], teams: [Team], text: String) {
        self.people = people
        self.teams = teams
        self.text = text
    }
}

/// Finds the people and teams named in a command. Tolerates Turkish suffixes ("Ayşe'yi", "Ayşeyi")
/// and speech-recognition spelling (ş/s, ı/i, ğ/g).
public enum CompanyCommandParser {
    public static func fold(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "\u{0131}", with: "i")
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        return s.folding(options: [.diacriticInsensitive], locale: nil)
    }

    private static func matches(_ token: String, _ name: String) -> Bool {
        if token == name { return true }
        // Longer names also match with a Turkish suffix attached; short names (Can, Ece) must match exactly.
        return name.count >= 4 && token.hasPrefix(name)
    }

    public static func parse(_ utterance: String, company: Company) -> CompanyCommand? {
        let tokens = fold(utterance).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.isEmpty { return nil }

        var namedTeams: [Team] = []
        var ids = Set<String>()
        for team in company.teams {
            let teamName = fold(team.name)
            if tokens.contains(where: { matches($0, teamName) }) {
                namedTeams.append(team)
                for member in team.members { ids.insert(member.id) }
            }
        }
        for person in company.allPeople {
            let first = fold(person.firstName)
            if tokens.contains(where: { matches($0, first) }) { ids.insert(person.id) }
        }
        if ids.isEmpty { return nil }
        let people = company.allPeople.filter { ids.contains($0.id) }
        return CompanyCommand(people: people, teams: namedTeams, text: utterance)
    }
}

/// Whatever sits behind a person in the company view. Today it is a stand-in; later each person can be a real agent.
public protocol TeamAgent: Sendable {
    func handle(command: String, for person: Person) async -> String
}

/// Does nothing except acknowledge. "Very well." is the whole reply.
public struct StubTeamAgent: TeamAgent {
    public static let reply = "Very well."
    public var delayNanoseconds: UInt64

    public init(delayNanoseconds: UInt64 = 700_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    public func handle(command: String, for person: Person) async -> String {
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        return Self.reply
    }
}
