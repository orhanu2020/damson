import SwiftUI
import DamsonCore
import DamsonProviders

/// Which modal dialog the Company tab is showing.
enum CompanySheet: Identifiable {
    case newTeam
    case renameTeam(Team)
    case newAgent(teamID: String)
    case editAgent(Person, teamID: String)

    var id: String {
        switch self {
        case .newTeam: return "newTeam"
        case .renameTeam(let t): return "rename-\(t.id)"
        case .newAgent(let id): return "new-\(id)"
        case .editAgent(let p, _): return "edit-\(p.id)"
        }
    }
}

/// Attaches the Company tab's modal dialogs and the delete-team confirmation.
struct CompanySheets: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.companySheet) { sheet in
                switch sheet {
                case .newTeam:
                    TeamSheet(title: "New team", name: "") { model.addTeam(name: $0) }
                case .renameTeam(let team):
                    TeamSheet(title: "Rename team", name: team.name) { model.renameTeam(team.id, to: $0) }
                case .newAgent(let teamID):
                    AgentSheet(model: model, person: nil, teamID: teamID)
                case .editAgent(let person, let teamID):
                    AgentSheet(model: model, person: person, teamID: teamID)
                }
            }
            .confirmationDialog("Delete team \(model.teamToDelete?.name ?? "")?",
                                isPresented: Binding(get: { model.teamToDelete != nil }, set: { if !$0 { model.teamToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete team and its agents", role: .destructive) {
                    if let t = model.teamToDelete { model.deleteTeam(t.id) }
                    model.teamToDelete = nil
                }
            } message: {
                Text("The \(model.teamToDelete?.members.count ?? 0) agent(s) in it are deleted too. This cannot be undone.")
            }
    }
}

/// The "Manage" menu in the Company header: teams and agents.
struct CompanyMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Button("New team\u{2026}") { model.companySheet = .newTeam }
                .disabled(model.company.teams.count >= Company.maxTeams)
            Menu("Rename team") {
                ForEach(model.company.teams) { team in Button(team.name) { model.companySheet = .renameTeam(team) } }
            }
            .disabled(model.company.teams.isEmpty)
            Menu("Delete team") {
                ForEach(model.company.teams) { team in Button(team.name, role: .destructive) { model.teamToDelete = team } }
            }
            .disabled(model.company.teams.isEmpty)
            Divider()
            Button("Set up delivery teams") { model.setupDeliveryTeams() }
                .help("Adds Business Analysis, Project Management, Dev and Test teams that are missing")

        } label: {
            Label("Manage", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Create or delete teams and agents")
    }
}

/// Right-click menu for an agent.
struct AgentContextMenu: View {
    @ObservedObject var model: AppModel
    let person: Person

    var body: some View {
        if let team = model.company.teams.first(where: { $0.members.contains { $0.id == person.id } }) {
            Button("Settings\u{2026}") { model.companySheet = .editAgent(person, teamID: team.id) }
            Menu("Move to") {
                ForEach(model.company.teams.filter { $0.id != team.id }) { other in
                    Button(other.name) { model.updatePerson(person, team: other.id) }
                        .disabled(other.members.count >= Company.maxMembers)
                }
            }
            Button("Clear chat") { model.clearPersonChat(person) }
            Divider()
            Button("Delete agent", role: .destructive) { model.deletePerson(person.id) }
        }
    }
}

struct TeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var name: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Team name", text: $name).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n)
        dismiss()
    }
}

