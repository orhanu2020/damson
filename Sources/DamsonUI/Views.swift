import SwiftUI
import AppKit
import DamsonProviders
import DamsonTools
import DamsonCore
import DamsonVoice

enum SidebarItem: String, CaseIterable, Identifiable {
    case company = "Company"
    case projects = "Projects"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .company: return "building.2.fill"
        case .projects: return "list.bullet.clipboard.fill"
        case .settings: return "gearshape"
        }
    }
}

public struct RootView: View {
    @ObservedObject var model: AppModel
    /// "company", "settings", "team:<id>" or "person:<id>".
    @State private var selection: String? = "company"
    @State private var companyOpen = true
    @State private var collapsedTeams: Set<String> = []

    public init(model: AppModel) {
        self.model = model
    }

    private var page: SidebarItem {
        guard let s = selection else { return .company }
        if s == "settings" { return .settings }
        if s == "projects" { return .projects }
        return .company
    }

    /// Company, with its teams under it and each team's agents under the team.
    @ViewBuilder private var companyTree: some View {
        DisclosureGroup(isExpanded: $companyOpen) {
            ForEach(model.company.teams) { team in
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedTeams.contains(team.id) },
                    set: { if $0 { collapsedTeams.remove(team.id) } else { collapsedTeams.insert(team.id) } }
                )) {
                    ForEach(team.members) { person in
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
                        .contextMenu { AgentContextMenu(model: model, person: person) }
                    }
                } label: {
                    Label {
                        HStack {
                            Text(team.name).lineLimit(1)
                            Spacer()
                            Text("\(team.members.count)").font(.caption).foregroundStyle(.secondary)
                            Button { model.companySheet = .newAgent(teamID: team.id) } label: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.green)
                            }
                            .buttonStyle(.plain)
                            .disabled(team.members.count >= Company.maxMembers)
                            .help(team.members.count >= Company.maxMembers ? "This team is full" : "Add an agent to \(team.name)")
                        }
                    } icon: {
                        Image(systemName: "person.2").foregroundStyle(Theme.green)
                    }
                    .tag("team:" + team.id)
                }
            }
        } label: {
            HStack {
                Label("Company", systemImage: SidebarItem.company.icon)
                Spacer()
                Button { model.companySheet = .newTeam } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Theme.green)
                }
                .buttonStyle(.plain)
                .disabled(model.company.teams.count >= Company.maxTeams)
                .help(model.company.teams.count >= Company.maxTeams ? "The office is full" : "Add a team")
            }
            .tag("company")
        }
    }

    private func applySelection(_ new: String?) {
        model.companyViewActive = new != nil && new != "settings" && new != "projects"
        guard let new else { return }
        if new.hasPrefix("person:") {
            model.selectedPeople = [String(new.dropFirst(7))]
        } else if new.hasPrefix("team:"), let team = model.company.teams.first(where: { $0.id == String(new.dropFirst(5)) }) {
            model.selectedPeople = Set(team.members.map { $0.id })
        }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                companyTree
                Label("Projects", systemImage: SidebarItem.projects.icon).tag("projects")
                Label("Settings", systemImage: SidebarItem.settings.icon).tag("settings")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !model.approvals.isEmpty {
                    ApprovalBanner(model: model)
                }
                switch page {
                case .company: CompanyView(model: model, status: model.voiceStatus)
                case .projects: ProjectsView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .onChange(of: selection) { _, new in applySelection(new) }
            .toolbar {
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
