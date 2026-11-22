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

    /// The company as this project sees it: only the teams working on the project.
    func projectCompany(_ project: Project) -> Company {
        var c = company
        c.teams = c.teams.filter { project.usesTeam($0.id) }
        return c
    }

    /// Which roles used by the process have no team in the project (steps given to one agent do not need one).
    func missingTeams(for project: Project) -> [TeamRole] {
        let scope = projectCompany(project)
        let roles = Set(project.steps.filter { $0.kind != .approval && $0.agentID == nil }.compactMap { $0.role })
        return TeamRole.allCases.filter { roles.contains($0) && ProjectFlow.team(for: $0, in: scope) == nil }
    }

    /// Everybody who can be given a step in this project: the people of its teams and its extra agents.
    func projectAgents(_ project: Project) -> [Person] {
        var people = projectCompany(project).teams.flatMap { $0.members }
        for team in company.teams { for p in team.members where project.agentIDs.contains(p.id) && !people.contains(where: { $0.id == p.id }) { people.append(p) } }
        return people
    }

    // MARK: Editing a project

    func setBrief(_ projectID: String, _ text: String) {
        update(projectID) { $0.brief = text }
        if let p = projects.first(where: { $0.id == projectID }) {
            prepareFolders(p)
            try? text.write(to: p.folderURL.appendingPathComponent("handoff/00-brief.md"), atomically: true, encoding: .utf8)
        }
    }

    func setTeam(_ projectID: String, _ teamID: String, on: Bool) {
        update(projectID) { p in
            var ids = p.teamIDs.isEmpty ? company.teams.map { $0.id } : p.teamIDs
            if on { if !ids.contains(teamID) { ids.append(teamID) } } else { ids.removeAll { $0 == teamID } }
            p.teamIDs = Set(ids) == Set(company.teams.map { $0.id }) ? [] : ids
        }
    }

    func setAgent(_ projectID: String, _ personID: String, on: Bool) {
        update(projectID) { p in
            p.agentIDs.removeAll { $0 == personID }
            if on { p.agentIDs.append(personID) }
        }
    }

    // MARK: Editing the process (not while it runs)

    func editStep(_ projectID: String, _ stepID: String, _ change: (inout FlowStep) -> Void) {
        guard !isRunning(projectID) else { return }
        updateStep(projectID, stepID, change)
    }

    /// Moving a step is only layout, so it is allowed while running.
    func moveStep(_ projectID: String, _ stepID: String, to point: CGPoint) {
        updateStep(projectID, stepID) { $0.x = Double(max(0, point.x)); $0.y = Double(max(0, point.y)) }
    }

    @discardableResult
    func addStep(_ projectID: String, kind: StepKind, at point: CGPoint) -> String? {
        guard !isRunning(projectID) else { return nil }
        var id: String?
        update(projectID) { id = $0.addStep(kind: kind, at: point) }
        return id
    }

    func removeStep(_ projectID: String, _ stepID: String) {
        guard !isRunning(projectID) else { return }
        update(projectID) { $0.removeStep(stepID) }
    }

    @discardableResult
    func connect(_ projectID: String, from: String, to: String) -> Bool {
        guard !isRunning(projectID) else { return false }
        var ok = false
        update(projectID) { ok = $0.connect(from: from, to: to) }
        return ok
    }

    func setEdge(_ projectID: String, _ edgeID: String, condition: EdgeCondition?) {
        guard !isRunning(projectID) else { return }
        update(projectID) { p in
            guard let i = p.edges.firstIndex(where: { $0.id == edgeID }) else { return }
            if let condition { p.edges[i].condition = condition } else { p.edges.remove(at: i) }
        }
    }

    /// Back to the standard delivery process (all progress is cleared).
    func resetProcess(_ projectID: String) {
        guard !isRunning(projectID) else { return }
        update(projectID) { p in
            p.steps = ProjectFlow.defaultSteps(environments: p.environments.map { $0.name })
            p.edges = ProjectFlow.chain(p.steps)
        }
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

    /// Runs the process: every step whose incoming edges are decided, one after another. Stops at the first failure.
    /// Approval gates wait for the user while the rest of the process carries on. `from` re-runs that step and
    /// everything after it; `all` starts over.
    func startProject(_ id: String, from: String? = nil, all: Bool = false) {
        guard projectTasks[id] == nil, let project = projects.first(where: { $0.id == id }) else { return }
        prepareFolders(project)
        update(id) { p in
            let reset: Set<String> = all ? Set(p.steps.map { $0.id })
                : from.map { p.downstream(of: $0) } ?? Set(p.steps.filter { $0.status != .done && $0.status != .waiting }.map { $0.id })
            for i in p.steps.indices where reset.contains(p.steps[i].id) {
                p.steps[i].status = .pending; p.steps[i].error = ""; p.steps[i].summary = ""; p.steps[i].badVerdict = false
            }
        }
        let task = Task { @MainActor in
            defer { projectTasks[id] = nil }
            while !Task.isCancelled {
                guard let p = projects.first(where: { $0.id == id }) else { break }
                let skip = ProjectFlow.toSkip(in: p)
                if !skip.isEmpty {
                    for s in skip {
                        updateStep(id, s) { $0.status = .skipped }
                        log(id, "\u{21B7} \(p.step(s)?.title ?? s): skipped, its branch was not taken.")
                    }
                    continue
                }
                guard let next = ProjectFlow.ready(in: p).first, let step = p.step(next) else { break }
                if step.kind == .approval {
                    // A gate: wait here for the user. Pressing Approve continues the process.
                    updateStep(id, step.id) { $0.status = .waiting }
                    log(id, "\u{23F8} \(step.title): waiting for your approval.")
                    continue
                }
                guard await runStep(step, projectID: id) else { break }
            }
            if projects.first(where: { $0.id == id })?.isFinished == true { log(id, "\u{2605} Project finished.") }
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
        let scope = step.agentID != nil ? company : projectCompany(project)
        guard let (team, agent) = ProjectFlow.agent(for: step, in: scope) else {
            return fail(step.agentID != nil ? "The agent for this step no longer exists. Pick another in the process."
                        : "No \(step.role?.title ?? "") team with an agent in this project. Add one under Overview, or use Manage > Set up delivery teams.")
        }
        updateStep(id, step.id) { $0.status = .running; $0.agentName = agent.name }
        personStatus[agent.id] = .working
        log(id, "▶ \(step.title): \(agent.name) (\(team.name)) started")
        defer { personStatus[agent.id] = nil }

        let output = step.outputFile.map { project.folderURL.appendingPathComponent($0) }
        if let output { try? FileManager.default.removeItem(at: output) }
        let instruction = ProjectFlow.instruction(for: step, project: project)
        var bad = false
        do {
            let summary = try await engine.runTask(as: agent, company: company, instruction: instruction,
                                                   directory: project.folderURL, stage: step.id) { [weak self] tool in
                Task { @MainActor in self?.log(id, "   \(agent.firstName): \(tool)") }
            }
            if let output, let file = step.outputFile {
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                guard size > 0 else { return fail("\(agent.name) finished but did not write \(file).") }
                let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                bad = ProjectFlow.verdict(of: text) == .fail
                let failBranch = project.edges.contains { $0.from == step.id && $0.condition == .fail }
                if bad && (step.kind.stopsOnBadVerdict || step.kind == .task) && !failBranch {
                    return fail("\(file) reports a failure. Read it, fix the cause and retry.")
                }
            }
            updateStep(id, step.id) { $0.status = .done; $0.summary = summary; $0.badVerdict = bad }
            log(id, "✓ \(step.title) done\(step.outputFile.map { ". Written to \($0)" } ?? "")")
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
