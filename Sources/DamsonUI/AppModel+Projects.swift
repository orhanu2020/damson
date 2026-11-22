import SwiftUI
import DamsonSupport
import DamsonCore

extension AppModel {
    // MARK: Teams for the process

    /// Creates the teams of the process that are missing, and gives their agents the right model, skills and tools.
    /// Agents that already have skills set are left as the user configured them.
    func setupDeliveryTeams() {
        reloadSkills()
        ProjectFlow.applyPresets(to: &company, knownSkills: Set(skills.map { $0.id }),
                                 allTools: engine.tools.specs.map { $0.name }, newID: newPersonID)
    }

    private func newPersonID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Which roles cannot work because no team matches them.
    func missingTeams() -> [TeamRole] {
        TeamRole.allCases.filter { ProjectFlow.team(for: $0, in: company) == nil }
    }

    // MARK: Projects

    func createProject(name: String, brief: String) -> Project {
        let base = settings.workspaceURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent(ProjectFlow.slug(name))
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = base.appendingPathComponent("\(ProjectFlow.slug(name))-\(n)"); n += 1
        }
        let project = Project(name: name, brief: brief, folder: folder.path)
        prepareFolders(project)
        try? brief.write(to: folder.appendingPathComponent("handoff/00-brief.md"), atomically: true, encoding: .utf8)
        projects.insert(project, at: 0)
        return project
    }

    private func prepareFolders(_ project: Project) {
        for sub in ProjectFlow.folders {
            try? FileManager.default.createDirectory(at: project.folderURL.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    func deleteProject(_ id: String) {
        cancelProject(id)
        projects.removeAll { $0.id == id }
        projectLog[id] = nil
    }

    func isRunning(_ id: String) -> Bool { projectTasks[id] != nil }

    func updateEnvironment(_ projectID: String, _ env: EnvSettings) {
        update(projectID) { p in
            if let i = p.environments.firstIndex(where: { $0.name == env.name }) { p.environments[i] = env } else { p.environments.append(env) }
        }
    }

    private func update(_ id: String, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
    }

    private func updateStep(_ id: String, _ stepID: String, _ change: (inout FlowStep) -> Void) {
        update(id) { p in if let i = p.steps.firstIndex(where: { $0.id == stepID }) { change(&p.steps[i]) } }
    }

    private func log(_ id: String, _ line: String) {
        projectLog[id, default: []].append(line)
        if (projectLog[id]?.count ?? 0) > 300 { projectLog[id]?.removeFirst(100) }
    }

    func cancelProject(_ id: String) {
        projectTasks[id]?.cancel()
    }

    // MARK: Running

    /// Runs the steps in order from `from` (or the first step that is not done). Stops at an approval gate until the
    /// user decides, and at the first failure.
    func startProject(_ id: String, from: String? = nil) {
        guard projectTasks[id] == nil, let project = projects.first(where: { $0.id == id }) else { return }
        prepareFolders(project)
        let startIndex = from.flatMap { f in project.steps.firstIndex { $0.id == f } }
            ?? (project.steps.firstIndex { $0.status != .done } ?? project.steps.count)
        update(id) { p in
            for i in p.steps.indices where i >= startIndex && p.steps[i].status != .waiting {
                p.steps[i].status = .pending; p.steps[i].error = ""; p.steps[i].summary = ""
            }
        }
        let task = Task { @MainActor in
            defer { projectTasks[id] = nil }
            var i = startIndex
            while let step = projects.first(where: { $0.id == id })?.steps[safe: i] {
                if Task.isCancelled { break }
                if step.kind == .approval {
                    // A gate: wait here for the user. Pressing Approve continues the flow.
                    updateStep(id, step.id) { $0.status = .waiting }
                    log(id, "⏸ \(step.title): waiting for your approval.")
                    return
                }
                guard await runStep(step, projectID: id) else { break }
                i += 1
            }
        }
        projectTasks[id] = task
    }

    /// Only the user can pass a gate. A failed test report needs `anyway: true`.
    func approveGate(_ projectID: String, _ stepID: String, note: String = "", anyway: Bool = false) {
        guard let p = projects.first(where: { $0.id == projectID }),
              let i = p.steps.firstIndex(where: { $0.id == stepID }), p.steps[i].status == .waiting else { return }
        if gateWarning(p, index: i) != nil && !anyway { return }
        updateStep(projectID, stepID) { $0.status = .done; $0.note = note }
        log(projectID, "✓ \(p.steps[i].title): approved\(note.isEmpty ? "" : " (\(note))").")
        startProject(projectID)
    }

    func rejectGate(_ projectID: String, _ stepID: String, note: String = "") {
        guard let p = projects.first(where: { $0.id == projectID }), let step = p.steps.first(where: { $0.id == stepID }) else { return }
        updateStep(projectID, stepID) { $0.status = .rejected; $0.note = note }
        log(projectID, "✗ \(step.title): rejected\(note.isEmpty ? "" : " (\(note))"). The flow stops here.")
    }

    /// Puts a rejected gate back to waiting.
    func reopenGate(_ projectID: String, _ stepID: String) {
        updateStep(projectID, stepID) { $0.status = .waiting; $0.note = "" }
    }

    /// Why a gate should not simply be approved: the report before it says FAIL.
    func gateWarning(_ project: Project, index: Int) -> String? {
        guard let file = project.reportBefore(index),
              let text = try? String(contentsOf: project.folderURL.appendingPathComponent(file), encoding: .utf8) else { return nil }
        return ProjectFlow.verdict(of: text) == .fail ? "\((file as NSString).lastPathComponent) reports a failure." : nil
    }

    private func runStep(_ step: FlowStep, projectID id: String) async -> Bool {
        guard let project = projects.first(where: { $0.id == id }) else { return false }
        func fail(_ message: String) -> Bool {
            updateStep(id, step.id) { $0.status = .failed; $0.error = message }
            log(id, "✗ \(step.title): \(message)")
            return false
        }
        guard let (team, agent) = ProjectFlow.agent(for: step, in: company) else {
            return fail("No \(step.kind.role?.title ?? "") team with an agent. Use Manage > Set up delivery teams.")
        }
        updateStep(id, step.id) { $0.status = .running; $0.agentName = agent.name }
        personStatus[agent.id] = .working
        log(id, "▶ \(step.title): \(agent.name) (\(team.name)) started")
        defer { personStatus[agent.id] = nil }

        let output = step.outputFile.map { project.folderURL.appendingPathComponent($0) }
        if let output { try? FileManager.default.removeItem(at: output) }
        let instruction = ProjectFlow.instruction(for: step, project: project)
        do {
            let summary = try await engine.runTask(as: agent, company: company, instruction: instruction,
                                                   directory: project.folderURL, stage: step.id) { [weak self] tool in
                Task { @MainActor in self?.log(id, "   \(agent.firstName): \(tool)") }
            }
            if let output, let file = step.outputFile {
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                guard size > 0 else { return fail("\(agent.name) finished but did not write \(file).") }
                if step.kind.stopsOnBadVerdict {
                    let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                    if ProjectFlow.verdict(of: text) == .fail { return fail("\(file) reports a failure. Read it, fix the cause and retry.") }
                }
            }
            updateStep(id, step.id) { $0.status = .done; $0.summary = summary }
            log(id, "✓ \(step.title) done\(step.outputFile.map { ". Written to \($0)" } ?? "")")
            if projects.first(where: { $0.id == id })?.steps.last?.id == step.id { log(id, "★ Project finished.") }
            return true
        } catch where Task.isCancelled || error is CancellationError {
            updateStep(id, step.id) { $0.status = .pending }
            log(id, "■ Stopped during \(step.title).")
            return false
        } catch {
            return fail(error.localizedDescription)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
