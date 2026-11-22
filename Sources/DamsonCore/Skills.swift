import Foundation
import DamsonProviders

/// A Claude Agent Skill: a folder with a SKILL.md (YAML frontmatter + instructions). This is Claude's own
/// format, so skills made here work in Claude Code too, and skills from ~/.claude/skills work here.
public struct SkillInfo: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case damson, claude }
    public var name: String
    public var description: String
    public var body: String
    public var directory: URL
    public var source: Source
    public var id: String { name }
    /// Only skills Damson owns can be edited or deleted from the app.
    public var isEditable: Bool { source == .damson }
}

/// Finds, writes and hands out skills. Skills live in Damson's own folder and in the user's ~/.claude/skills.
public enum SkillStore {
    public static var damsonDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damson/skills", isDirectory: true)
    }
    public static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Skill names are lowercase letters, digits and hyphens, as Claude requires.
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
        var out = ""
        for ch in folded {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) }
            else if !out.hasSuffix("-") { out.append("-") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Reading

    /// All skills. Damson's own shadow same-named ones from ~/.claude/skills.
    public static func list(damson: URL = damsonDirectory, claude: URL = claudeDirectory) -> [SkillInfo] {
        var byName: [String: SkillInfo] = [:]
        for s in scan(claude, source: .claude) { byName[s.name] = s }
        for s in scan(damson, source: .damson) { byName[s.name] = s }
        return byName.values.sorted { $0.name < $1.name }
    }

    private static func scan(_ root: URL, source: SkillInfo.Source) -> [SkillInfo] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [SkillInfo] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let (meta, body) = parse(text)
            result.append(SkillInfo(name: meta["name"] ?? dir.lastPathComponent, description: meta["description"] ?? "",
                                    body: body, directory: dir.resolvingSymlinksInPath(), source: source))
        }
        return result
    }

    /// Splits "---\nkey: value\n---\nbody". Handles single-line values and folded/literal blocks.
    static func parse(_ text: String) -> (meta: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var meta: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if v == ">" || v == "|" || v == ">-" || v == "|-" { v = "" }
                if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                    v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                } else if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
                meta[k] = v; key = k
            } else if let k = key {
                let piece = line.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { meta[k] = ((meta[k] ?? "").isEmpty ? "" : meta[k]! + " ") + piece }
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }

    // MARK: Writing (Damson's own folder only)

    @discardableResult
    public static func save(name: String, description: String, body: String, in root: URL = damsonDirectory) throws -> String {
        let slug = slug(name)
        guard !slug.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oneLine = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = oneLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let text = "---\nname: \(slug)\ndescription: \"\(escaped)\"\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return slug
    }

    public static func delete(name: String, in root: URL = damsonDirectory) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(slug(name), isDirectory: true))
    }

    /// Writes the starter skills that are not there yet. Never overwrites a skill the user edited.
    public static func seedBuiltins(in root: URL = damsonDirectory) {
        for b in Skill.builtins {
            let dir = root.appendingPathComponent(slug(b.name), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) else { continue }
            _ = try? save(name: b.name, description: b.description, body: b.instructions, in: root)
        }
    }

    // MARK: For a run

    /// The skills an agent has (by name) as folders the Claude CLI can load, and the other known skill names to block.
    public static func selection(for names: [String], all: [SkillInfo]) -> (refs: [SkillRef], blocked: [String]) {
        let wanted = Set(names.map { slug($0) })
        let refs = all.filter { wanted.contains($0.name) }.map { SkillRef(name: $0.name, directory: $0.directory) }
        let blocked = all.map { $0.name }.filter { !wanted.contains($0) }
        return (refs, blocked)
    }
}
