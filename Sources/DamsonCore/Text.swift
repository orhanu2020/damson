import Foundation
import DamsonProviders

/// Extracts the first balanced JSON object from model output (which may include prose or code fences).
public enum JSONExtractor {
    public static func firstObject(in text: String) -> JSONValue? {
        let chars = Array(text)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" {
                    if start != nil { inString = true }
                } else if c == "{" {
                    if start == nil { start = i }
                    depth += 1
                } else if c == "}" {
                    if start != nil {
                        depth -= 1
                        if depth == 0, let s = start {
                            let candidate = String(chars[s...i])
                            if let value = JSONValue.parse(candidate) { return value }
                            start = nil
                            depth = 0
                        }
                    }
                }
            }
            i += 1
        }
        return nil
    }
}

/// Splits streaming text into sentences so speech can start at the first complete sentence.
public struct SentenceSplitter {
    private var buffer = ""
    private let minLength: Int

    public init(minLength: Int = 12) {
        self.minLength = minLength
    }

    public mutating func push(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let end = nextBoundary() {
            let sentence = String(buffer[buffer.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextBoundary() -> String.Index? {
        var idx = buffer.startIndex
        var count = 0
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            let after = buffer.index(after: idx)
            count += 1
            if ch == "\n" && count >= 2 {
                return after
            }
            if ch == "." || ch == "!" || ch == "?" {
                if after < buffer.endIndex, buffer[after].isWhitespace, count >= minLength {
                    return after
                }
            }
            idx = after
        }
        return nil
    }
}