struct AgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let person: Person?
    @State var teamID: String
    @State private var name: String
    @State private var role: String
    @State private var skills: [String]
    @State private var agentModel: String
    @State private var disabledTools: Set<String>

    init(model: AppModel, person: Person?, teamID: String) {
        self.model = model
        self.person = person
        _teamID = State(initialValue: teamID)
        _name = State(initialValue: person?.name ?? "")
        _role = State(initialValue: person?.role ?? "")
        _skills = State(initialValue: person?.skills ?? [])
        _agentModel = State(initialValue: person?.model ?? "")
        _disabledTools = State(initialValue: Set(person?.disabledTools ?? []))
    }

    private enum PickerKind: String, Identifiable { case skills, tools; var id: String { rawValue } }
    @State private var picker: PickerKind?

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !role.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(person == nil ? "New agent" : "Edit agent").font(.headline)
            TextField("Name (e.g. Alex Morgan)", text: $name)
            TextField("Role (e.g. Backend Developer)", text: $role)
            Picker("Team", selection: $teamID) {
                ForEach(model.company.teams) { Text($0.name).tag($0.id) }
            }
            Picker("Claude model (your subscription)", selection: $agentModel) {
                Text("Default (from Settings)").tag("")
                ForEach(ClaudeCodeProvider.knownModels, id: \.self) { Text($0).tag($0) }
            }
            Text("Claude models run through the Claude Code app signed in with your Claude subscription, not the API.").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { picker = .skills } label: { Label("Skills (\(skills.count))\u{2026}", systemImage: "sparkles") }
                Button { picker = .tools } label: {
                    Label("Tools (\(model.engine.tools.specs.count - disabledTools.count) of \(model.engine.tools.specs.count))\u{2026}", systemImage: "wrench.and.screwdriver")
                }
            }
            Text("Skills come from your Claude skills and installed plugins. Anything that changes your Mac or an account still asks for your approval.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 460)
        .sheet(item: $picker) { which in
            switch which {
            case .skills:
                ItemPickerSheet(title: "Skills", note: model.skills.isEmpty ? "No skills found (~/.claude/skills or installed plugins)." : "Your Claude skills. Selected ones are available to this agent.",
                                items: skillItems, selected: Binding(get: { Set(skills) }, set: { skills = Array($0).sorted() }))
            case .tools:
                ItemPickerSheet(title: "Tools", note: "Selected tools are available to this agent.",
                                items: model.engine.tools.specs.map { PickItem(id: $0.name, detail: $0.description) },
                                selected: Binding(get: { Set(model.engine.tools.specs.map { $0.name }).subtracting(disabledTools) },
                                                  set: { disabledTools = Set(model.engine.tools.specs.map { $0.name }).subtracting($0) }))
            }
        }
    }

    /// Skills on disk, plus any already assigned that are missing from disk so they can be removed.
    private var skillItems: [PickItem] {
        var items = model.skills.map { PickItem(id: $0.id, detail: $0.description) }
        for n in skills where !items.contains(where: { $0.id == n }) { items.append(PickItem(id: n, detail: "Not found any more")) }
        return items
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let r = role.trimmingCharacters(in: .whitespaces)
        if var p = person {
            p.name = n; p.role = r; p.skills = skills; p.model = agentModel.isEmpty ? nil : agentModel; p.disabledTools = disabledTools.sorted()
            model.updatePerson(p, team: teamID)
        } else {
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            model.addPerson(Person(id: id, name: n, role: r, skills: skills, model: agentModel.isEmpty ? nil : agentModel, disabledTools: disabledTools.sorted()), to: teamID)
        }
        dismiss()
    }
}

struct PickItem: Identifiable { let id: String; let detail: String }

/// A list of items, one per line with a checkbox, ten visible at a time and a scrollbar for the rest.
struct ItemPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let note: String
    let items: [PickItem]
    @Binding var selected: Set<String>
    @State private var filter = ""

    private var shown: [PickItem] {
        let q = filter.lowercased()
        return q.isEmpty ? items : items.filter { $0.id.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
    }
    private let rowHeight: CGFloat = 38

    var body: some View {
        let rows = CGFloat(min(max(shown.count, 1), 10))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Text("\(selected.count) of \(items.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("All") { selected.formUnion(shown.map { $0.id }) }.disabled(shown.isEmpty)
                Button("None") { selected.subtract(shown.map { $0.id }) }.disabled(shown.isEmpty)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
            if items.count > 10 { TextField("Filter", text: $filter).textFieldStyle(.roundedBorder) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.id) },
                                             set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.id).lineLimit(1)
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .frame(height: rowHeight - 1, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: rowHeight * rows)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 460)
    }
}
