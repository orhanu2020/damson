import Foundation
import AVFoundation
import Speech
import DamsonSupport

// MARK: - Text to speech

/// System text-to-speech (AVSpeechSynthesizer). Replaceable behind the same small surface
/// (enqueue / stop / isBusy / onDrained) by neural or cloud voices later.
public final class SystemSpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct Counters {
        var pending = 0
        var epoch = 0
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let counters = Locked<Counters>(Counters())
    // Touched only on the main thread.
    private var utteranceEpochs: [ObjectIdentifier: Int] = [:]

    public var voiceIdentifier: String = ""
    public var rate: Float = 0.5
    public var languageCode: String = "en-US"
    public var onDrained: (@Sendable () -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// True from the moment text is queued until the last queued sentence has finished.
    public var isBusy: Bool { counters.current.pending > 0 }

    public static func availableVoices() -> [(id: String, name: String, language: String)] {
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { (id: $0.identifier, name: $0.name, language: $0.language) }
    }

    private func chooseVoice() -> AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { return v }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        let best = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
        return best ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    public func enqueue(_ text: String) {
        let cleaned = SpeechText.clean(text)
        if cleaned.isEmpty { return }
        let myEpoch = counters.withLock { (c: inout Counters) -> Int in
            c.pending += 1
            return c.epoch
        }
        DispatchQueue.main.async {
            // stop() was called after this was queued: its counters were already reset.
            if self.counters.current.epoch != myEpoch { return }
            let utterance = AVSpeechUtterance(string: cleaned)
            utterance.voice = self.chooseVoice()
            utterance.rate = self.rate
            self.utteranceEpochs[ObjectIdentifier(utterance)] = myEpoch
            self.synthesizer.speak(utterance)
        }
    }

    public func stop() {
        counters.withLock { (c: inout Counters) in
            c.epoch += 1
            c.pending = 0
        }
        DispatchQueue.main.async {
            self.utteranceEpochs.removeAll()
            self.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard let e = utteranceEpochs.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        let drained = counters.withLock { (c: inout Counters) -> Bool in
            guard c.epoch == e else { return false }
            c.pending = max(0, c.pending - 1)
            return c.pending == 0
        }
        if drained { onDrained?() }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(utterance)
    }
}

enum SpeechSupport {
    static func onDeviceMissingMessage(_ locale: Locale) -> String {
        return "On-device speech recognition isn't available for \(locale.identifier). Turn on Dictation and download the language in System Settings > Keyboard > Dictation, or allow Apple's server recognition in Damson Settings > Voice (your audio is then sent to Apple)."
    }
}

// MARK: - Speech to text (per conversation turn)

/// Streaming speech recognition for one user turn, using Apple's on-device recognizer when available.
public final class AppleSpeechTurnRecognizer: @unchecked Sendable {
    private struct Session {
        var request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var id: UUID
        var finished: Bool
    }

    private let session = Locked<Session?>(nil)
    private let lastText = Locked<String>("")

    public init() {}

    public static func requestPermissions(completion: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else { completion(false); return }
            AVCaptureDevice.requestAccess(for: .audio) { granted in completion(granted) }
        }
    }

    /// Starts a new turn. `prefix` buffers (audio heard just before the turn began) are fed first.
    public var allowServerRecognition = false
    private let failure = Locked<String>("")
    public var failureReason: String { failure.current }

    private func fail(_ message: String) {
        DebugLog.write("stt: \(message)")
        failure.withLock { $0 = message }
    }

    /// Returns false (with `failureReason` set) when recognition cannot start.
    @discardableResult
    public func begin(locale: Locale, prefix: [AVAudioPCMBuffer],
                      onPartial: @escaping @Sendable (String) -> Void,
                      onFinal: @escaping @Sendable (String) -> Void) -> Bool {
        cancel()
        lastText.withLock { $0 = "" }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            fail("Speech recognition permission is not granted. Enable it for Damson in System Settings > Privacy & Security > Speech Recognition.")
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            fail("The speech recognizer is not available for \(locale.identifier).")
            return false
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        if !onDevice && !allowServerRecognition {
            fail(SpeechSupport.onDeviceMissingMessage(locale))
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Damson", "Hey Damson"]
        request.requiresOnDeviceRecognition = onDevice

        let id = UUID()
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            let isCurrent = self.session.current?.id == id
            guard isCurrent else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastText.withLock { $0 = text }
                if result.isFinal {
                    self.finish(id: id, text: text, onFinal: onFinal)
                } else {
                    onPartial(text)
                }
            } else if let error = error {
                DebugLog.write("stt error: \(error.localizedDescription)")
                self.finish(id: id, text: self.lastText.current, onFinal: onFinal)
            }
        }
        session.withLock { $0 = Session(request: request, task: task, id: id, finished: false) }
        for b in prefix { request.append(b) }
        return true
    }

    private func finish(id: UUID, text: String, onFinal: @escaping @Sendable (String) -> Void) {
        let shouldFire = session.withLock { s -> Bool in
            guard var current = s, current.id == id, !current.finished else { return false }
            current.finished = true
            s = current
            return true
        }
        if shouldFire { onFinal(text) }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        session.current?.request.append(buffer)
    }

    /// Tells the recognizer no more audio is coming; the final result follows.
    public func endTurn() {
        session.current?.request.endAudio()
    }

    public var latestText: String { lastText.current }

    public func cancel() {
        let old = session.withLock { s -> Session? in
            let previous = s
            s = nil
            return previous
        }
        old?.task?.cancel()
    }
}
