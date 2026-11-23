import SwiftUI
import DamsonCore
import DamsonVoice

/// The "Company" tab: the company, its teams and the people in each team, shown as cards.
/// Say a name (or a team) while this tab is open to select them; their agent answers.
struct CompanyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: VoiceStatus
    @State private var commandText = ""
    @State private var notice = ""

    private var canSend: Bool { !commandText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var micActive: Bool { status.mode == .listening || status.mode == .thinking || status.mode == .speaking }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                FloorPlanView(model: model)
                    .padding(20)
            }
            if let person = model.chatPerson {
                Divider()
                PersonChatPanel(model: model, person: person)
                    .frame(height: 260)
            }
            VoiceStrip(model: model, status: status)
            if !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.top, 6)
            }
            commandBar
        }
        .background(Theme.chatBackground)
        .navigationTitle("Company")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.green)
                Image(systemName: "building.2.fill").foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Company").font(.headline)
                Text("\(OfficeLayout.rooms(of: model.company).filter { !$0.members.isEmpty }.count) capabilities \u{00B7} \(model.company.allPeople.count) agents")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CompanyMenu(model: model)
            if !model.selectedPeople.isEmpty {
                Text("\(model.selectedPeople.count) selected")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.green)
                Button("Clear selection") { model.clearSelection() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card)
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            Button { model.toggleConversation() } label: {
                Image(systemName: micActive ? "mic.fill" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(micActive ? Color.white : Theme.green)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(micActive ? Theme.green : Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Talk by voice (Control+Option+D). Say a person's or a team's name.")

            TextField(model.chatPerson.map { "Message \($0.firstName)…" } ?? "Type a command for the selected people…", text: $commandText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .onSubmit { submit() }

            Button { submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.green.opacity(canSend ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() {
        let text = commandText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        commandText = ""
        run(text)
    }

    private func run(_ text: String) {
        notice = ""
        Task { @MainActor in
            let spoken = model.settings.voiceOutputEnabled && status.mode != .off
            let handled = await model.runCompanyCommand(text, speak: spoken)
            if !handled { notice = "Select a person or team first, or include a name in the command." }
        }
    }
}

struct Avatar: View {
    let person: Person
    let selected: Bool

    private static let palette: [Color] = [
        Theme.green,
        Color(red: 0.25, green: 0.40, blue: 0.62),
        Color(red: 0.62, green: 0.35, blue: 0.25),
        Color(red: 0.45, green: 0.33, blue: 0.58),
        Color(red: 0.20, green: 0.50, blue: 0.50),
        Color(red: 0.60, green: 0.48, blue: 0.18),
    ]

    private var color: Color {
        let sum = person.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            Text(person.initials)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 38, height: 38)
        .overlay(Circle().stroke(selected ? Theme.onlineGreen : Color.clear, lineWidth: 3).padding(-3))
    }
}


/// Live chat with the selected person. Typed and spoken messages both land here.
struct PersonChatPanel: View {
    @ObservedObject var model: AppModel
    let person: Person

    @ObservedObject private var status: VoiceStatus
    private var micOn: Bool { status.mode == .listening || status.mode == .thinking || status.mode == .speaking }
    private var messages: [ChatMessage] { model.personChats[person.id] ?? [] }

    init(model: AppModel, person: Person) {
        self.model = model
        self.person = person
        self.status = model.voiceStatus
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(person: person, selected: true).scaleEffect(0.8).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name).font(.subheadline.weight(.semibold))
                    Text(person.role).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.toggleConversation() } label: {
                    Label(micOn ? "Listening" : "Talk", systemImage: micOn ? "waveform" : "mic.fill")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Talk to \(person.firstName)")
                if model.personResponding.contains(person.id) {
                    ProgressView().controlSize(.small)
                }
                Button { model.clearPersonChat(person) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear chat")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.card)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if messages.isEmpty {
                            Text("Type to \(person.firstName), or press the microphone and talk.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                        }
                        ForEach(messages) { MessageRow(message: $0).id($0.id) }
                    }
                    .padding(14)
                }
                .onChange(of: messages.last?.text) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
