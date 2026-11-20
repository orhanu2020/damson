import Foundation
import AVFoundation
import AudioToolbox
import Combine
import DamsonSupport

public enum VoiceMode: String, Sendable {
    case off          // nothing listens
    case listening    // conversation: open mic
    case thinking     // waiting for Damson's reply
    case speaking     // Damson is talking

    public var label: String {
        switch self {
        case .off: return "Not listening"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }
}

public struct VoiceConfig: Sendable, Equatable {
    public var idleTimeout: Double = 20
    public var bargeIn: Bool = true
    public var locale: String = "en-US"
    public var voiceIdentifier: String = ""
    public var speechRate: Double = 0.5
    public var endSilence: Double = 0.8
    public var voiceOutput: Bool = true
    public var allowServerRecognition: Bool = false
    public var echoCancellation: Bool = true
    /// UID of the microphone to use; empty = the system default input.
    public var microphoneUID: String = ""

    public init() {}
}

/// UI-facing state, updated on the main thread.
@MainActor
public final class VoiceStatus: ObservableObject {
    @Published public var mode: VoiceMode = .off
    @Published public var partialTranscript: String = ""
    @Published public var message: String = ""
    /// 0...1 microphone level, for the meter in the chat window.
    @Published public var inputLevel: Double = 0
    /// The same level in decibels (about -20 is loud speech, -60 is a quiet room, -120 is digital silence).
    @Published public var inputLevelDB: Double = -120
    /// Name of the microphone Damson is using (empty if none was found).
    @Published public var inputDevice: String = ""

    public init() {}
}

/// The conversation state machine: open conversation -> turn-taking -> spoken replies,
/// with barge-in. All logic runs on one serial queue; the UI observes `status`.
public final class VoiceController: @unchecked Sendable {
    public let status: VoiceStatus

    /// Called with each final user utterance. The app runs the model and calls `speak` per sentence.
    public var onUtterance: (@Sendable (String) async -> Void)?
    /// Called when the user interrupts Damson (cancel the in-flight reply).
    public var onInterrupt: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "app.damson.voice")
    private var engine = AVAudioEngine()
    private var engineRunning = false
    private var mode: VoiceMode = .off
    private var config = VoiceConfig()

    private let stt = AppleSpeechTurnRecognizer()
    private let tts = SystemSpeechSynthesizer()

    private var turn = TurnDetector()
    private var bargeTurn = TurnDetector(startMarginDB: 18, minSpeechSeconds: 0.3, endSilenceSeconds: 0.5, absoluteFloorDB: -38)
    private var ring: [AVAudioPCMBuffer] = []
    private var ringSeconds = 0.0

    private var pttActive = false
    private var turnGeneration = 0
    private var responseFinished = true
    private var idleGeneration = 0
    private var announcements: [String] = []
    private var configObserver: NSObjectProtocol?
    private var recentRestarts: [Date] = []
    // Barge-in (interrupting Damson): compares the microphone to its level during Damson's own speech.
    private var bargeBaselineDB: Float = -70
    private var bargeWarmup = 0.0
    private var bargeSeconds = 0.0
    private var useVoiceProcessing = true
    private var maxLevelSeen: Float = -120
    private var silenceCheckGeneration = 0
    private var lastLevelPublish = Date.distantPast
    private var lastLevelLog = Date.distantPast

    public init(status: VoiceStatus) {
        self.status = status
        tts.onDrained = { [weak self] in
            self?.queue.async { self?.speechDrained() }
        }
    }

    // MARK: Public API (thread-safe)

    public func updateConfig(_ new: VoiceConfig) {
        queue.async {
            self.config = new
            self.turn.endSilenceSeconds = new.endSilence
            self.tts.voiceIdentifier = new.voiceIdentifier
            self.tts.rate = Float(new.speechRate)
            self.tts.languageCode = new.locale
            self.stt.allowServerRecognition = new.allowServerRecognition
            if !self.engineRunning { self.useVoiceProcessing = new.echoCancellation }
        }
    }

    public func startListening() {
        AppleSpeechTurnRecognizer.requestPermissions { [weak self] granted in
            self?.queue.async {
                guard let self = self else { return }
                DebugLog.write("microphone + speech permissions granted: \(granted)")
                guard granted else {
                    self.publish(message: "Microphone or speech recognition permission was not granted. Enable both in System Settings > Privacy & Security.")
                    return
                }
                let chosenName = self.config.microphoneUID.isEmpty ? nil : AudioDevices.name(forUID: self.config.microphoneUID)
                let deviceName = chosenName ?? AVCaptureDevice.default(for: .audio)?.localizedName
                DebugLog.write("default input device: \(deviceName ?? "none")")
                self.publish(device: deviceName ?? "")
                if deviceName == nil {
                    self.publish(message: "No microphone found. A Mac mini has no built-in microphone: connect a USB or Bluetooth microphone or headset, or choose an input in System Settings > Sound > Input.")
                }
                self.startEngine()
                self.publish(message: "")
                // Listening opens the conversation right away and stays on until stopped.
                self.enterConversation(greeting: nil)
            }
        }
    }

