import Foundation
import DamsonProviders

/// A Claude Agent Skill. Damson does not make or edit skills; it reads the user's own and those of installed plugins.
public struct SkillInfo: Identifiable, Equatable, Sendable {
    /// The skill's own name, as Claude knows it.
    public var name: String
    public var description: String
    public var directory: URL
    /// The plugin it comes from; nil for the user's own skills in ~/.claude/skills.
    public var plugin: String?
    /// Unique across sources: "plugin:skill" for plugin skills, the plain name otherwise.
    public var id: String { plugin.map { "\($0):\(name)" } ?? name }
}

public enum SkillStore {
    public static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }
    public static var pluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins", isDirectory: true)
    }

    /// The user's own skills plus those of installed and synced plugins.
    public static func list(in root: URL = claudeDirectory, plugins: URL = pluginsDirectory) -> [SkillInfo] {
        var result = scan(root, plugin: nil)
        var seen = Set<String>()
        for dir in pluginDirectories(plugins) {
            let name = pluginName(dir)
            guard seen.insert(name).inserted else { continue }
            result += scan(dir.appendingPathComponent("skills", isDirectory: true), plugin: name)
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func scan(_ root: URL, plugin: String?) -> [SkillInfo] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [SkillInfo] = []
        for dir in dirs {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { continue }
            let meta = frontmatter(text)
            result.append(SkillInfo(name: meta["name"] ?? dir.lastPathComponent, description: meta["description"] ?? "",
                                    directory: dir.resolvingSymlinksInPath(), plugin: plugin))
        }
        return result
    }

    /// Installed plugins (from installed_plugins.json) first, then synced ones.
    private static func pluginDirectories(_ plugins: URL) -> [URL] {
        var dirs: [URL] = []
        if let data = try? Data(contentsOf: plugins.appendingPathComponent("installed_plugins.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let map = (obj["plugins"] as? [String: Any]) ?? obj
            for (_, entries) in map.sorted(by: { $0.key < $1.key }) {
                for e in (entries as? [[String: Any]]) ?? [] {
                    if let path = e["installPath"] as? String { dirs.append(URL(fileURLWithPath: path)) }
                }
            }
        }
        let synced = plugins.appendingPathComponent("synced", isDirectory: true)
        for account in (try? FileManager.default.contentsOfDirectory(at: synced, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: account.path, isDirectory: &isDir), isDir.boolValue else { continue }
            dirs += ((try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("skills").path) }
        }
        return dirs
    }

    private static func pluginName(_ dir: URL) -> String {
        for file in [".claude-plugin/plugin.json", "package.json"] {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let n = obj["name"] as? String, !n.isEmpty { return n.lowercased() }
        }
        return dir.lastPathComponent
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

    /// The skills an agent has (by id), as folders the Claude CLI can load, and every other skill name to block.
    public static func selection(for ids: [String], all: [SkillInfo]) -> (refs: [SkillRef], blocked: [String]) {
        let wanted = Set(ids)
        let chosen = all.filter { wanted.contains($0.id) }
        var seenNames = Set<String>()
        let refs = chosen.filter { seenNames.insert($0.name).inserted }.map { SkillRef(name: $0.name, directory: $0.directory) }
        return (refs, all.map { $0.name }.filter { !seenNames.contains($0) })
    }
}
