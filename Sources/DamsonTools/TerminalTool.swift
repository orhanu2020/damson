import Foundation
import DamsonSupport
import DamsonProviders

/// Types a command into a visible Terminal window and runs it, so the user can watch.
/// Uses AppleScript (macOS asks once: "Damson wants to control Terminal"). Output is read back from the window.
public struct TerminalTool: Tool {
    public let timeout: TimeInterval
    /// One Terminal window per task, reused for later commands.
    private static let windows = Locked<[String: Int]>([:])

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public var spec: ToolSpec {
        ToolSpec(name: "terminal_run",
                 description: "Open the Terminal app on the user's Mac, type a single-line command into it and run it while the user watches. Returns the output. Use this when the user wants to see what you are doing; use shell otherwise. Not for interactive programs.",
                 inputSchema: JSONValue.schema([("command", "string", "One-line shell command to type and run in Terminal")], required: ["command"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        guard let command = input.string("command"), !command.contains("\n") else { return .change }
        return ShellClassifier.classify(command)
    }

    public func describe(_ input: JSONValue) -> String {
        return "Run in Terminal: \(input.string("command") ?? "(none)")"
    }

    public func grantKey(_ input: JSONValue) -> String {
        let first = (input.string("command") ?? "").split(separator: " ").first.map(String.init) ?? ""
        return "terminal_run:\(first)"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let command = input.string("command")?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw ToolError.invalidInput("command is required")
        }
        if command.contains("\n") { throw ToolError.invalidInput("Use a single-line command (join steps with && or ;).") }

        let id = String(UUID().uuidString.prefix(6)).lowercased()
        // The typed text holds $((6*7)); the finished marker holds 42. The two never look alike, so only real output matches.
        let typedMarker = "DAMSON-DONE-$((6*7))-\(id)"
        let doneMarker = "DAMSON-DONE-42-\(id)-exit="
        let directory = context.baseDir.path
        let typed = "cd \(Self.singleQuoted(directory)) && \(command); echo \"\(typedMarker)-exit=$?\""

        let knownWindow = Self.windows.current[context.taskID] ?? 0
        let windowID = try await openAndType(typed, knownWindow: knownWindow)
        Self.windows.withLock { $0[context.taskID] = windowID }

        let deadline = Date().addingTimeInterval(timeout)
        var contents = ""
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            contents = try await readWindow(windowID)
            if contents.contains(doneMarker) {
                return Self.extractOutput(contents, id: id, typedMarker: typedMarker, doneMarker: doneMarker)
            }
        }
        let tail = contents.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
        return tail + "\n[still running after \(Int(timeout))s; it was left running in the Terminal window]"
    }

    // MARK: AppleScript

    private func openAndType(_ typed: String, knownWindow: Int) async throws -> Int {
        let escaped = Self.appleScriptString(typed)
        let lines = [
            "tell application \"Terminal\"",
            "activate",
            "set cmd to \"\(escaped)\"",
            "set wid to \(knownWindow)",
            "if wid is not 0 then",
            "try",
            "do script cmd in window id wid",
            "return wid",
            "end try",
            "end if",
            "do script cmd",
            "return id of front window",
            "end tell",
        ]
        let out = try await osascript(lines, timeout: 60)
        guard let id = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ToolError.failed("Terminal did not return a window: \(out)")
        }
        return id
    }

    private func readWindow(_ windowID: Int) async throws -> String {
        let lines = ["tell application \"Terminal\" to return contents of selected tab of window id \(windowID)"]
        do {
            return try await osascript(lines, timeout: 20)
        } catch {
            throw ToolError.failed("The Terminal window was closed before the command finished.")
        }
    }

    private func osascript(_ lines: [String], timeout: TimeInterval) async throws -> String {
        var arguments: [String] = []
        for line in lines { arguments += ["-e", line] }
        let result = try await runProcess(executable: "/usr/bin/osascript", arguments: arguments,
                                          cwd: FileManager.default.temporaryDirectory, timeout: timeout,
                                          environment: sanitizedEnvironment())
        if result.timedOut { throw ToolError.failed("Terminal did not answer in time.") }
        if result.status != 0 {
            if result.output.contains("-1743") || result.output.lowercased().contains("not authorized") {
                throw ToolError.failed("macOS blocked Damson from controlling Terminal. Open System Settings > Privacy & Security > Automation, allow Damson to control Terminal, then try again.")
            }
            throw ToolError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    // MARK: Helpers

    static func singleQuoted(_ text: String) -> String {
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ text: String) -> String {
        return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Text between the typed command line and the finished marker, plus the exit status when it is not 0.
    static func extractOutput(_ contents: String, id: String, typedMarker: String, doneMarker: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        guard let doneIndex = lines.lastIndex(where: { $0.contains(doneMarker) }) else { return contents }
        var start = 0
        if let typedIndex = lines[..<doneIndex].lastIndex(where: { $0.contains("$((6*7))-\(id)") }) {
            start = typedIndex + 1
        } else {
            start = max(0, doneIndex - 80)
        }
        var output = lines[start..<doneIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = lines[doneIndex].range(of: doneMarker) {
            let digits = lines[doneIndex][range.upperBound...].prefix { $0.isNumber }
            if let status = Int(digits), status != 0 { output += "\n[exit status \(status)]" }
        }
        return output.isEmpty ? "(no output)" : output
    }
}