    public func stopListening() {
        queue.async {
            self.cancelResponse()
            self.stt.cancel()
            self.tts.stop()
            self.idleGeneration += 1
            self.silenceCheckGeneration += 1
            self.stopEngine()
            self.setMode(.off)
        }
    }

    /// Starts listening and opens the conversation (button, menu item or hotkey).
    public func beginConversation(greeting: String? = nil) {
        queue.async {
            if self.mode == .off {
                self.startListening()
            } else {
                self.enterConversation(greeting: greeting)
            }
        }
    }

    public func endConversation() {
        queue.async { self.leaveConversation(farewell: nil) }
    }

    public func pushToTalkDown() {
        queue.async {
            if self.mode == .off { return }
            self.pttActive = true
            self.interruptSpeech()
            self.setMode(.listening)
            self.startSTTTurn(prefix: [])
        }
    }

    public func pushToTalkUp() {
        queue.async {
            guard self.pttActive else { return }
            self.pttActive = false
            self.endUserTurn()
        }
    }

    /// Speak a sentence of Damson's reply (called per sentence as the model streams).
    public func speak(_ text: String) {
        queue.async {
            guard self.config.voiceOutput else { return }
            if !self.tts.isBusy { self.resetBargeDetector() }
            if self.mode == .thinking { self.setMode(.speaking) }
            self.tts.enqueue(text)
        }
    }

    /// The reply for the current utterance has been fully delivered (all sentences queued).
    public func replyFinished() {
        queue.async {
            self.responseFinished = true
            if !self.tts.isBusy { self.speechDrained() }
        }
    }

    /// A notification (task finished, approval needed...). Spoken at the next natural pause.
    public func announce(_ text: String) {
        queue.async {
            guard self.config.voiceOutput else { return }
            let busy = self.mode == .thinking || self.mode == .speaking || (self.mode == .listening && self.turn.inSpeech)
            if busy {
                self.announcements.append(text)
            } else {
                self.tts.enqueue(text)
            }
        }
    }

    public func stopSpeaking() {
        queue.async {
            self.interruptSpeech()
            if self.mode == .speaking || self.mode == .thinking {
                self.setMode(.listening)
                self.startSTTTurn(prefix: [])
                self.armIdleTimer()
            }
        }
    }

    // MARK: Engine

