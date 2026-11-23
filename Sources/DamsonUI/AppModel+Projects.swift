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

    /// Agents are one pool for all projects, so a project sees the whole company.
    func projectCompany(_ project: Project) -> Company { company }

    /// Roles used by the process that have no agent chosen and no agent with that capability (so the step cannot run).
    func missingTeams(for project: Project) -> [TeamRole] {
        let roles = Set(project.steps.filter { $0.kind != .approval && $0.agentIDs.isEmpty }.compactMap { $0.role })
        return TeamRole.allCases.filter { role in
            roles.contains(role) && project.steps.contains { $0.role == role && $0.agentIDs.isEmpty && ProjectFlow.agent(for: $0, in: company) == nil }
        }
    }

    /// The agents who do a step (none for approvals).
    func stepCrew(_ project: Project, _ step: FlowStep) -> [Person] {
        guard step.kind != .approval else { return [] }
        return ProjectFlow.agents(for: step, in: company).map { $0.person }
    }

    /// Everybody who can be given a step: the whole pool.
    func projectAgents(_ project: Project) -> [Person] { company.allPeople }

    /// The projects in which an agent does at least one step, with the steps.
    func usage(of personID: String) -> [(project: Project, steps: [FlowStep])] {
        projects.compactMap { p in
            let steps = p.steps.filter { s in stepCrew(p, s).contains { $0.id == personID } }
            return steps.isEmpty ? nil : (p, steps)
        }
    }

    /// The team new agents are added to (the agents page has no teams): the first with room, or a new one.
    func homeTeamID() -> String? {
        if let t = company.teams.first(where: { $0.members.count < Company.maxMembers }) { return t.id }
        guard company.teams.count < Company.maxTeams else { return nil }
        addTeam(name: "Agents")
        return company.teams.last?.id
    }

    // MARK: Editing a project

    func setBrief(_ projectID: String, _ text: String) {
        update(projectID) { $0.brief = text }
        if let p = projects.first(where: { $0.id == projectID }) {
            prepareFolders(p)
            try? text.write(to: p.folderURL.appendingPathComponent("handoff/00-brief.md"), atomically: true, encoding: .utf8)
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
    func connect(_ projectID: String, from: String, to: String, condition: EdgeCondition = .always, fromSide: FlowSide? = nil, toSide: FlowSide? = nil) -> Bool {
        guard !isRunning(projectID) else { return false }
        var ok = false
        update(projectID) { ok = $0.connect(from: from, to: to, condition: condition, fromSide: fromSide, toSide: toSide) }
        return ok
    }

    /// Moves an end of a connection to another step or side. Returns the connection's new id.
    @discardableResult
    func reconnect(_ projectID: String, _ edgeID: String, from: String? = nil, to: String? = nil, fromSide: FlowSide?, toSide: FlowSide?) -> String? {
        guard !isRunning(projectID) else { return nil }
        var id: String?
        update(projectID) { id = $0.reconnect(edgeID, from: from, to: to, fromSide: fromSide, toSide: toSide) }
        return id
    }

    /// Adds an agent to a step. A step that still uses its team's default agent keeps that agent first.
    func addStepAgent(_ projectID: String, _ stepID: String, _ personID: String) {
        guard !isRunning(projectID), let project = projects.first(where: { $0.id == projectID }),
              let step = project.step(stepID), !step.agentIDs.contains(personID) else { return }
        var list = step.agentIDs
        if list.isEmpty, step.kind != .task, let d = ProjectFlow.agent(for: step, in: projectCompany(project)), d.person.id != personID { list = [d.person.id] }
        list.append(personID)
        updateStep(projectID, stepID) { $0.agentIDs = list; if $0.kind == .task { $0.customRole = nil } }
    }

    func removeStepAgent(_ projectID: String, _ stepID: String, _ personID: String) {
        guard !isRunning(projectID) else { return }
        updateStep(projectID, stepID) { $0.agentIDs.removeAll { $0 == personID } }
    }

    /// Puts the steps back in rows (layout only).
    func arrangeSteps(_ projectID: String) {
        update(projectID) { p in
            var steps = p.steps
            ProjectFlow.arrange(&steps)
            p.steps = steps
        }
    }

    func setEdge(_ projectID: String, _ edgeID: String, condition: EdgeCondition?) {
        guard !isRunning(projectID) else { return }
        update(projectID) { p in
            guard let i = p.edges.firstIndex(where: { $0.id == edgeID }) else { return }
            if let condition { p.edges[i].condition = condition } else { p.edges.remove(at: i) }
        }
    }

    func setEdgeLabel(_ projectID: String, _ edgeID: String, _ label: String) {
        update(projectID) { p in
            if let i = p.edges.firstIndex(where: { $0.id == edgeID }) { p.edges[i].label = label }
        }
    }

    @discardableResult
    func insertStep(_ projectID: String, kind: StepKind, on edgeID: String) -> String? {
        guard !isRunning(projectID) else { return nil }
        var id: String?
        update(projectID) { id = $0.insertStep(kind: kind, on: edgeID) }
        return id
    }

    @discardableResult
    func duplicateStep(_ projectID: String, _ stepID: String) -> String? {
        guard !isRunning(projectID) else { return nil }
        var id: String?
        update(projectID) { id = $0.duplicateStep(stepID) }
        return id
    }

    // Notes are documentation, so they can be edited any time.
    @discardableResult
    func addNote(_ projectID: String, at point: CGPoint) -> String {
        let note = FlowNote(x: Double(point.x), y: Double(point.y))
        update(projectID) { $0.notes.append(note) }
        return note.id
    }

    func editNote(_ projectID: String, _ noteID: String, _ change: (inout FlowNote) -> Void) {
        update(projectID) { p in
            if let i = p.notes.firstIndex(where: { $0.id == noteID }) { change(&p.notes[i]) }
        }
    }

    func removeNote(_ projectID: String, _ noteID: String) {
        update(projectID) { $0.notes.removeAll { $0.id == noteID } }
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
                if all { p.steps[i].round = 0; p.steps[i].feedback = "" }
            }
            if all { for i in p.edges.indices { p.edges[i].rounds = 0 } }
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
        let crew = ProjectFlow.agents(for: step, in: company)
        guard let (team, agent) = crew.first else {
            return fail(!step.agentIDs.isEmpty ? "The agent for this step no longer exists. Pick another in the process."
                        : "No agent for this step. Pick one in the step's settings, or add an agent with the \(step.role?.title ?? "right") capability on the Agents page.")
        }
        updateStep(id, step.id) { $0.status = .running; $0.agentName = crew.map { $0.person.name }.joined(separator: ", ") }
        log(id, "▶ \(step.title): \(agent.name) (\(team.name)) started")
        defer { for member in crew { personStatus[member.person.id] = nil } }

        let output = step.outputFile.map { project.folderURL.appendingPathComponent($0) }
        if let output { try? FileManager.default.removeItem(at: output) }
        let instruction = ProjectFlow.instruction(for: step, project: project)
        var bad = false
        do {
            var summary = ""
            for (n, member) in crew.enumerated() {
                let person = member.person
                personStatus[person.id] = .working
                var text = instruction
                if n > 0 {
                    log(id, "\u{25B6} \(person.name) (\(member.team.name)) takes over from \(crew[n - 1].person.name)")
                    text += """


                    TEAMMATES WORKED ON THIS STEP BEFORE YOU: \(crew[..<n].map { $0.person.name }.joined(separator: ", ")).
                    Read what they produced (the output file and the other files in the project folder). Do not start over: check it, correct mistakes, fill gaps and improve it, and leave the output file complete and in the required format.
                    """
                }
                summary = try await engine.runTask(as: person, company: company, instruction: text,
                                                   directory: project.folderURL, stage: step.id) { [weak self] tool in
                    Task { @MainActor in self?.log(id, "   \(person.firstName): \(tool)") }
                }
                personStatus[person.id] = nil
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
            if bad, let loop = project.edges.first(where: { $0.loop && $0.from == step.id }) {
                // Send the work back: the target and everything after it (this step included) run again.
                guard loop.rounds < ProjectFlow.maxLoops else {
                    return fail("\(step.outputFile ?? "The report") still reports problems after \(ProjectFlow.maxLoops) rework rounds. Fix it yourself or retry.")
                }
                let feedback = step.outputFile ?? ""
                update(id) { p in
                    guard let e = p.edges.firstIndex(where: { $0.id == loop.id }) else { return }
                    p.edges[e].rounds += 1
                    for i in p.steps.indices where p.downstream(of: loop.to).contains(p.steps[i].id) {
                        p.steps[i].status = .pending; p.steps[i].error = ""; p.steps[i].summary = ""; p.steps[i].badVerdict = false
                        if p.steps[i].id == loop.to { p.steps[i].round = p.edges[e].rounds; p.steps[i].feedback = feedback }
                    }
                }
                let target = project.step(loop.to)?.title ?? loop.to
                log(id, "\u{21BB} \(step.title) found problems: back to \(target) (rework round \(loop.rounds + 1) of \(ProjectFlow.maxLoops)).")
                return true
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
