import SwiftUI
import Combine
import AppKit
import UserNotifications
import DamsonSupport
import DamsonProviders
import DamsonStore
import DamsonTools
import DamsonCore
import DamsonVoice

public struct ChatMessage: Identifiable, Equatable {
    public enum Kind { case user, assistant, system, tool }
    public let id = UUID()
    public var kind: Kind
    public var text: String
    public var date = Date()
    public var viaVoice = false
    /// True while the user is still speaking and the text is a live, unfinished transcript.
    public var isLive = false
}

/// The app's single source of truth for the UI. Owns the engine and the voice controller,
/// so everything keeps running when the window is closed.
@MainActor
public final class AppModel: ObservableObject {
    public let engine: DamsonEngine
    public let voice: VoiceController
    public let voiceStatus: VoiceStatus

    // Company view
    @Published public var company: Company = Company.load() ?? .sample {
        didSet { company.save() }
    }
    /// The user's Claude skills (~/.claude/skills), read-only.
    @Published public var skills: [SkillInfo] = []
    @Published public var selectedPeople: Set<String> = []
    @Published public var personStatus: [String: PersonStatus] = [:]
    /// Direct chats with people, by person id.
    // Projects (the delivery process)
    @Published var projects: [Project] = ProjectStore.load() { didSet { ProjectStore.save(projects) } }
    @Published var projectLog: [String: [String]] = [:]
    var projectTasks: [String: Task<Void, Never>] = [:]
    @Published var companySheet: CompanySheet?
    @Published var teamToDelete: Team?
    @Published public var personChats: [String: [ChatMessage]] = [:]
    @Published public var personResponding: Set<String> = []
    /// True while the Company tab is open: spoken commands naming a person or team go there instead of the chat.
    public var companyViewActive = false
    let teamAgent: TeamAgent = LangGraphTeamAgent()
    @Published public var approvals: [ApprovalRequest] = []
    @Published public var settings: DamsonSettings {
        didSet { settingsChanged() }
    }
    @Published public var notice: String = ""
    @Published public var mcpLog: [String] = []
    @Published public var ollamaModels: [String] = []
    @Published public var localPresetMessage: String = ""

    /// True when at least one role is routed to Claude (your Claude subscription through Claude Code).
    public var usesClaude: Bool {
        return settings.routing.usesProviders.contains(ClaudeCodeProvider.providerID)
    }

    private let hotKey = GlobalHotKey(id: 1)          // Control+Option+Space: hold to talk
    private let conversationKey = GlobalHotKey(id: 2) // Control+Option+D: start/stop hands-free conversation
    private var started = false
    private var cancellables = Set<AnyCancellable>()


    public init() {
        let loaded = DamsonSettings.load()
        self.settings = loaded

        var startupNotice = ""
        let store: DamsonStore
        do {
            store = try DamsonStore()
        } catch {
            startupNotice = "Could not open the database (\(error.localizedDescription)). Using temporary storage."
            // An in-memory database cannot fail to open in practice.
            store = (try? DamsonStore.inMemory()) ?? (try! DamsonStore(path: ":memory:"))
        }

        self.engine = DamsonEngine(store: store, settings: loaded)
        let status = VoiceStatus()
        self.voiceStatus = status
        self.voice = VoiceController(status: status)
        self.notice = startupNotice

        reloadSkills()
        // Drop assigned skills that do not exist among the user's Claude skills (e.g. from older versions).
        if !skills.isEmpty {
            let known = Set(skills.map { $0.name })
            for t in company.teams.indices { for m in company.teams[t].members.indices {
                company.teams[t].members[m].skills.removeAll { !known.contains($0) }
            } }
        }

        Task { await self.start() }
    }

    // MARK: Startup

    private func start() async {
        guard !started else { return }
        started = true

        let stream = engine.bus.subscribe()
        Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }

        voice.onUtterance = { [weak self] text in
            await self?.handleVoiceUtterance(text)
        }
        applyVoiceConfig()

        hotKey.onPress = { [weak self] in
            Task { @MainActor in self?.hotKeyPressed() }
        }
        hotKey.onRelease = { [weak self] in
            Task { @MainActor in self?.voice.pushToTalkUp() }
        }
        hotKey.register()
        conversationKey.onPress = { [weak self] in
            Task { @MainActor in self?.conversationKeyPressed() }
        }
        conversationKey.registerConversationShortcut()

        requestNotificationPermission()
        refreshOllamaModels()