    /// Bluetooth headsets switch audio profile when their microphone starts, which makes macOS stop the
    /// engine and change its format. Restart the engine (and re-install the tap) when that happens.
    private func handleConfigurationChange() {
        DebugLog.write("audio configuration changed (device or format switch)")
        guard mode != .off else { return }
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 30 }
        guard recentRestarts.count < 5 else {
            publish(message: "The audio device keeps changing. Try choosing a different input in System Settings > Sound.")
            return
        }
        recentRestarts.append(now)
        engineRunning = true   // make sure stopEngine() really tears down the old tap
        stopEngine()
        startEngine()
    }

    private var lastEngineError = ""

    /// Starts the microphone. Tries echo cancellation first (if enabled), then a plain microphone tap.
    /// A fresh engine is used for every attempt, because a failed start can leave an engine unusable.
    private func startEngine() {
        guard !engineRunning else { return }
        let plan: [Bool] = useVoiceProcessing ? [true, false] : [false]
        for voiceProcessing in plan {
            if tryStartEngine(voiceProcessing: voiceProcessing) {
                if useVoiceProcessing && !voiceProcessing {
                    useVoiceProcessing = false
                    publish(message: "This microphone does not support echo cancellation, so it was turned off. Use headphones if Damson interrupts itself.")
                }
                return
            }
        }
        publish(message: "Could not start the microphone: \(lastEngineError)")
    }

    private func tryStartEngine(voiceProcessing: Bool) -> Bool {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine = AVAudioEngine()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
        let input = engine.inputNode
        if !config.microphoneUID.isEmpty {
            if var deviceID = AudioDevices.deviceID(forUID: config.microphoneUID), let unit = input.audioUnit {
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                DebugLog.write("selected microphone \(config.microphoneUID), status \(status)")
            } else {
                DebugLog.write("selected microphone not found: \(config.microphoneUID)")
            }
        }
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                DebugLog.write("could not enable voice processing: \(error.localizedDescription)")
                lastEngineError = error.localizedDescription
                return false
            }
        }
        let format = input.outputFormat(forBus: 0)
        DebugLog.write("input format: \(format.sampleRate) Hz, \(format.channelCount) channel(s), echo cancellation \(voiceProcessing)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastEngineError = "the input device reports no valid audio format"
            DebugLog.write(lastEngineError)
            return false
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.queue.async { self?.route(buffer) }
        }
        if voiceProcessing {
            _ = engine.mainMixerNode   // echo cancellation needs an output side to the graph
        }
        engine.prepare()
        do {
            try engine.start()
            engineRunning = true
            DebugLog.write("audio engine started (echo cancellation \(voiceProcessing))")
            scheduleSilenceCheck()
            return true
        } catch {
            lastEngineError = error.localizedDescription
            DebugLog.write("audio engine failed to start (echo cancellation \(voiceProcessing)): \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            engine.stop()
            return false
        }
    }

    /// If no sound at all arrives shortly after starting, retry without echo cancellation, then explain.
    private func scheduleSilenceCheck() {
        maxLevelSeen = -120
        silenceCheckGeneration += 1
        let generation = silenceCheckGeneration
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.silenceCheckGeneration == generation, self.engineRunning else { return }
            guard self.maxLevelSeen < -85 else { return }
            DebugLog.write("no audio signal after 4 s (max \(self.maxLevelSeen) dB), echo cancellation: \(self.useVoiceProcessing)")
            if self.useVoiceProcessing {
                self.useVoiceProcessing = false
                self.stopEngine()
                self.startEngine()
                self.publish(message: "Echo cancellation was turned off because no sound came through. If the level bar still does not move, check System Settings > Sound > Input.")
            } else {
                self.publish(message: "Damson hears silence from the microphone. In System Settings > Sound > Input, choose a device and watch its level while you speak. Also check that Damson is allowed under Privacy & Security > Microphone.")
            }
        }
    }

    private func stopEngine() {
        guard engineRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
    }

    // MARK: Audio routing (runs on `queue`)

    private func route(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let level = AudioMath.rmsDB(buffer)
        maxLevelSeen = max(maxLevelSeen, level)
        let now = Date()
        if now.timeIntervalSince(lastLevelPublish) > 0.12 {
            lastLevelPublish = now
            let normalized = max(0, min(1, Double((level + 80) / 60)))
            let levelDB = Double(level)
            Task { @MainActor in
                self.status.inputLevel = normalized
                self.status.inputLevelDB = levelDB
            }
        }
        if now.timeIntervalSince(lastLevelLog) > 5 {
            lastLevelLog = now
            DebugLog.write("mic level \(Int(level)) dB, mode \(mode.rawValue)")
        }

        switch mode {
        case .off:
            return

        case .listening:
            stt.append(buffer)
            let event = turn.ingest(levelDB: level, duration: duration)
            if event == .speechStarted { idleGeneration += 1 }
            if event == .speechEnded && !pttActive { endUserTurn() }

        case .thinking, .speaking:
            ring.append(buffer)
            ringSeconds += duration
            while ringSeconds > 0.8, let first = ring.first {
                ringSeconds -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
            if config.bargeIn, detectBargeIn(level: level, duration: duration) {
                bargeIn()
            }
        }
    }

    // MARK: State transitions (run on `queue`)

    private func setMode(_ new: VoiceMode) {
        mode = new
        let value = new
        DebugLog.write("mode -> \(new.rawValue)")
        Task { @MainActor in
            self.status.mode = value
            if value != .listening { self.status.partialTranscript = "" }
        }
    }

    private func publish(message: String) {
        Task { @MainActor in self.status.message = message }
    }

    private func publish(device: String) {
        Task { @MainActor in self.status.inputDevice = device }
    }

    private func publish(partial: String) {
        Task { @MainActor in self.status.partialTranscript = partial }
    }

    private func enterConversation(greeting: String?) {
        turn.reset()
        bargeTurn.reset()
        idleGeneration += 1
        if let greeting = greeting, config.voiceOutput {
            responseFinished = true
            setMode(.speaking)
            tts.enqueue(greeting)
        } else {
            setMode(.listening)
            startSTTTurn(prefix: [])
            armIdleTimer()
        }
    }

    private func leaveConversation(farewell: String?) {
        cancelResponse()
        stt.cancel()
        idleGeneration += 1
        pttActive = false
        announcements.removeAll()
        if let farewell = farewell, config.voiceOutput {
            tts.enqueue(farewell)
        } else {
            tts.stop()
        }
        // Ending the conversation stops listening.
        stopEngine()
        setMode(.off)
    }

    private func startSTTTurn(prefix: [AVAudioPCMBuffer]) {
        turnGeneration += 1
        let gen = turnGeneration
        turn.reset()
        let started = stt.begin(locale: Locale(identifier: config.locale), prefix: prefix,
                  onPartial: { [weak self] text in
                      self?.publish(partial: text)
                  },
                  onFinal: { [weak self] text in
                      self?.queue.async { self?.completeTurn(generation: gen, text: text) }
                  })
        if !started {
            // Do not loop: tell the user why, and stop listening.
            publish(message: stt.failureReason)
            leaveConversation(farewell: nil)
        }
    }

    private func endUserTurn() {
        let gen = turnGeneration
        stt.endTurn()
        // If the recognizer is slow to finalize, use what we have.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.turnGeneration == gen, self.mode == .listening else { return }
            self.completeTurn(generation: gen, text: self.stt.latestText)
        }
    }

    private func completeTurn(generation: Int, text: String) {
        guard generation == turnGeneration, mode == .listening else { return }
        turnGeneration += 1   // make this turn's remaining callbacks stale
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.write("heard utterance: '\(trimmed)'")
        publish(partial: "")
        if trimmed.isEmpty {
            startSTTTurn(prefix: [])
            return
        }
        if SpeechText.isEndPhrase(trimmed) {
            leaveConversation(farewell: "Very good.")
            return
        }
        processUtterance(trimmed)
    }

    private func processUtterance(_ text: String) {
        stt.cancel()
        responseFinished = false
        ring.removeAll()
        ringSeconds = 0
        bargeTurn.reset()
        resetBargeDetector()
        setMode(.thinking)
        let handler = onUtterance
        Task { [weak self] in
            await handler?(text)
            self?.replyFinished()
        }
        if handler == nil { replyFinished() }
    }

    private func speechDrained() {
        guard mode == .speaking || mode == .thinking else {
            return
        }
        guard responseFinished else { return }
        if !announcements.isEmpty {
            speakNextAnnouncement()
            return
        }
        // Back to listening for the user's next turn.
        setMode(.listening)
        startSTTTurn(prefix: [])
        armIdleTimer()
    }

    private func speakNextAnnouncement() {
        let all = announcements.joined(separator: " ")
        announcements.removeAll()
        setMode(.speaking)
        tts.enqueue(all)
    }

    private func armIdleTimer() {
        return  // Listening stays on until the user stops it; there is no silence timeout.
        let timeout = config.idleTimeout
        guard timeout > 0 else { return }
        idleGeneration += 1
        let gen = idleGeneration
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.idleGeneration == gen, self.mode == .listening, !self.turn.inSpeech else { return }
            self.leaveConversation(farewell: nil)
        }
    }

    private func resetBargeDetector() {
        bargeWarmup = 0
        bargeSeconds = 0
    }

    /// True when the microphone gets clearly louder than it was during Damson's own speech, for a moment.
    /// The first second after speech starts only measures the baseline (Damson's voice leaking into the mic).
    private func detectBargeIn(level: Float, duration: Double) -> Bool {
        if bargeWarmup < 1.0 {
            bargeBaselineDB = bargeWarmup == 0 ? level : bargeBaselineDB * 0.7 + level * 0.3
            bargeWarmup += duration
            return false
        }
        let threshold = max(-55, bargeBaselineDB + 10)
        if level > threshold {
            bargeSeconds += duration
            if bargeSeconds >= 0.25 {
                DebugLog.write("barge-in: \(Int(level)) dB over baseline \(Int(bargeBaselineDB)) dB")
                resetBargeDetector()
                return true
            }
        } else {
            bargeSeconds = 0
            bargeBaselineDB = bargeBaselineDB * 0.95 + level * 0.05
        }
        return false
    }

    private func interruptSpeech() {
        tts.stop()
        cancelResponse()
    }

    private func cancelResponse() {
        onInterrupt?()
        responseFinished = true
    }

    private func bargeIn() {
        let carried = ring
        ring.removeAll()
        ringSeconds = 0
        tts.stop()
        cancelResponse()
        setMode(.listening)
        startSTTTurn(prefix: carried)
        armIdleTimer()
    }
}

// MARK: - Global hotkey (push to talk)

#if canImport(Carbon)
import Carbon.HIToolbox

/// Registers a system-wide hotkey (default: Control+Option+Space). Each instance has its own id,
/// so several hotkeys can coexist (push to talk, start/stop conversation).
public final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?

    public init(id: UInt32 = 1) { self.id = id }

    public func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        unregister()
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData, let event = event else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var firedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            guard firedID.id == me.id else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            if kind == UInt32(kEventHotKeyPressed) {
                me.onPress?()
            } else if kind == UInt32(kEventHotKeyReleased) {
                me.onRelease?()
            }
            return noErr
        }, 2, &specs, selfPointer, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x444D5348), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Control+Option+D.
    public func registerConversationShortcut() {
        register(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
    }

    public func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = handlerRef { RemoveEventHandler(handler) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit { unregister() }
}
#endif
