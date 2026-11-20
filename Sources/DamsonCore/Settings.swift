import Foundation
import DamsonProviders
import DamsonTools

public enum Verbosity: String, Codable, CaseIterable, Sendable {
    case brief
    case normal
    case detailed

    public var title: String { rawValue.capitalized }
}

public enum AssistantStyle: String, Codable, CaseIterable, Sendable {
    case formal
    case friendly

    public var title: String { rawValue.capitalized }
}

/// All user-adjustable settings. Decoding is lenient so new fields never wipe old settings.
public struct DamsonSettings: Codable, Equatable, Sendable {
    public var routing: RoutingTable = .claudeDefault
    public var verbosity: Verbosity = .brief
    public var style: AssistantStyle = .formal

    // Notifications
    public var soundsEnabled: Bool = true
    public var soundOnNeedsInput: Bool = true
    public var speakNeedsInput: Bool = true

    // Voice
    public var voiceOutputEnabled: Bool = true
    public var listeningAtLaunch: Bool = false
    public var idleTimeoutSeconds: Double = 20
    public var bargeInEnabled: Bool = true
    public var speechLocale: String = "en-US"
    public var voiceIdentifier: String = ""
    public var speechRate: Double = 0.5
    public var endSilenceSeconds: Double = 0.8
    public var allowServerSpeechRecognition: Bool = false
    public var debugLogPath: String = ""
    public var echoCancellation: Bool = true
    public var microphoneUID: String = ""

    // Trust and workspace
    public var trustLevel: TrustLevel = .ask
    public var workspacePath: String = "~/Projects"

    // Helpers

    // Providers
    public var ollamaURL: String = "http://localhost:11434"

    public init() {}

    /// The workspace folder as a URL, or nil when none is set.
    public var workspaceURL: URL? {
        let trimmed = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }

    enum CodingKeys: String, CodingKey {
        case routing, verbosity, style
        case soundsEnabled, soundOnNeedsInput, speakNeedsInput
        case voiceOutputEnabled, listeningAtLaunch, idleTimeoutSeconds, bargeInEnabled, speechLocale, voiceIdentifier, speechRate, endSilenceSeconds
        case allowServerSpeechRecognition, debugLogPath, echoCancellation, microphoneUID
        case ollamaURL, trustLevel, workspacePath
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(RoutingTable.self, forKey: .routing) { routing = v }
        if let v = try c.decodeIfPresent(Verbosity.self, forKey: .verbosity) { verbosity = v }
        if let v = try c.decodeIfPresent(AssistantStyle.self, forKey: .style) { style = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) { soundsEnabled = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .soundOnNeedsInput) { soundOnNeedsInput = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .speakNeedsInput) { speakNeedsInput = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .voiceOutputEnabled) { voiceOutputEnabled = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .listeningAtLaunch) { listeningAtLaunch = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .idleTimeoutSeconds) { idleTimeoutSeconds = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) { bargeInEnabled = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .speechLocale) { speechLocale = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier) { voiceIdentifier = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .speechRate) { speechRate = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .endSilenceSeconds) { endSilenceSeconds = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .allowServerSpeechRecognition) { allowServerSpeechRecognition = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .debugLogPath) { debugLogPath = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) { echoCancellation = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .microphoneUID) { microphoneUID = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .ollamaURL) { ollamaURL = v }
        if let v = try c.decodeIfPresent(TrustLevel.self, forKey: .trustLevel) { trustLevel = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .workspacePath) { workspacePath = v }
    }

    // MARK: Persistence in UserDefaults

    private static let defaultsKey = "app.damson.settings.v1"

    public static func load() -> DamsonSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(DamsonSettings.self, from: data) else {
            return DamsonSettings()
        }
        return settings
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
