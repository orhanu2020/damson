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
    @State private var projectToDelete: Project?
    @State private var pictures: [Data] = []
    @State private var pasteMonitor: Any?

    private var canSend: Bool { !commandText.trimmingCharacters(in: .whitespaces).isEmpty || !pictures.isEmpty }
    private var micActive: Bool { status.mode == .listening || status.mode == .thinking || status.mode == .speaking }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 18) {
                        projectsSection.frame(width: max(geo.size.width - 40, 600), alignment: .leading)
                        FloorPlanView(model: model, availableWidth: geo.size.width - 40)
                    }
                    .padding(20)
                }
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

    /// The projects: list, add and delete.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects").font(.headline)
                Text("\(model.projects.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.showNewProject = true } label: { Label("New project", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.green).controlSize(.small)
            }
            if model.projects.isEmpty {
                Text("No projects yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.projects) { project in
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(Theme.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(project.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { model.openProject = project.id }.controlSize(.small)
                    Button(role: .destructive) { projectToDelete = project } label: { Image(systemName: "trash") }
                        .controlSize(.small).disabled(model.isRunning(project.id))
                        .help(model.isRunning(project.id) ? "Stop the project first" : "Delete this project from the list")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            }
        }
        .confirmationDialog("Delete \(projectToDelete?.name ?? "this project")?", isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete from the list", role: .destructive) {
                if let p = projectToDelete { model.deleteProject(p.id) }
                projectToDelete = nil
            }
        } message: { Text("The project's files stay on disk. Its process and progress are removed.") }
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
        VStack(spacing: 0) {
            if !pictures.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(pictures.enumerated()), id: \.offset) { i, data in
                            PictureChip(data: data) { pictures.remove(at: i) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 10)
                }
                .scrollIndicators(.hidden)
            }
            inputRow
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            PastedImage.load(from: providers) { pictures += $0 }
            return true
        }
        .onAppear {
            // Cmd+V with a picture on the clipboard attaches it (a text field alone would ignore it).
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let found = PastedImage.fromPasteboard()
                if found.isEmpty { return event }
                pictures += found
                return nil
            }
        }
        .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil } }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Button { pictures += PastedImage.choose() } label: {
                Image(systemName: "paperclip").font(.system(size: 16)).foregroundStyle(Theme.green)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.card)).overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain).help("Attach a picture. You can also paste (\u{2318}V) or drop one here.")
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
        guard !text.isEmpty || !pictures.isEmpty else { return }
        if !pictures.isEmpty && model.chatPerson == nil {
            notice = "Open a chat with one person first (click them), then send the picture."
            return
        }
        let attached = pictures
        commandText = ""
        pictures = []
        run(text, images: attached)
    }

    private func run(_ text: String, images: [Data] = []) {
        notice = ""
        Task { @MainActor in
            let spoken = model.settings.voiceOutputEnabled && status.mode != .off
            let handled = await model.runCompanyCommand(text, images: images, speak: spoken)
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
