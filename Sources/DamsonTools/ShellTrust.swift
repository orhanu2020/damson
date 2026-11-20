import Foundation

/// Trust checks for shell commands. Conservative: when in doubt, ask the user.
extension ShellClassifier {
    // MARK: Parsing

    struct ParsedCommand {
        var segments: [[String]]
        var hasSubstitution: Bool
    }

    /// Loose tokenizer: splits on ; & | and newlines outside quotes, removes quotes. Never fails.
    static func parse(_ command: String) -> ParsedCommand {
        var segments: [[String]] = []
        var words: [String] = []
        var current = ""
        var hasWord = false
        var inSingle = false
        var inDouble = false
        let chars = Array(command)
        var i = 0

        func endWord() {
            if hasWord { words.append(current) }
            current = ""
            hasWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        while i < chars.count {
            let c = chars[i]
            if inSingle {
                if c == "'" { inSingle = false } else { current.append(c) }
                i += 1
                continue
            }
            if inDouble {
                if c == "\"" {
                    inDouble = false
                } else if c == "\\", i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 1
                } else {
                    current.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "'":
                inSingle = true
                hasWord = true
            case "\"":
                inDouble = true
                hasWord = true
            case "\\":
                if i + 1 < chars.count {
                    current.append(chars[i + 1])
                    hasWord = true
                    i += 1
                }
            case " ", "\t":
                endWord()
            case ";", "\n", "|":
                endSegment()
            case "&":
                // Keep 2>&1 and &> together; otherwise it separates commands.
                if (i > 0 && chars[i - 1] == ">") || (i + 1 < chars.count && chars[i + 1] == ">") {
                    current.append(c)
                    hasWord = true
                } else {
                    endSegment()
                }
            default:
                current.append(c)
                hasWord = true
            }
            i += 1
        }
        endSegment()
        let substitution = command.contains("`") || command.contains("$(")
        return ParsedCommand(segments: segments, hasSubstitution: substitution)
    }

    /// First real command word of a segment (skips VAR=value prefixes).
    static func commandWord(_ words: [String]) -> (name: String, args: [String])? {
        var index = 0
        while index < words.count, isAssignment(words[index]) { index += 1 }
        guard index < words.count else { return nil }
        let name = (words[index] as NSString).lastPathComponent.lowercased()
        return (name, Array(words[(index + 1)...]))
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[word.startIndex..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: Paths

    static let systemPrefixes = ["/System", "/Library", "/etc", "/usr", "/bin", "/sbin", "/private", "/var", "/Applications"]

    public static func isSystemPath(_ path: String) -> Bool {
        let p = (path as NSString).expandingTildeInPath
        for prefix in systemPrefixes where p == prefix || p.hasPrefix(prefix + "/") { return true }
        return false
    }

    private static func looksLikePath(_ word: String) -> Bool {
        return word.hasPrefix("/") || word.hasPrefix("~") || word == ".." || word.hasPrefix("../")
            || word.contains("/../") || word.hasSuffix("/..")
    }

    /// Path-like pieces of a word: the word itself, a redirect target (">/x") and the value of --opt=/x.
    private static func pathCandidates(_ word: String) -> [String] {
        var w = word
        if w.contains(">") || w.contains("<") {
            w = String(w.drop(while: { "0123456789<>&".contains($0) }))
        }
        var out: [String] = []
        if looksLikePath(w) { out.append(w) }
        if let eq = w.firstIndex(of: "=") {
            let value = String(w[w.index(after: eq)...])
            if looksLikePath(value) { out.append(value) }
        }
        return out
    }

    private static func isInside(_ token: String, workspace: URL) -> Bool {
        let url = PathUtil.resolve(token, base: workspace)
        return PathUtil.isInside(url, directory: workspace)
    }

    // MARK: Hard-block list (asks even under Full trust)

    static let hardBlockedCommands: Set<String> = [
        "sudo", "su", "doas", "diskutil", "dd", "fdisk", "shutdown", "reboot", "halt", "passwd", "csrutil",
        "nvram", "dscl", "security", "launchctl", "crontab", "kextload", "kextunload", "pfctl", "networksetup",
        "systemsetup", "tmutil", "srm", "shred",
    ]

    private static let hardBlockRegexes: [NSRegularExpression] = {
        let names = hardBlockedCommands.sorted().joined(separator: "|")
        let patterns = [
            "(^|[^A-Za-z0-9_./-])(\(names))([^A-Za-z0-9_-]|$)",   // dangerous program anywhere in the text
            "(^|[^A-Za-z0-9_])(mkfs|newfs)[A-Za-z0-9_.]*",          // filesystem creation
            "\\|\\s*(sudo\\s+)?(/bin/)?(ba|z|da|k)?sh(\\s|$)",       // anything piped into a shell
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    public static func isHardBlocked(_ command: String, workspace: URL?) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        for regex in hardBlockRegexes where regex.firstMatch(in: command, options: [], range: range) != nil { return true }
        if isSensitivePath(command) { return true }

        let parsed = parse(command)
        for words in parsed.segments {
            // A dangerous program hidden behind quotes ("s""udo") or a wrapper.
            for word in words where hardBlockedCommands.contains(word.lowercased()) { return true }
            guard let (name, args) = commandWord(words) else { continue }

            for word in words {
                for candidate in pathCandidates(word) where isSystemPath(candidate) { return true }
            }

            if name == "git", args.contains("push") {
                for a in args where a == "-f" || a.hasPrefix("--force") || a == "--delete" || a == "--mirror" { return true }
            }

            if ["rm", "chmod", "chown", "chgrp"].contains(name) {
                let flags = args.filter { $0.hasPrefix("-") }
                let recursive = flags.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R"))) }
                guard recursive else { continue }
                guard let workspace = workspace else { return true }
                for target in args where !target.hasPrefix("-") {
                    if [".", "./", "..", "*", "/", "~", "~/", "/*", "~/*"].contains(target) { return true }
                    if target.contains("$") { return true }
                    let url = PathUtil.resolve(target, base: workspace)
                    if url.standardizedFileURL.path == workspace.standardizedFileURL.path { return true }
                    if !PathUtil.isInside(url, directory: workspace) { return true }
                }
            }
        }
        return false
    }

    // MARK: Trusted workspace

    static let workspaceCommands: Set<String> = [
        "mkdir", "touch", "cp", "mv", "rm", "rmdir", "ln", "chmod", "git", "swift", "swiftc", "xcodebuild",
        "python3", "python", "node", "npm", "npx", "yarn", "pnpm", "make", "cmake", "cargo", "go", "sed", "awk",
        "tee", "echo", "cat", "ls", "pwd", "cd", "grep", "rg", "head", "tail", "sort", "wc", "printf", "true",
        "test", "diff", "tar", "zip", "unzip", "ruby", "bundle", "mvn", "gradle", "java", "javac", "clang", "cc",
    ]

    static let deniedSubcommands: [String: Set<String>] = [
        "git": ["push", "remote", "config", "credential", "submodule"],
        "npm": ["publish", "login", "adduser", "token", "owner", "access", "deprecate", "unpublish", "config"],
        "yarn": ["publish", "login", "npm", "config"],
        "pnpm": ["publish", "login", "config"],
        "cargo": ["publish", "login", "install", "owner"],
        "go": ["install"],
    ]

    /// True when every command is a file or build command and every path stays inside the workspace.
    public static func isWorkspaceSafe(_ command: String, workspace: URL) -> Bool {
        let parsed = parse(command)
        if parsed.hasSubstitution || parsed.segments.isEmpty { return false }
        for words in parsed.segments {
            guard let (name, args) = commandWord(words), workspaceCommands.contains(name) else { return false }
            if let denied = deniedSubcommands[name], args.contains(where: { denied.contains($0) }) { return false }
            if args.contains("-g") || args.contains("--global") { return false }
            for word in words {
                if word.contains("$") { return false }
                for candidate in pathCandidates(word) where !isInside(candidate, workspace: workspace) { return false }
            }
        }
        return true
    }
}
