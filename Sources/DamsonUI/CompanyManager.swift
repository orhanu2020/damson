import SwiftUI
import DamsonCore
import DamsonProviders

/// Which agent dialog is showing.
enum CompanySheet: Identifiable {
    case newAgent(teamID: String)
    case editAgent(Person, teamID: String)

    var id: String {
        switch self {
        case .newAgent(let id): return "new-\(id)"
        case .editAgent(let p, _): return "edit-\(p.id)"
        }
    }
}

/// Attaches the agent dialogs.
struct CompanySheets: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.companySheet) { sheet in
                switch sheet {
                case .newAgent(let teamID):
                    AgentSheet(model: model, person: nil, teamID: teamID)
                case .editAgent(let person, let teamID):
                    AgentSheet(model: model, person: person, teamID: teamID)
                }
            }
    }
}

/// The agent dialog (opened from the office floor plan).
struct AgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let person: Person?
    let teamID: String

    private var presetCapability: String {
        guard person == nil, let p = model.pendingStepAgent, let proj = model.projects.first(where: { $0.id == p.project }) else { return "" }
        return proj.step(p.step)?.role?.title ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(person == nil ? "New agent" : "Edit agent").font(.headline)
            AgentForm(model: model, person: person, teamID: teamID, showTeam: true, presetCapability: presetCapability, onSaved: { id in
                if person == nil, let p = model.pendingStepAgent { model.addStepAgent(p.project, p.step, id) }
                dismiss()
            }, onCancel: { dismiss() })
        }
        .onDisappear { model.pendingStepAgent = nil }
        .padding(20).frame(width: 460)
    }
}

/// The settings of one agent: name, role, team, model, skills and tools. Used in the Agents page and in the dialog.
struct AgentForm: View {
    @ObservedObject var model: AppModel
    let person: Person?
    let showTeam: Bool
    let onSaved: (String) -> Void
    let onCancel: () -> Void
    @State private var capability: String
    @State var teamID: String
    @State private var name: String
    @State private var role: String
    @State private var skills: [String]
    @State private var agentModel: String
    @State private var disabledTools: Set<String>

    init(model: AppModel, person: Person?, teamID: String, showTeam: Bool = false, presetCapability: String = "", onSaved: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.showTeam = showTeam
        _capability = State(initialValue: person.map { ProjectFlow.capability(of: $0, in: model.company) } ?? presetCapability)
        self.person = person
        self.onSaved = onSaved
        self.onCancel = onCancel
        _teamID = State(initialValue: teamID)
        _name = State(initialValue: person?.name ?? "")
        _role = State(initialValue: person?.role ?? "")
        _skills = State(initialValue: person?.skills ?? [])
        _agentModel = State(initialValue: person?.model ?? "")
        _disabledTools = State(initialValue: Set(person?.disabledTools ?? []))
    }

    private enum PickerKind: String, Identifiable { case skills, tools; var id: String { rawValue } }
    @State private var picker: PickerKind?

    private var capabilityChoices: [String] {
        var all = ProjectFlow.capabilities + ["General"]
        for p in model.company.allPeople { let c = ProjectFlow.capability(of: p, in: model.company); if !all.contains(c) { all.append(c) } }
        return all
    }

    private var teamFull: Bool {
        guard person == nil else { return false }
        return (model.company.teams.first { $0.id == teamID }?.members.count ?? 0) >= Company.maxMembers
    }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !role.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name (e.g. Alex Morgan)", text: $name)
            TextField("Role (e.g. Backend Developer)", text: $role)
            HStack {
                TextField("Capability (e.g. Development)", text: $capability)
                Menu {
                    ForEach(capabilityChoices, id: \.self) { c in Button(c) { capability = c } }
                } label: { Image(systemName: "chevron.down.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Pick a capability")
            }
            Text("Agents are grouped by capability, and a step with no agent chosen takes the first agent with its capability.").font(.caption2).foregroundStyle(.secondary)
            if showTeam {
                Picker("Team", selection: $teamID) {
                    ForEach(model.company.teams) { Text($0.name).tag($0.id) }
                }
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
                Button(person == nil ? "Cancel" : "Revert") { onCancel() }
                Button(person == nil ? "Add agent" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid || teamFull)
            }
            if teamFull { Text("This team already has \(Company.maxMembers) agents.").font(.caption).foregroundStyle(.orange) }
        }
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
            p.name = n; p.role = r; p.capability = capability.trimmingCharacters(in: .whitespaces); p.skills = skills; p.model = agentModel.isEmpty ? nil : agentModel; p.disabledTools = disabledTools.sorted()
            model.updatePerson(p, team: teamID)
            onSaved(p.id)
        } else {
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            model.addPerson(Person(id: id, name: n, role: r, skills: skills, model: agentModel.isEmpty ? nil : agentModel, disabledTools: disabledTools.sorted(), capability: capability.trimmingCharacters(in: .whitespaces)), to: teamID)
            onSaved(id)
        }
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