        if settings.listeningAtLaunch { voice.startListening() }
        mcpLog = await engine.loadMCP()
    }

    // MARK: Settings

    private func settingsChanged() {
        settings.save()
        engine.updateSettings(settings)
        applyVoiceConfig()
    }

    private func applyVoiceConfig() {
        var c = VoiceConfig()
        c.idleTimeout = settings.idleTimeoutSeconds
        c.bargeIn = settings.bargeInEnabled
        c.locale = settings.speechLocale
        c.voiceIdentifier = settings.voiceIdentifier
        c.speechRate = settings.speechRate
        c.endSilence = settings.endSilenceSeconds
        c.voiceOutput = settings.voiceOutputEnabled
        c.allowServerRecognition = settings.allowServerSpeechRecognition
        c.echoCancellation = settings.echoCancellation
        c.microphoneUID = settings.microphoneUID
        DebugLog.setPath(settings.debugLogPath)
        voice.updateConfig(c)
    }

    /// One click: route chat to local Ollama models (no Claude API key needed).
    public func useLocalModelsOnly() {
        let installed = ollamaModels
        guard !installed.isEmpty else {
            localPresetMessage = "No local models found. Start Ollama and pull a model first, then press Refresh local models."
            return
        }
        let assistant = installed.first(where: { $0 == "qwen3.6:35b-a3b" })
            ?? installed.first(where: { $0.contains("35b-a3b") })
            ?? installed.first(where: { $0.hasPrefix("qwen3") && !$0.contains("coder") })
            ?? installed[0]
        settings.routing = RoutingTable.allLocal(assistant: assistant)
        localPresetMessage = "Chat now uses the local model \(assistant)."
    }

    public func refreshOllamaModels() {
        let url = URL(string: settings.ollamaURL) ?? URL(string: "http://localhost:11434")!
        Task {
            let names = await OllamaProvider.installedModels(baseURL: url)
            await MainActor.run { self.ollamaModels = names }
        }
    }

    public func reloadMCP() {
        Task {
            let log = await engine.loadMCP()
            await MainActor.run { self.mcpLog = log }
        }
    }

    // MARK: Voice input

    private func handleVoiceUtterance(_ text: String) async {
        DebugLog.write("utterance sent to Damson: '\(text)'")
        _ = await runCompanyCommand(text, speak: true, viaVoice: true)
    }

    // MARK: Voice

    /// "Start listening" opens a hands-free conversation right away.
    public func toggleListening() {
        if voiceStatus.mode == .off {
            voice.beginConversation()
        } else {
            voice.stopListening()
        }
    }

    public func startConversation() {
        voice.beginConversation()
    }

    /// Microphone button in the chat: start a hands-free conversation, or end the current one.
    public func toggleConversation() { conversationKeyPressed() }

    /// Control+Option+D: start or stop listening, press again to end the conversation.
    private func conversationKeyPressed() {
        switch voiceStatus.mode {
        case .off:
            voice.beginConversation()
        case .listening, .thinking, .speaking:
            voice.endConversation()
        }
    }

    private func hotKeyPressed() {
        if voiceStatus.mode == .off {
            voice.beginConversation()
        } else {
            voice.pushToTalkDown()
        }
    }

    // MARK: Approvals

    public func resolve(_ request: ApprovalRequest, _ decision: ApprovalDecision) {
        engine.resolveApproval(id: request.id, decision: decision)
    }

    // MARK: Events

    private func handle(_ event: DamsonEvent) {
        switch event {
        case .approvalRequested(let a):
            approvals.append(a)
            alert(sound: settings.soundOnNeedsInput, name: "Ping",
                  speak: settings.speakNeedsInput,
                  text: "I need your approval. \(a.summary). Say approve, or deny.")
            postSystemNotification(title: "Damson needs approval", body: a.summary)

        case .approvalResolved(let a, _):
            approvals.removeAll { $0.id == a.id }

        case .log:
            break
        }
    }

    private func alert(sound: Bool, name: String, speak: Bool, text: String) {
        if settings.soundsEnabled && sound {
            NSSound(named: NSSound.Name(name))?.play()
        }
        if speak && settings.voiceOutputEnabled {
            voice.announce(text)
        }
    }

    // MARK: System notifications (only when running as a proper .app bundle)

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func postSystemNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: Browser sandbox

    public func showSandboxBrowser() {
        SandboxBrowser.shared.showWindow()
    }

    public func clearBrowserData() {
        Task { await SandboxBrowser.shared.clearData() }
    }

    // MARK: Menu bar

    public var menuIcon: String {
        switch voiceStatus.mode {
        case .off: return "mic.slash"
        case .listening: return "waveform"
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2"
        }
    }

    public var menuBadge: String {
        let waiting = approvals.count
        return waiting > 0 ? "\(waiting) approval\(waiting == 1 ? "" : "s") waiting" : ""
    }

    public func shutdown() {
        voice.stopListening()
        engine.mcp.shutdown()
        hotKey.unregister()
        conversationKey.unregister()
    }
}
