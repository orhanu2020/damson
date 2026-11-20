import Foundation

/// Decides whether a shell command only looks (Observe) or may change something (Change).
/// Conservative by design: anything not provably read-only is a Change.
public enum ShellClassifier {
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "echo", "date", "whoami", "uname",
        "which", "file", "stat", "du", "df", "ps", "uptime", "sort", "uniq", "cut", "tr", "basename",
        "dirname", "realpath", "sw_vers", "hostname", "id", "tree", "diff", "cmp", "shasum", "md5",
        "jq", "find", "git", "defaults", "plutil", "true", "false", "printf", "test", "seq",
    ]

    static let gitReadOnly: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "branch", "remote", "tag",
    ]

    static let findDangerous: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls", "-fprint0"]

    static let sensitiveMarkers: [String] = [
        ".ssh", "keychains", ".aws", ".gnupg", ".netrc", "id_rsa", "id_ed25519", ".env", "credentials",
        "cookies", "login data", ".config/gh", ".docker/config", "sudoers", "master.passwd", ".kube/config", ".npmrc", ".pypirc",
    ]

    public static func isSensitivePath(_ text: String) -> Bool {
        let lower = text.lowercased()
        for marker in sensitiveMarkers where lower.contains(marker) { return true }
        return false
    }

    public static func classify(_ command: String) -> ActionClass {
        guard let segments = split(command), !segments.isEmpty else { return .change }
        for words in segments {
            if !isReadOnly(words) { return .change }
        }
        return .observe
    }

    /// Splits on |, ||, &&, ; outside quotes. Returns nil when the command contains anything
    /// that could hide a write or a second command (redirects, backticks, $( ), backgrounding).
    static func split(_ command: String) -> [[String]]? {
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
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if inSingle {
                if c == "'" { inSingle = false } else { current.append(c); hasWord = true }
                i += 1
                continue
            }
            if inDouble {
                if c == "\"" {
                    inDouble = false
                } else if c == "`" || (c == "$" && next == "(") {
                    return nil
                } else if c == "\\" {
                    if let n = next { current.append(n); hasWord = true; i += 1 }
                } else {
                    current.append(c)
                    hasWord = true
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
            case "`":
                return nil
            case "$":
                if next == "(" || next == "{" { return nil }
                current.append(c)
                hasWord = true
            case ">", "<":
                return nil
            case "\n", "\r":
                return nil
            case "\\":
                if let n = next { current.append(n); hasWord = true; i += 1 } else { return nil }
            case " ", "\t":
                endWord()
            case "|":
                endSegment()
                if next == "|" { i += 1 }
            case "&":
                if next == "&" {
                    endSegment()
                    i += 1
                } else {
                    return nil
                }
            case ";":
                endSegment()
            default:
                current.append(c)
                hasWord = true
            }
            i += 1
        }
        if inSingle || inDouble { return nil }
        endSegment()
        return segments
    }

    static func isReadOnly(_ words: [String]) -> Bool {
        guard let first = words.first, !first.contains("/") else { return false }
        guard readOnlyCommands.contains(first) else { return false }
        let args = Array(words.dropFirst())

        for w in args where isSensitivePath(w) { return false }
        if args.contains(where: { $0.hasPrefix("--output") || $0.hasPrefix("--pre") }) { return false }

        switch first {
        case "git":
            guard let sub = args.first, gitReadOnly.contains(sub) else { return false }
            let rest = args.dropFirst()
            if rest.contains(where: { $0 == "-c" || $0.hasPrefix("--exec") || $0.hasPrefix("--ext-diff") }) { return false }
            if sub == "branch" || sub == "tag" {
                // listing only: flags like -a/-r/-v are fine, bare names would create/delete refs
                return rest.allSatisfy { $0.hasPrefix("-") && !$0.hasPrefix("-d") && !$0.hasPrefix("-D") && !$0.hasPrefix("-m") && !$0.hasPrefix("-M") && !$0.hasPrefix("-c") && !$0.hasPrefix("-C") && !$0.hasPrefix("-f") }
            }
            if sub == "remote" {
                return rest.allSatisfy { $0 == "-v" || $0 == "--verbose" }
            }
            return true
        case "find":
            return !args.contains(where: { findDangerous.contains($0) })
        case "sort":
            return !args.contains(where: { $0 == "-o" })
        case "tree":
            return !args.contains(where: { $0 == "-o" })
        case "date":
            return !args.contains(where: { $0 == "-s" || $0 == "-f" })
        case "hostname":
            return args.isEmpty || args == ["-s"] || args == ["-f"]
        case "uniq":
            let positional = args.filter { !$0.hasPrefix("-") }
            return positional.count <= 1
        case "defaults":
            return args.first == "read" || args.first == "read-type"
        case "plutil":
            return args.first == "-p"
        default:
            return true
        }
    }
}
