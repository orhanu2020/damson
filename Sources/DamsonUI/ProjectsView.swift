import SwiftUI
import AppKit
import DamsonCore

/// The delivery process: requirements, estimate, build, review, then per environment: approval, provision, deploy, test.
struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: String?
    @State private var showNew = false

    private var project: Project? { model.projects.first { $0.id == selectedID } ?? model.projects.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Projects").font(.headline)
                    Spacer()
                    Button { showNew = true } label: { Image(systemName: "plus") }.help("New project")
                }
                .padding(12)
                Divider()
                List(selection: Binding(get: { project?.id }, set: { selectedID = $0 })) {
                    ForEach(model.projects) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text(statusLine(p)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(p.id)
                    }
                }
            }
            .frame(width: 210)
            Divider()
            Group {
                if let project {
                    ProjectDetail(model: model, project: project)
                        .id(project.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.clipboard").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("No projects yet").font(.headline)
                        Text("Describe what the business needs. Business Analysis, Project Management and Dev build it; then, with your approval at each gate, Platform, Deployment and Test take it through qa, uat and production.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button("New project") { showNew = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.chatBackground)
        .navigationTitle("Projects")
        .sheet(isPresented: $showNew) {
            NewProjectSheet(model: model) { selectedID = $0.id }
        }
    }

    private func statusLine(_ p: Project) -> String {
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

    private var running: Bool { model.isRunning(project.id) }
    private var missing: [TeamRole] { model.missingTeams() }
    private var files: [String] {
        let known = project.steps.compactMap { $0.outputFile } + ["reports/production-release.md"]
        var seen = Set<String>()
        return known.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent($0).path) }
    }
    private var needsAction: Bool { project.steps.contains { $0.status == .waiting } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !missing.isEmpty { missingBanner }
                environmentsSection
                VStack(spacing: 8) {
                    ForEach(Array(project.steps.enumerated()), id: \.element.id) { i, step in stepRow(step, index: i) }
                }
                filesSection
                logSection
            }
            .padding(20)
        }
        .onChange(of: project.steps) { _, _ in reload() }
        .onAppear { openFile = files.last; reload() }
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
                    Button("Run again") { model.startProject(project.id, from: project.steps.first?.id) }
                } else if !needsAction {
                    Button(project.steps.contains { $0.status == .failed || $0.status == .done } ? "Continue" : "Start") {
                        model.startProject(project.id)
                    }
                    .buttonStyle(.borderedProminent).disabled(!missing.isEmpty)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([project.folderURL]) } label: { Image(systemName: "folder") }
                    .help("Show the project folder in Finder")
                Button { NSWorkspace.shared.open(project.folderURL.appendingPathComponent("reports")) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Open the reports folder")
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(running)
            }
            Text(project.brief).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(project.folder).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private var missingBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Missing team(s): \(missing.map { $0.title }.joined(separator: ", ")).").font(.callout)
            Spacer()
            Button("Set up delivery teams") { model.setupDeliveryTeams() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
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
                    Text("\u{00B7} \(step.kind.role?.title ?? "")\(step.agentName.isEmpty ? "" : " (\(step.agentName))")")
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
            Text("What does the business need? Describe the application, who uses it and why.").font(.caption).foregroundStyle(.secondary)
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
        if start && model.missingTeams().isEmpty { model.startProject(p.id) }
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
