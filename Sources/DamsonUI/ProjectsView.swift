import SwiftUI
import AppKit
import DamsonCore

/// The delivery process: requirements, design, build, review, then per environment: approval, provision, deploy, test.
struct ProjectsView: View {
    @ObservedObject var model: AppModel

    private var project: Project? { model.projects.first { $0.id == model.selectedProjectID } ?? model.projects.first }

    var body: some View {
        Group {
            if let project {
                ProjectDetail(model: model, project: project)
                    .id(project.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.clipboard").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No projects yet").font(.headline)
                    Text("Write the high-level requirements, choose the teams and agents, and define the process as a flow. The standard process takes it through analysis and requirements, design, build and review, then qa, uat and production with your approval at each gate.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("New project") { model.showNewProject = true }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.chatBackground)
        .navigationTitle(project?.name ?? "Projects")
        .sheet(isPresented: $model.showNewProject) {
            NewProjectSheet(model: model) { model.selectedProjectID = $0.id }
        }
    }

}

extension Project {
    /// One line for the sidebar: where the process stands.
    var statusLine: String {
        let p = self
        if p.isFinished { return "Finished" }
        if let s = p.steps.first(where: { $0.status == .running }) { return "Running: \(s.title)" }
        if let s = p.steps.first(where: { $0.status == .waiting }) { return "Waiting: \(s.title)" }
        if let s = p.steps.first(where: { $0.status == .failed }) { return "Failed: \(s.title)" }
        if let s = p.steps.first(where: { $0.status == .rejected }) { return "Rejected: \(s.title)" }
        let done = p.steps.filter { $0.status == .done }.count
        return done == 0 ? "Not started" : "\(done)/\(p.steps.count) steps done"
    }
}

private struct ProjectDetail: View {
    @ObservedObject var model: AppModel
    let project: Project
    @State private var openFile: String?
    @State private var content = ""
    @State private var confirmDelete = false
    @State private var editingEnv: EnvSettings?
    @State private var gateNote = ""
    @State private var tab = Tab.overview
    @State private var draftBrief = ""

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", process = "Process", progress = "Progress"
        var id: String { rawValue }
    }

    private var running: Bool { model.isRunning(project.id) }
    private var missing: [TeamRole] { model.missingTeams(for: project) }
    private var files: [String] {
        let known = project.steps.compactMap { $0.outputFile } + ["reports/production-release.md"]
        var seen = Set<String>()
        return known.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent($0).path) }
    }
    private var needsAction: Bool { project.steps.contains { $0.status == .waiting } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            if !missing.isEmpty { missingBanner }
            switch tab {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        requirementsSection
                        crewSection
                        environmentsSection
                    }
                    .padding(.bottom, 20)
                }
            case .process:
                ProcessEditorView(model: model, project: project)
            case .progress:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 8) {
                            ForEach(Array(project.steps.enumerated()), id: \.element.id) { i, step in stepRow(step, index: i) }
                        }
                        filesSection
                        logSection
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(20)
        .onChange(of: project.steps) { _, _ in reload() }
        .onAppear { openFile = files.last; reload(); draftBrief = project.brief }
        .sheet(item: $editingEnv) { env in
            EnvironmentSheet(env: env) { model.updateEnvironment(project.id, $0) }
        }
        .confirmationDialog("Delete project \(project.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from list (files stay on disk)", role: .destructive) { model.deleteProject(project.id) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.name).font(.title2.weight(.semibold))
                Spacer()
                if running {
                    Button("Stop") { model.cancelProject(project.id) }
                } else if project.isFinished {
                    Button("Run again") { model.startProject(project.id, all: true); tab = .progress }
                } else if !needsAction {
                    Button(project.steps.contains { $0.status == .failed || $0.status == .done } ? "Continue" : "Start") {
                        model.startProject(project.id); tab = .progress
                    }
                    .buttonStyle(.borderedProminent).disabled(!missing.isEmpty || project.steps.isEmpty)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([project.folderURL]) } label: { Image(systemName: "folder") }
                    .help("Show the project folder in Finder")
                Button { NSWorkspace.shared.open(project.folderURL.appendingPathComponent("reports")) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Open the reports folder")
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(running)
            }
            Text(project.folder).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private var missingBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("No agent can do these steps yet: \(missing.map { $0.title }.joined(separator: ", ")). Choose agents in the Process tab or add agents with that capability.").font(.callout)
            Spacer()
            Button("Add standard agents") { model.setupDeliveryTeams() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("High-level requirements").font(.headline)
            Text("What the business needs. The business analysis agent turns this into detailed requirements, and the other steps follow from them.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draftBrief)
                .font(.callout).frame(height: 170)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                .disabled(running)
            HStack {
                Button("Save requirements") { model.setBrief(project.id, draftBrief.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(draftBrief.trimmingCharacters(in: .whitespacesAndNewlines) == project.brief || running)
                if draftBrief.trimmingCharacters(in: .whitespacesAndNewlines) != project.brief {
                    Text("Not saved yet").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Who works on the project: found from the process steps (choose agents in the Process tab).
    private var crewSection: some View {
        let rows = project.orderedSteps.filter { $0.kind != .approval }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Agents").font(.headline)
            Text("Agents come from the shared pool. Choose who does each step in the Process tab: click a step and use Add agent.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { step in
                let crew = model.stepCrew(project, step)
                HStack(alignment: .top) {
                    Image(systemName: step.kind.icon).foregroundStyle(Theme.green).frame(width: 22)
                    Text(step.title).font(.subheadline.weight(.semibold)).frame(width: 190, alignment: .leading)
                    Text(crew.isEmpty ? "no agent" : crew.map { $0.name }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(crew.isEmpty ? Color.orange : Color.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var environmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environments").font(.headline)
            Text("Platform and Deployment work from these settings. Click Edit to choose where each environment runs.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(project.environments) { env in
                HStack {
                    Image(systemName: "server.rack").foregroundStyle(Theme.green)
                    Text(env.name).font(.subheadline.weight(.semibold)).frame(width: 90, alignment: .leading)
                    Text(env.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Edit") { editingEnv = env }.controlSize(.small).disabled(running)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            }
        }
    }

    @ViewBuilder private func stepRow(_ step: FlowStep, index: Int) -> some View {
        if step.kind == .approval { gateRow(step, index: index) } else { agentRow(step) }
    }

    private func agentRow(_ step: FlowStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(step.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: step.kind.icon).foregroundStyle(Theme.green)
                    Text(step.title).font(.subheadline.weight(.semibold))
                    Text("\u{00B7} \(step.role?.title ?? "Custom")\(step.agentName.isEmpty ? "" : " (\(step.agentName))")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let f = step.outputFile { Text("Writes \(f)").font(.caption2).foregroundStyle(.tertiary) }
                if !step.error.isEmpty { Text(step.error).font(.caption).foregroundStyle(.red) }
                if !step.summary.isEmpty { Text(step.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            if step.status == .failed && !running {
                Button("Retry") { model.startProject(project.id, from: step.id) }.controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }

    /// An approval gate. Only these buttons (or the user's own words) pass it.
    private func gateRow(_ step: FlowStep, index: Int) -> some View {
        let warning = step.status == .waiting ? model.gateWarning(project, index: index) : nil
        let report = project.reportBefore(index)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                statusIcon(step.status)
                Image(systemName: step.kind.icon).foregroundStyle(.orange)
                Text(step.title).font(.subheadline.weight(.semibold))
                Text("\u{00B7} you decide").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if step.status == .waiting {
                if !step.about.isEmpty { Text(step.about).font(.callout).textSelection(.enabled) }
                if let report {
                    Button { openFile = report; reload() } label: { Label("Read \((report as NSString).lastPathComponent)", systemImage: "doc.text") }
                        .controlSize(.small)
                }
                if let warning {
                    Label("\(warning) Approving anyway is your decision.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Note (optional)", text: $gateNote).textFieldStyle(.roundedBorder).font(.caption)
                HStack {
                    Button(warning == nil ? "Approve" : "Approve anyway") {
                        model.approveGate(project.id, step.id, note: gateNote, anyway: true); gateNote = ""
                    }
                    .buttonStyle(.borderedProminent).tint(warning == nil ? Theme.green : .orange)
                    Button("Reject", role: .destructive) { model.rejectGate(project.id, step.id, note: gateNote); gateNote = "" }
                }
            } else if step.status == .rejected {
                Text("Rejected\(step.note.isEmpty ? "" : ": \(step.note)")").font(.caption).foregroundStyle(.red)
                Button("Reopen") { model.reopenGate(project.id, step.id) }.controlSize(.small)
            } else if step.status == .done && !step.note.isEmpty {
                Text("Approved: \(step.note)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(step.status == .waiting ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(step.status == .waiting ? 0.6 : 0.25), lineWidth: 1))
    }

    @ViewBuilder private func statusIcon(_ status: StepStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.onlineGreen)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .rejected: Image(systemName: "hand.raised.slash.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files and reports").font(.headline)
            if files.isEmpty {
                Text("Nothing written yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(get: { openFile ?? files.last ?? "" }, set: { openFile = $0; reload() })) {
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
                ScrollView {
                    Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 260)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(.headline)
            let lines = model.projectLog[project.id] ?? []
            if lines.isEmpty { Text("No activity yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(lines.suffix(40).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func reload() {
        let name = openFile ?? files.last
        guard let name else { content = ""; return }
        if openFile == nil { openFile = name }
        content = (try? String(contentsOf: project.folderURL.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
}

private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let onCreate: (Project) -> Void
    @State private var name = ""
    @State private var brief = ""

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.headline)
            TextField("Project name", text: $name)
            Text("High-level requirements: what does the business need? Describe the application, who uses it and why.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $brief)
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
            Text("The project folder is created inside your workspace folder. Teams pass work to each other as files in its handoff folder.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create and start") { create(start: true) }.keyboardShortcut(.defaultAction).disabled(!valid)
                Button("Create") { create(start: false) }.disabled(!valid)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func create(start: Bool) {
        let p = model.createProject(name: name.trimmingCharacters(in: .whitespaces), brief: brief.trimmingCharacters(in: .whitespacesAndNewlines))
        onCreate(p)
        if start && model.missingTeams(for: p).isEmpty { model.startProject(p.id) }
        dismiss()
    }
}

/// Choose where an environment runs and its target-specific settings.
private struct EnvironmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let env: EnvSettings
    let onSave: (EnvSettings) -> Void
    @State private var target: DeployTarget
    @State private var options: [String: String]

    init(env: EnvSettings, onSave: @escaping (EnvSettings) -> Void) {
        self.env = env
        self.onSave = onSave
        _target = State(initialValue: env.target)
        _options = State(initialValue: env.options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment: \(env.name)").font(.headline)
            Picker("Runs on", selection: $target) {
                ForEach(DeployTarget.allCases) { Text($0.title).tag($0) }
            }
            ForEach(target.options, id: \.key) { o in
                TextField(o.label, text: Binding(get: { options[o.key] ?? "" }, set: { options[o.key] = $0 }), prompt: Text(o.placeholder))
            }
            Text("Platform and Deployment use these settings to provision and deploy. Empty fields are chosen by the agent. Cloud targets need the cloud's command-line tool installed and signed in on this Mac.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let keys = Set(target.options.map { $0.key })
                    onSave(EnvSettings(name: env.name, target: target, options: options.filter { keys.contains($0.key) }))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}
