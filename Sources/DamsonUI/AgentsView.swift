import SwiftUI
import DamsonCore

/// All agents in one list, with their settings next to it: add, edit, move to another team, remove.
struct AgentsView: View {
    @ObservedObject var model: AppModel
    /// An agent id, "new", or nil.
    @State private var selection: String?
    @State private var newTeamID = ""
    @State private var revision = 0
    @State private var toDelete: Person?

    private var people: [Person] { model.company.allPeople }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agents").font(.title2.weight(.semibold))
                Text("\(people.count) in the pool").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.setupDeliveryTeams() } label: { Label("Add standard agents", systemImage: "person.crop.circle.badge.checkmark") }
                    .controlSize(.small).help("Adds the standard agents for the delivery process that are missing")
                Button { startNew() } label: { Label("Add agent", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.green)
            }
            HStack(alignment: .top, spacing: 12) {
                list.frame(width: 280)
                detail
            }
        }
        .padding(16)
        .confirmationDialog("Delete \(toDelete?.name ?? "this agent")?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("Delete agent", role: .destructive) {
                if let p = toDelete { model.deletePerson(p.id); if selection == p.id { selection = nil } }
                toDelete = nil
            }
        } message: { Text("Their chat history is removed too. This cannot be undone.") }
    }

    private func startNew() {
        newTeamID = model.homeTeamID() ?? model.company.teams.first?.id ?? ""
        revision += 1
        selection = "new"
    }

    /// Agents grouped by capability: the standard ones first, then others.
    private var groups: [(capability: String, people: [Person])] {
        var map: [String: [Person]] = [:]
        for p in people { map[ProjectFlow.capability(of: p, in: model.company), default: []].append(p) }
        let order = ProjectFlow.capabilities + map.keys.filter { !ProjectFlow.capabilities.contains($0) }.sorted()
        return order.compactMap { c in map[c].map { (c, $0) } }
    }

    private func usageText(_ id: String) -> String {
        let n = model.usage(of: id).count
        return n == 0 ? "not used" : n == 1 ? "1 project" : "\(n) projects"
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.capability) { group in
                Section {
                    ForEach(group.people) { person in
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.olive).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.name).lineLimit(1)
                                Text(person.role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(usageText(person.id)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .tag(person.id)
                    }
                } header: {
                    Text("\(group.capability) \u{00B7} \(group.people.count)").font(.caption.weight(.semibold))
                }
            }
        }
        .listStyle(.inset)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: selection) { _, new in if new != "new" { revision += 1 } }
    }

    /// Where the agent works: each project with its steps.
    private func usageBlock(_ person: Person) -> some View {
        let used = model.usage(of: person.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Used in \(used.count) project\(used.count == 1 ? "" : "s")").font(.subheadline.weight(.semibold))
            if used.isEmpty {
                Text("Not doing any step yet. Add this agent to a step in a project's Process tab.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(used, id: \.project.id) { u in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(Theme.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.project.name).font(.caption.weight(.semibold))
                        Text(u.steps.map { $0.title }.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var detail: some View {
        Group {
            if selection == "new" {
                panel(title: "New agent", person: nil) {
                    AgentForm(model: model, person: nil, teamID: newTeamID, onSaved: { selection = $0 }, onCancel: { selection = nil })
                }
            } else if let id = selection, let person = people.first(where: { $0.id == id }),
                      let team = model.company.teams.first(where: { $0.members.contains { $0.id == id } }) {
                panel(title: person.name, person: person) {
                    VStack(alignment: .leading, spacing: 14) {
                        usageBlock(person)
                        AgentForm(model: model, person: person, teamID: team.id, onSaved: { _ in }, onCancel: { revision += 1 })
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.crop.square.stack").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Pick an agent to see and change its settings, or add a new one.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func panel<Content: View>(title: String, person: Person?, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.title3.weight(.semibold))
                    Spacer()
                    if let person {
                        Button { model.clearPersonChat(person) } label: { Label("Clear chat", systemImage: "eraser") }.controlSize(.small)
                        Button(role: .destructive) { toDelete = person } label: { Label("Delete", systemImage: "trash") }.controlSize(.small)
                    }
                }
                content().id("\(selection ?? "")-\(revision)")
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }
}
