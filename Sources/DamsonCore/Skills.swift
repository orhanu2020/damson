import Foundation
import DamsonProviders

/// A Claude Agent Skill found in ~/.claude/skills. Damson does not make or edit skills; it only reads them.
public struct SkillInfo: Identifiable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var directory: URL
    public var id: String { name }
}

public enum SkillStore {
    public static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// The user's Claude skills (folders with a SKILL.md).
    public static func list(in root: URL = claudeDirectory) -> [SkillInfo] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [SkillInfo] = []
        for dir in dirs {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { continue }
            let meta = frontmatter(text)
            result.append(SkillInfo(name: meta["name"] ?? dir.lastPathComponent, description: meta["description"] ?? "",
                                    directory: dir.resolvingSymlinksInPath()))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Reads the YAML frontmatter keys (single-line values and folded/literal blocks).
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [:] }
        var meta: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if [">", "|", ">-", "|-"].contains(v) { v = "" }
                if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
                meta[k] = v; key = k
            } else if let k = key {
                let piece = line.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { meta[k] = ((meta[k] ?? "").isEmpty ? "" : meta[k]! + " ") + piece }
            }
        }
        return meta
    }

    /// The skills an agent has, as folders the Claude CLI can load, and every other skill name to block.
    public static func selection(for names: [String], all: [SkillInfo]) -> (refs: [SkillRef], blocked: [String]) {
        let wanted = Set(names)
        let refs = all.filter { wanted.contains($0.name) }.map { SkillRef(name: $0.name, directory: $0.directory) }
        return (refs, all.map { $0.name }.filter { !wanted.contains($0) })
    }
}
