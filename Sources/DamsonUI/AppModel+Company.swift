import SwiftUI
import DamsonSupport
import DamsonCore

/// What a person in the company view is doing right now.
public enum PersonStatus: Equatable {
    case working
    case replied(String)
}

extension AppModel {
    func toggleSelection(_ personID: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedPeople.contains(personID) {
                selectedPeople.remove(personID)
            } else {
                selectedPeople.insert(personID)
            }
        }
    }

    func setTeamSelected(_ team: Team, _ selected: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            for member in team.members {
                if selected { selectedPeople.insert(member.id) } else { selectedPeople.remove(member.id) }
            }
        }
    }

    func clearSelection() {
        withAnimation(.easeInOut(duration: 0.15)) { selectedPeople.removeAll() }
    }

    // MARK: Editing the company

    private func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    func addTeam(name: String) {
        guard company.teams.count < Company.maxTeams else { return }
        company.teams.append(Team(id: newID(), name: name, members: []))
    }

    func reloadSkills() { skills = SkillStore.list() }

    func addPerson(_ person: Person, to teamID: String) {
        guard let i = company.teams.firstIndex(where: { $0.id == teamID }),
              company.teams[i].members.count < Company.maxMembers else { return }
        company.teams[i].members.append(person)
    }

    /// Saves changes to a person and moves them to `teamID` if that differs.
    func updatePerson(_ person: Person, team teamID: String) {
        guard let from = company.teams.firstIndex(where: { $0.members.contains { $0.id == person.id } }),
              let to = company.teams.firstIndex(where: { $0.id == teamID }) else { return }
        if from == to {
            if let j = company.teams[from].members.firstIndex(where: { $0.id == person.id }) { company.teams[from].members[j] = person }
        } else if company.teams[to].members.count < Company.maxMembers {
            company.teams[from].members.removeAll { $0.id == person.id }
            company.teams[to].members.append(person)
        }
    }

    func deletePerson(_ id: String) {
        guard let person = company.allPeople.first(where: { $0.id == id }) else { return }
        forget(person)
        for i in company.teams.indices { company.teams[i].members.removeAll { $0.id == id } }
    }

    private func forget(_ person: Person) {
        selectedPeople.remove(person.id)
        personStatus[person.id] = nil
        clearPersonChat(person)
    }

    /// The one person whose chat is open: exactly one card selected.
    var chatPerson: Person? {
        guard selectedPeople.count == 1, let id = selectedPeople.first else { return nil }
        return company.allPeople.first { $0.id == id }
    }

    private static func wantsSelection(_ text: String) -> Bool {
        let tokens = CompanyCommandParser.fold(text).split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains { $0.hasPrefix("sec") || $0 == "select" }
    }

    /// Sends one message to a person and streams their reply (and any tool use) into their chat.
    func chat(with person: Person, text: String, images: [Data] = [], speak: Bool, viaVoice: Bool) async {
        let id = person.id
        var sent = ChatMessage(kind: .user, text: text, viaVoice: viaVoice)
        sent.images = images
        personChats[id, default: []].append(sent)
        personResponding.insert(id)
        personStatus[id] = .working
        let currentReply = Locked<UUID?>(nil)   // the assistant bubble currently being filled
        let voice = self.voice

        _ = await engine.chat(with: person, company: company, text: text, images: images, onSentence: { [weak self] sentence in
            Task { @MainActor in
                guard let self else { return }
                var list = self.personChats[id] ?? []
                if let rid = currentReply.current, let i = list.firstIndex(where: { $0.id == rid }) {
                    list[i].text += (list[i].text.isEmpty ? "" : " ") + sentence
                } else {
                    let m = ChatMessage(kind: .assistant, text: sentence, viaVoice: viaVoice)
                    currentReply.withLock { $0 = m.id }
                    list.append(m)
                }
                self.personChats[id] = list
            }
            if speak { voice.speak(sentence) }
        }, onTool: { [weak self] summary in
            currentReply.withLock { $0 = nil }
            Task { @MainActor in self?.personChats[id, default: []].append(ChatMessage(kind: .tool, text: summary)) }
        })
        personResponding.remove(id)
        personStatus[id] = nil
    }

    func clearPersonChat(_ person: Person) {
        personChats[person.id] = nil
        Task { await engine.clearPersonChat(person) }
    }

    /// Picks the people (or teams) named in the command and lets their agents answer.
    /// With one person open, everything goes to them as a chat. Returns false when nobody is addressed.
    func runCompanyCommand(_ text: String, images: [Data] = [], speak: Bool, viaVoice: Bool = false) async -> Bool {
        // A waiting tool approval is answered by the user's own words, never by a model.
        if engine.resolveApprovalByWords(text) != nil { return true }
        // Chat open: words go to that person, unless the user asks to select someone else.
        if let open = chatPerson, !Self.wantsSelection(text) {
            await chat(with: open, text: text, images: images, speak: speak, viaVoice: viaVoice)
            return true
        }
        let command: CompanyCommand
        if let named = CompanyCommandParser.parse(text, company: company) {
            command = named
        } else if !selectedPeople.isEmpty {
            command = CompanyCommand(people: company.allPeople.filter { selectedPeople.contains($0.id) }, teams: [], text: text)
        } else {
            return false
        }
        // Just picking someone ("Select Ayşe") opens their chat without sending anything.
        if Self.wantsSelection(text) {
            withAnimation(.easeInOut(duration: 0.15)) { selectedPeople = Set(command.people.map { $0.id }) }
            if speak, command.people.count == 1 { voice.speak("Yes?") }
            return true
        }
        // A single person addressed by name starts a chat with them.
        if command.people.count == 1, let only = command.people.first {
            withAnimation(.easeInOut(duration: 0.15)) { selectedPeople = [only.id] }
            await chat(with: only, text: text, images: images, speak: speak, viaVoice: viaVoice)
            return true
        }
        DebugLog.write("company command: '\(text)' -> \(command.people.map { $0.name })")

        withAnimation(.easeInOut(duration: 0.15)) {
            selectedPeople = Set(command.people.map { $0.id })
            for person in command.people { personStatus[person.id] = .working }
        }

        let agent = teamAgent
        let replies: [(String, String)] = await withTaskGroup(of: (String, String).self) { group in
            for person in command.people {
                group.addTask { (person.id, await agent.handle(command: text, for: person)) }
            }
            var collected: [(String, String)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            for (id, reply) in replies { personStatus[id] = .replied(reply) }
        }
        if speak, let first = replies.first?.1 { voice.speak(first) }

        // The speech bubbles fade after a few seconds.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            for (id, _) in replies {
                if case .replied? = personStatus[id] { personStatus[id] = nil }
            }
        }
        return true
    }
}
