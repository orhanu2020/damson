import SwiftUI
import AppKit
import DamsonCore

/// The delivery process: brief -> requirements -> estimates -> development and deploy -> testing and report.
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
                        Text("Describe what the business needs. Business Analysis writes the requirements, Project Management estimates them, Dev builds and deploys, and Test tests and reports.")
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
        if let s = p.stages.first(where: { $0.status == .running }) { return "Running: \(s.kind.title)" }
        if let s = p.stages.first(where: { $0.status == .failed }) { return "Failed: \(s.kind.title)" }
        let done = p.stages.filter { $0.status == .done }.count
        return done == 0 ? "Not started" : "\(done)/\(p.stages.count) stages done"
    }
}

private struct ProjectDetail: View {
    @ObservedObject var model: AppModel
    let project: Project
    @State private var openFile: String?
    @State private var content = ""
    @State private var confirmDelete = false

    private var running: Bool { model.isRunning(project.id) }
    private var missing: [StageKind] { model.missingTeams() }
    private var files: [String] {
        StageKind.allCases.map { $0.outputFile }.filter { FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent($0).path) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !missing.isEmpty { missingBanner }
                VStack(spacing: 8) {
                    ForEach(project.stages) { stage in stageRow(stage) }
                }
                filesSection
                logSection
            }
            .padding(20)
        }
        .onChange(of: project.stages) { _, _ in reload() }
        .onAppear { openFile = files.last; reload() }
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
                    Button("Run again") { model.startProject(project.id, from: .requirements) }
                } else {
                    Button(project.stages.contains { $0.status == .failed || $0.status == .done } ? "Continue" : "Start") {
                        model.startProject(project.id)
                    }
                    .buttonStyle(.borderedProminent).disabled(!missing.isEmpty)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([project.folderURL]) } label: { Image(systemName: "folder") }
                    .help("Show the project folder in Finder")
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(running)
            }
            Text(project.brief).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(project.folder).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private var missingBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Missing team(s): \(missing.map { $0.teamLabel }.joined(separator: ", ")).").font(.callout)
            Spacer()
            Button("Set up delivery teams") { model.setupDeliveryTeams() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private func stageRow(_ stage: ProjectStage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(stage.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: stage.kind.icon).foregroundStyle(Theme.green)
                    Text(stage.kind.title).font(.subheadline.weight(.semibold))
                    Text("\u{00B7} \(stage.kind.teamLabel)\(stage.agentName.isEmpty ? "" : " (\(stage.agentName))")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Writes \(stage.kind.outputFile)").font(.caption2).foregroundStyle(.tertiary)
                if !stage.error.isEmpty { Text(stage.error).font(.caption).foregroundStyle(.red) }
                if !stage.summary.isEmpty { Text(stage.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            if stage.status == .failed && !running {
                Button("Retry") { model.startProject(project.id, from: stage.kind) }.controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func statusIcon(_ status: StageStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.onlineGreen)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Handoff files").font(.headline)
            if files.isEmpty {
                Text("Nothing written yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(get: { openFile ?? files.last ?? "" }, set: { openFile = $0; reload() })) {
                    ForEach(files, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
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
