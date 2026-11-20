import SwiftUI
import DamsonCore
import DamsonProviders

/// Which modal dialog the Company tab is showing.
enum CompanySheet: Identifiable {
    case newTeam
    case renameTeam(Team)
    case newAgent(teamID: String)
    case editAgent(Person, teamID: String)
    case skills

    var id: String {
        switch self {
        case .newTeam: return "newTeam"
        case .renameTeam(let t): return "rename-\(t.id)"
        case .newAgent(let id): return "new-\(id)"
        case .editAgent(let p, _): return "edit-\(p.id)"
        case .skills: return "skills"
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
                case .skills:
                    SkillsLibrarySheet(model: model)
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

/// The "Manage" menu in the Company header: teams, agents and skills.
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
            Button("Skills library\u{2026}") { model.companySheet = .skills }
        } label: {
            Label("Manage", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Create or delete teams and agents, and edit skills")
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

private struct SkillsLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var editing: SkillEdit?

    private struct SkillEdit: Identifiable { let skill: Skill?; var id: String { skill?.name ?? "new" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skills library").font(.headline)
                Spacer()
                Button { editing = SkillEdit(skill: nil) } label: { Label("New skill", systemImage: "plus") }
            }
            Text("Skills are instructions an agent follows. Assign them in an agent's settings.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.company.skillLibrary) { skill in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            Text(skill.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button { editing = SkillEdit(skill: skill) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button(role: .destructive) { model.deleteSkill(skill.name) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(height: 280)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
        .sheet(item: $editing) { SkillSheet(model: model, skill: $0.skill) }
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

    private var options: [String] { model.company.skillLibrary.map { $0.name } }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !role.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(person == nil ? "New agent" : "Edit agent").font(.headline)
            TextField("Name (e.g. Ayşe Kaya)", text: $name)
            TextField("Role (e.g. Backend Developer)", text: $role)
            Picker("Team", selection: $teamID) {
                ForEach(model.company.teams) { Text($0.name).tag($0.id) }
            }
            Picker("Claude model (your subscription)", selection: $agentModel) {
                Text("Default (from Settings)").tag("")
                ForEach(ClaudeCodeProvider.knownModels, id: \.self) { Text($0).tag($0) }
            }
            Text("Claude models run through the Claude Code app signed in with your Claude subscription, not the API.").font(.caption2).foregroundStyle(.secondary)
            Text("Skills").font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.self) { skill in
                    let on = skills.contains(skill)
                    Button {
                        if on { skills.removeAll { $0 == skill } } else { skills.append(skill) }
                    } label: {
                        Text(skill).font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(on ? Color.white : Theme.green)
                            .background(Capsule().fill(on ? Theme.green : Color.clear))
                            .overlay(Capsule().stroke(Theme.green.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Tools").font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(model.engine.tools.specs, id: \.name) { spec in
                    let on = !disabledTools.contains(spec.name)
                    Button {
                        if on { disabledTools.insert(spec.name) } else { disabledTools.remove(spec.name) }
                    } label: {
                        Text(spec.name).font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(on ? Color.white : Theme.green)
                            .background(Capsule().fill(on ? Theme.green : Color.clear))
                            .overlay(Capsule().stroke(Theme.green.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(spec.description)
                }
            }
            Text("Anything that changes your Mac or an account still asks for your approval.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 460)
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

struct SkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let original: String?
    @State private var name: String
    @State private var instructions: String

    init(model: AppModel, skill: Skill?) {
        self.model = model
        original = skill?.name
        _name = State(initialValue: skill?.name ?? "")
        _instructions = State(initialValue: skill?.instructions ?? "")
    }

    private var clash: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n != original && model.company.skillLibrary.contains { $0.name == n }
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !clash }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New skill" : "Edit skill").font(.headline)
            TextField("Skill name", text: $name)
            if clash { Text("A skill with this name already exists.").font(.caption).foregroundStyle(.orange) }
            Text("Instructions the agent follows when it uses this skill").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instructions)
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.saveSkill(Skill(name: name.trimmingCharacters(in: .whitespaces), instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)), replacing: original)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 440)
    }
}
