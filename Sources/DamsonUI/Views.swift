import SwiftUI
import AppKit
import DamsonProviders
import DamsonTools
import DamsonCore
import DamsonVoice

enum SidebarItem: String, CaseIterable, Identifiable {
    case company = "Office"
    case projects = "Projects"
    case agents = "Agents"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .company: return "building.2.fill"
        case .projects: return "list.bullet.clipboard.fill"
        case .agents: return "person.2.crop.square.stack.fill"
        case .settings: return "gearshape"
        }
    }
}

public struct RootView: View {
    @ObservedObject var model: AppModel
    /// "projects", "project:<id>", "office", "settings", "team:<id>" or "person:<id>".
    @State private var selection: String? = "projects"
    @State private var collapsedProjects: Set<String> = []
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var collapsedTeams: Set<String> = []

    public init(model: AppModel) {
        self.model = model
    }

    private var page: SidebarItem {
        guard let s = selection else { return .projects }
        if s == "settings" { return .settings }
        if s == "agents" { return .agents }
        if s == "projects" || s.hasPrefix("project:") || s.hasPrefix("step:") { return .projects }
        return .company
    }

    private func personRow(_ person: Person, prefix: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(person.name).lineLimit(1)
                Text(person.role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.olive)
        }
        .tag("person:" + person.id)
        .help("\(person.name), \(person.role)\nModel: \(person.model ?? "default")\nSkills: \(person.skills.isEmpty ? "none" : person.skills.joined(separator: ", "))")
    }

    /// Projects, each with the teams working on it and each team's agents under the team.
    @ViewBuilder private var projectsTree: some View {
        do {
            ForEach(model.projects) { project in
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedProjects.contains(project.id) },
                    set: { if $0 { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) } }
                )) {
                    ForEach(project.orderedSteps) { step in
                        let crew = model.stepCrew(project, step)
                        let key = project.id + step.id
                        let label = Label {
                            HStack {
                                Text(step.title).lineLimit(1)
                                Spacer()
                                if step.kind == .approval { Text("you").font(.caption).foregroundStyle(.secondary) }
                                else if crew.isEmpty { Text("no agent").font(.caption).foregroundStyle(.orange) }
                                else if crew.count > 1 { Text("\(crew.count)").font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: {
                            Image(systemName: step.kind.icon).foregroundStyle(step.kind == .approval ? Color.orange : Theme.green)
                        }
                        .tag("step:" + project.id + ":" + step.id)
                        if crew.isEmpty {
                            label
                        } else {
                            DisclosureGroup(isExpanded: Binding(
                                get: { !collapsedTeams.contains(key) },
                                set: { if $0 { collapsedTeams.remove(key) } else { collapsedTeams.insert(key) } }
                            )) {
                                ForEach(crew) { personRow($0, prefix: key) }
                            } label: { label }
                        }
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(project.name).lineLimit(1)
                            Text(project.statusLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(Theme.green)
                    }
                    .tag("project:" + project.id)
                }
            }
        }
    }

    private func applySelection(_ new: String?) {
        model.companyViewActive = new != nil && new != "settings" && new != "agents" && new != "projects" && !(new?.hasPrefix("project:") ?? false) && !(new?.hasPrefix("step:") ?? false)
        guard let new else { return }
        if new.hasPrefix("step:") {
            model.selectedProjectID = String(new.dropFirst(5).prefix { $0 != ":" })
        } else if new.hasPrefix("project:") {
            model.selectedProjectID = String(new.dropFirst(8))
        } else if new.hasPrefix("person:") {
            model.selectedPeople = [String(new.dropFirst(7))]
        } else if new.hasPrefix("team:"), let team = model.company.teams.first(where: { $0.id == String(new.dropFirst(5)) }) {
            model.selectedPeople = Set(team.members.map { $0.id })
        }
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                projectsTree
                Label("Agents", systemImage: SidebarItem.agents.icon).tag("agents")
                Label("Office", systemImage: SidebarItem.company.icon).tag("office")
                Label("Settings", systemImage: SidebarItem.settings.icon).tag("settings")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 250, max: 600)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                Button { model.showNewProject = true; selection = "projects" } label: {
                    Label("New project", systemImage: "plus.circle.fill").foregroundStyle(Theme.green)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.approvals.isEmpty {
                    ApprovalBanner(model: model)
                }
                ProcessApprovalBanner(model: model)
                switch page {
                case .company: CompanyView(model: model, status: model.voiceStatus)
                case .projects: ProjectsView(model: model)
                case .agents: AgentsView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .sheet(isPresented: $model.showNewProject) {
                NewProjectSheet(model: model) { model.selectedProjectID = $0.id; selection = "project:" + $0.id }
            }
            .onChange(of: model.openProject) { _, id in
                if let id { selection = "project:" + id; model.openProject = nil }
            }
            .onChange(of: selection) { _, new in applySelection(new) }
            .onChange(of: model.projects.map { $0.id }) { _, ids in
                if selection?.hasPrefix("project:") == true || selection?.hasPrefix("step:") == true, let sel = model.selectedProjectID, !ids.contains(sel) { selection = "projects" }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { columns = columns == .all ? .detailOnly : .all } label: { Image(systemName: "sidebar.left") }
                        .help("Show or hide the sidebar")
                        .keyboardShortcut("s", modifiers: [.command, .option])
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.toggleSpeech() } label: {
                        Image(systemName: model.settings.voiceOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(model.settings.voiceOutputEnabled ? Theme.green : Color.orange)
                    }
                    .help(model.settings.voiceOutputEnabled ? "Damson speaks aloud. Click to mute." : "Damson is muted. Click to let it speak.")
                }
            }
        }
        .modifier(CompanySheets(model: model))
        .frame(minWidth: 980, minHeight: 620)
    }
}

