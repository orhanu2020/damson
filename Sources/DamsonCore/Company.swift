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
    public init(name: String, teams: [Team]) {
        self.name = name
        self.teams = teams
    }

    public var allPeople: [Person] { teams.flatMap { $0.members } }

    /// Limits so the office stays readable.
    public static let maxTeams = 10
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
            Person(id: "anna", name: "Anna Miller", role: "Team Lead"),
            Person(id: "mark", name: "Mark Davis", role: "Backend Developer"),
            Person(id: "zoe", name: "Zoe Adams", role: "Mobile Developer"),
            Person(id: "chris", name: "Chris Young", role: "Test Engineer"),
        ]),
        Team(id: "design", name: "Design", members: [
            Person(id: "ella", name: "Ella Stone", role: "Design Director"),
            Person(id: "ben", name: "Ben Hall", role: "UI Designer"),
            Person(id: "sam", name: "Sam Lee", role: "UX Researcher"),
        ]),
        Team(id: "marketing", name: "Marketing", members: [
            Person(id: "dana", name: "Dana Cole", role: "Marketing Director"),
            Person(id: "adam", name: "Adam Price", role: "Content Writer"),
            Person(id: "grace", name: "Grace Evans", role: "Social Media Specialist"),
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
