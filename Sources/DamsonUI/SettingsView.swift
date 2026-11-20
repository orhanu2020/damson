import SwiftUI
import AppKit
import DamsonProviders
import DamsonTools
import DamsonCore
import DamsonVoice

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var micDevices: [AudioDevices.Input] = []

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as workspace"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.workspacePath = url.path
        }
    }

    private func providerBinding(_ role: AgentRole) -> Binding<String> {
        Binding(
            get: { model.settings.routing.route(for: role).provider },
            set: { newValue in
                var route = model.settings.routing.route(for: role)
                route.provider = newValue
                if newValue == "ollama" && route.model.hasPrefix("claude") {
                    route.model = model.ollamaModels.first ?? ""
                }
                if newValue == ClaudeCodeProvider.providerID && !route.model.hasPrefix("claude") {
                    route.model = "claude-sonnet-5-5"
                }
                // Voice-speed roles should not "think out loud" by default on local models.
                if newValue == "ollama" {
                    route.thinking = role == .conversation ? false : nil
                } else {
                    route.thinking = nil
                }
                model.settings.routing.set(role, route)
            }
        )
    }

    private func modelBinding(_ role: AgentRole) -> Binding<String> {
        Binding(
            get: { model.settings.routing.route(for: role).model },
            set: { newValue in
                var route = model.settings.routing.route(for: role)
                route.model = newValue
                model.settings.routing.set(role, route)
            }
        )
    }

    private func thinkingBinding(_ role: AgentRole) -> Binding<Bool> {
        Binding(
            get: { model.settings.routing.route(for: role).thinking ?? true },
            set: { newValue in
                var route = model.settings.routing.route(for: role)
                route.thinking = newValue
                model.settings.routing.set(role, route)
            }
        )
    }

    private func modelChoices(_ role: AgentRole) -> [String] {
        let provider = model.settings.routing.route(for: role).provider
        return provider == "ollama" ? model.ollamaModels : ClaudeCodeProvider.knownModels
    }

    private var voices: [(id: String, name: String, language: String)] {
        let prefix = String(model.settings.speechLocale.prefix(2))
        return SystemSpeechSynthesizer.availableVoices().filter { $0.language.hasPrefix(prefix) }
    }

    var body: some View {
        Form {
            Section("Models by role") {
                HStack {
                    Button("Use local models only") { model.useLocalModelsOnly() }
                    Button("Use Claude defaults") { model.settings.routing = .claudeDefault }
                }
                Text("Claude models run through the Claude Code app signed in with your Claude subscription. No API key is used.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.localPresetMessage.isEmpty {
                    Text(model.localPresetMessage).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(AgentRole.allCases, id: \.self) { role in
                    HStack {
                        Text(role.displayName).frame(width: 190, alignment: .leading)
                        Picker("", selection: providerBinding(role)) {
                            Text("Claude (subscription)").tag(ClaudeCodeProvider.providerID)
                            Text("Ollama (local)").tag("ollama")
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        ComboBoxField(text: modelBinding(role), items: modelChoices(role), placeholder: "model id")
                            .frame(minWidth: 220)
                        if model.settings.routing.route(for: role).provider == "ollama" {
                            Toggle("Think", isOn: thinkingBinding(role))
                                .toggleStyle(.checkbox)
                                .help("Let the local model reason step by step before answering. Better for hard problems, slower for conversation.")
                        }
                    }
                }
                TextField("Ollama address", text: $model.settings.ollamaURL)
                HStack {
                    Button("Refresh local models") { model.refreshOllamaModels() }
                    Text(model.ollamaModels.isEmpty ? "No local models found (is Ollama running?)" : "\(model.ollamaModels.count) local model(s) found")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Voice") {
                HStack {
                    Picker("Microphone", selection: $model.settings.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(micDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    Button("Refresh") { micDevices = AudioDevices.inputs() }
                }
                Text("Takes effect when listening restarts (Stop listening, then Start listening). Bluetooth headsets often have no microphone while they are in headphone mode.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start listening when Damson starts", isOn: $model.settings.listeningAtLaunch)
                Toggle("Speak replies aloud", isOn: $model.settings.voiceOutputEnabled)
                Toggle("Let me interrupt Damson while it is speaking (use headphones if it interrupts itself)", isOn: $model.settings.bargeInEnabled)
                Toggle("Echo cancellation (turn off if the microphone hears nothing; takes effect when listening restarts)", isOn: $model.settings.echoCancellation)
                HStack {
                    Text("Pause that ends my turn")
                    Slider(value: $model.settings.endSilenceSeconds, in: 0.4...2.0, step: 0.1)
                    Text(String(format: "%.1f s", model.settings.endSilenceSeconds)).frame(width: 50)
                }
                HStack {
                    Text("Speaking speed")
                    Slider(value: $model.settings.speechRate, in: 0.3...0.65)
                }
                Picker("Voice", selection: $model.settings.voiceIdentifier) {
                    Text("Automatic (best available)").tag("")
                    ForEach(voices, id: \.id) { v in
                        Text("\(v.name) (\(v.language))").tag(v.id)
                    }
                }
                TextField("Speech language (e.g. en-US, tr-TR)", text: $model.settings.speechLocale)
                Toggle("Allow Apple's server speech recognition if on-device isn't available (audio is sent to Apple)", isOn: $model.settings.allowServerSpeechRecognition)
                HStack {
                    Button("Turn on diagnostics (save to ~/Projects/Damson/voice.log)") {
                        model.settings.debugLogPath = "~/Projects/Damson/voice.log"
                    }
                    if !model.settings.debugLogPath.isEmpty {
                        Button("Turn off") { model.settings.debugLogPath = "" }
                    }
                }
                TextField("Diagnostics file (optional)", text: $model.settings.debugLogPath)
                Text("If set, Damson writes what the microphone and speech recognizer are doing to this file (no API keys). Leave empty to turn off.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Press Start listening and just talk; it listens until you press Stop listening. Push to talk: hold Control + Option + Space.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Personality") {
                Picker("Style", selection: $model.settings.style) {
                    ForEach(AssistantStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Answer detail", selection: $model.settings.verbosity) {
                    ForEach(Verbosity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("Notifications") {
                Toggle("Sounds", isOn: $model.settings.soundsEnabled)
                Group {
                    Toggle("Chime when Damson needs your input or approval", isOn: $model.settings.soundOnNeedsInput)
                }
                .disabled(!model.settings.soundsEnabled)
                Toggle("Speak when approval or input is needed", isOn: $model.settings.speakNeedsInput)
            }

            Section("Workspace and trust") {
                HStack {
                    TextField("Workspace folder", text: $model.settings.workspacePath, prompt: Text("~/Projects"))
                    Button("Choose...") { chooseWorkspace() }
                }
                Text("Helpers start here: shell commands run in this folder and relative paths resolve here. For anything elsewhere they use full paths.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Trust", selection: $model.settings.trustLevel) {
                    ForEach(TrustLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                Text(model.settings.trustLevel.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.trustLevel == .full {
                    Text("Full trust is on: helpers can open apps and run most commands without asking. Only you can change this setting.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("To watch Damson work, ask it to do the job in Terminal. The first time, macOS asks whether Damson may control Terminal: choose OK.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sandboxed browser") {
                HStack {
                    Button("Show sandbox browser") { model.showSandboxBrowser() }
                    Button("Clear its data", role: .destructive) { model.clearBrowserData() }
                }
                Text("Helpers browse in a separate profile with none of your own logins. Sign in to a site inside this window if a task needs it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MCP tools") {
                Button("Reload MCP servers") { model.reloadMCP() }
                Text("Config file: ~/Library/Application Support/Damson/mcp.json")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.mcpLog, id: \.self) { line in
                    Text(line).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshOllamaModels()
            micDevices = AudioDevices.inputs()
        }
        .navigationTitle("Settings")
    }
}