// MARK: - Approvals

struct ApprovalBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.approvals) { request in
                VStack(alignment: .leading, spacing: 6) {
                    Label("Approval needed", systemImage: "hand.raised.fill")
                        .font(.headline)
                    Text(request.summary)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Approve once") { model.resolve(request, .approveOnce) }
                            .keyboardShortcut(.defaultAction)
                        Button("Approve for this task") { model.resolve(request, .approveForTask) }
                        Button("Deny", role: .destructive) { model.resolve(request, .deny) }
                        Spacer()
                        Text("or say \"approve\" / \"deny\"").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding([.horizontal, .top], 12)
    }
}

/// Process gates waiting for the user, from every project, shown on every page like other approvals.
struct ProcessApprovalBanner: View {
    @ObservedObject var model: AppModel
    @State private var notes: [String: String] = [:]

    private struct Gate: Identifiable {
        let project: Project
        let step: FlowStep
        let index: Int
        var id: String { project.id + "|" + step.id }
    }

    private var gates: [Gate] {
        model.projects.flatMap { p in
            p.steps.enumerated().compactMap { i, s in
                s.kind == .approval && s.status == .waiting ? Gate(project: p, step: s, index: i) : nil
            }
        }
    }

    var body: some View {
        let list = gates
        if !list.isEmpty {
            VStack(spacing: 8) {
                ForEach(list) { gate in row(gate) }
            }
            .padding([.horizontal, .top], 12)
        }
    }

    private func row(_ gate: Gate) -> some View {
        let warning = model.gateWarning(gate.project, index: gate.index)
        let report = gate.project.reportBefore(gate.index)
        let note = Binding(get: { notes[gate.id] ?? "" }, set: { notes[gate.id] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Approval needed", systemImage: "hand.raised.fill").font(.headline)
                Text("\(gate.project.name) \u{00B7} \(gate.step.title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Open project") { model.openProject = gate.project.id }.controlSize(.small)
            }
            if !gate.step.about.isEmpty { Text(gate.step.about).font(.callout).textSelection(.enabled) }
            if let report {
                Button { NSWorkspace.shared.open(gate.project.folderURL.appendingPathComponent(report)) } label: {
                    Label("Read \((report as NSString).lastPathComponent)", systemImage: "doc.text")
                }
                .controlSize(.small)
            }
            if let warning {
                Label("\(warning) Approving anyway is your decision.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            TextField("Note (optional)", text: note).textFieldStyle(.roundedBorder).font(.caption)
            HStack {
                Button(warning == nil ? "Approve" : "Approve anyway") {
                    model.approveGate(gate.project.id, gate.step.id, note: notes[gate.id] ?? "", anyway: true)
                    notes[gate.id] = nil
                }
                .buttonStyle(.borderedProminent).tint(warning == nil ? Theme.green : .orange)
                Button("Reject", role: .destructive) {
                    model.rejectGate(gate.project.id, gate.step.id, note: notes[gate.id] ?? "")
                    notes[gate.id] = nil
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct VoiceStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: VoiceStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(status.mode == .off ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.mode.label).font(.callout)
                if status.mode != .off {
                    Text(status.inputDevice.isEmpty ? "Microphone: none found" : "Microphone: \(status.inputDevice)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if !status.partialTranscript.isEmpty {
                    Text(status.partialTranscript).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !status.message.isEmpty {
                    Text(status.message).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
            if status.mode != .off {
                ProgressView(value: status.inputLevel)
                    .frame(width: 70)
                    .help("Microphone level. If this stays flat while you talk, Damson cannot hear you.")
                Text("\(Int(status.inputLevelDB)) dB")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                    .help("About -20 dB is loud speech, -60 dB a quiet room, -120 dB means no signal at all.")
            }
            Spacer()
            if status.mode == .speaking || status.mode == .thinking {
                Button("Stop talking") { model.voice.stopSpeaking() }
            }
            Button(status.mode == .off ? "Start listening" : "Stop listening") { model.toggleListening() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.chip)
    }

    var icon: String {
        switch status.mode {
        case .off: return "mic.slash"
        case .listening: return "waveform"
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2"
        }
    }
}
