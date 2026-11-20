import SwiftUI
import DamsonSupport
import DamsonCore

extension AppModel {
    // MARK: Teams for the process

    /// Adds whichever of the four delivery teams (Project Management, Business Analysis, Dev, Test) are missing,
    /// each with an agent that has fitting skills and a Claude model.
    func setupDeliveryTeams() {
        for skill in Skill.builtins where !company.skillLibrary.contains(where: { $0.name == skill.name }) {
            company.skillLibrary.append(skill)
        }
        let plan: [(StageKind, String, Person)] = [
            (.requirements, "Business Analysis", Person(id: newPersonID(), name: "Kerem Aksoy", role: "Business Analyst",
                skills: ["Requirements analysis", "Research & summarizing"], model: "claude-sonnet-5-5")),
            (.estimate, "Project Management", Person(id: newPersonID(), name: "Selma Yıldırım", role: "Project Manager",
                skills: ["Time & effort estimation", "Project management"], model: "claude-sonnet-5-5")),
            (.development, "Dev", Person(id: newPersonID(), name: "Mert Çelik", role: "Senior Developer",
                skills: ["Software development", "Backend & APIs", "Deployment & DevOps"], model: "claude-opus-5-5")),
            (.testing, "Test", Person(id: newPersonID(), name: "Nehir Tan", role: "QA Engineer",
                skills: ["Test automation", "Testing & QA"], model: "claude-sonnet-5-5")),
        ]
        for (kind, teamName, person) in plan where ProjectFlow.team(for: kind, in: company) == nil {
            guard company.teams.count < Company.maxTeams else { break }
            company.teams.append(Team(id: newPersonID(), name: teamName, members: [person]))
        }
    }

    private func newPersonID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Which stages cannot run because no team matches them.
    func missingTeams() -> [StageKind] {
        StageKind.allCases.filter { ProjectFlow.team(for: $0, in: company) == nil }
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
        for sub in ProjectFlow.folders {
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try? brief.write(to: folder.appendingPathComponent("handoff/00-brief.md"), atomically: true, encoding: .utf8)
        projects.insert(project, at: 0)
        return project
    }

    func deleteProject(_ id: String) {
        cancelProject(id)
        projects.removeAll { $0.id == id }
        projectLog[id] = nil
    }

    func isRunning(_ id: String) -> Bool { projectTasks[id] != nil }

    private func update(_ id: String, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
    }

    private func log(_ id: String, _ line: String) {
        projectLog[id, default: []].append(line)
        if (projectLog[id]?.count ?? 0) > 300 { projectLog[id]?.removeFirst(100) }
    }

    func cancelProject(_ id: String) {
        projectTasks[id]?.cancel()
    }

    /// Runs the stages in order, starting at `from` (or the first unfinished stage). Stops at the first failure.
    func startProject(_ id: String, from: StageKind? = nil) {
        guard projectTasks[id] == nil, let project = projects.first(where: { $0.id == id }) else { return }
        let startIndex = from.flatMap { k in StageKind.allCases.firstIndex(of: k) }
            ?? (project.stages.firstIndex { $0.status != .done } ?? StageKind.allCases.count)
        update(id) { p in
            for i in p.stages.indices where i >= startIndex { p.stages[i].status = .pending; p.stages[i].error = ""; p.stages[i].summary = "" }
        }
        let task = Task { @MainActor in
            defer { projectTasks[id] = nil }
            for kind in StageKind.allCases.dropFirst(startIndex) {
                if Task.isCancelled { break }
                let ok = await runStage(kind, projectID: id)
                if !ok { break }
            }
        }
        projectTasks[id] = task
    }

    private func runStage(_ kind: StageKind, projectID id: String) async -> Bool {
        guard let project = projects.first(where: { $0.id == id }) else { return false }
        func fail(_ message: String) -> Bool {
            update(id) { p in if let i = p.stages.firstIndex(where: { $0.kind == kind }) { p.stages[i].status = .failed; p.stages[i].error = message } }
            log(id, "✗ \(kind.title): \(message)")
            return false
        }
        guard let team = ProjectFlow.team(for: kind, in: company), let agent = team.members.first else {
            return fail("No \(kind.teamLabel) team with an agent. Use Manage > Set up delivery teams.")
        }
        update(id) { p in
            if let i = p.stages.firstIndex(where: { $0.kind == kind }) { p.stages[i].status = .running; p.stages[i].agentName = agent.name }
        }
        personStatus[agent.id] = .working
        log(id, "▶ \(kind.title): \(agent.name) (\(team.name)) started")
        defer { personStatus[agent.id] = nil }

        let output = project.folderURL.appendingPathComponent(kind.outputFile)
        try? FileManager.default.removeItem(at: output)
        let instruction = ProjectFlow.instruction(for: kind, project: project)
        do {
            let summary = try await engine.runTask(as: agent, company: company, instruction: instruction,
                                                   directory: project.folderURL, stage: kind.rawValue) { [weak self] tool in
                Task { @MainActor in self?.log(id, "   \(agent.firstName): \(tool)") }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
            guard size > 0 else { return fail("\(agent.name) finished but did not write \(kind.outputFile).") }
            update(id) { p in if let i = p.stages.firstIndex(where: { $0.kind == kind }) { p.stages[i].status = .done; p.stages[i].summary = summary } }
            log(id, "✓ \(kind.title) done. Handed off in \(kind.outputFile)")
            if kind == .development { log(id, "   Dev deployed to the test environment and notified the Test team via the deploy notice.") }
            if kind == .testing { log(id, "★ Project finished. Test report: \(kind.outputFile)") }
            return true
        } catch where Task.isCancelled || error is CancellationError {
            update(id) { p in if let i = p.stages.firstIndex(where: { $0.kind == kind }) { p.stages[i].status = .pending } }
            log(id, "■ Stopped during \(kind.title).")
            return false
        } catch {
            return fail(error.localizedDescription)
        }
    }
}
