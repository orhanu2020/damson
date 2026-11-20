import Foundation
import AVFoundation

// MARK: - Spoken-text cleanup

public enum SpeechText {
    /// Removes markdown and URLs so text sounds natural when spoken.
    public static func clean(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "https?://\\S+", with: "a link", options: .regularExpression)
        for mark in ["**", "__", "`", "#", "*"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let endPhrases: [String] = [
        "thats all", "that is all", "thank you damson", "thanks damson", "goodbye damson", "bye damson",
        "goodbye", "thats it", "that will be all", "stop listening", "never mind",
    ]

    /// True when the user is ending the conversation.
    public static func isEndPhrase(_ text: String) -> Bool {
        let n = text.lowercased().filter { $0.isLetter || $0 == " " }
            .split(separator: " ").joined(separator: " ")
        for p in endPhrases where n == p || n == "okay " + p || n == p + " damson" { return true }
        return false
    }
}

// MARK: - Turn detection (energy-based voice activity detection)

public enum AudioMath {
    public static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        var sum: Float = 0
        if let channels = buffer.floatChannelData {
            let data = channels[0]
            for i in 0..<frames { sum += data[i] * data[i] }
        } else if let channels = buffer.int16ChannelData {
            let data = channels[0]
            for i in 0..<frames {
                let v = Float(data[i]) / 32768.0
                sum += v * v
            }
        } else {
            return -120
        }
        let rms = (sum / Float(frames)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }
}

public enum TurnEvent: Equatable {
    case speechStarted
    case speechEnded
}

/// Detects when the user starts and stops speaking, from per-buffer loudness.
public struct TurnDetector {
    public var startMarginDB: Float
    public var minSpeechSeconds: Double
    public var endSilenceSeconds: Double
    public var absoluteFloorDB: Float

    private var noiseFloorDB: Float = -60
    private var speechSeconds: Double = 0
    private var silenceSeconds: Double = 0
    public private(set) var inSpeech = false

    public init(startMarginDB: Float = 12, minSpeechSeconds: Double = 0.15, endSilenceSeconds: Double = 0.8, absoluteFloorDB: Float = -50) {
        self.startMarginDB = startMarginDB
        self.minSpeechSeconds = minSpeechSeconds
        self.endSilenceSeconds = endSilenceSeconds
        self.absoluteFloorDB = absoluteFloorDB
    }

    public mutating func reset() {
        speechSeconds = 0
        silenceSeconds = 0
        inSpeech = false
    }

    /// Feed one buffer's loudness and duration. Returns an event when a turn starts or ends.
    public mutating func ingest(levelDB: Float, duration: Double) -> TurnEvent? {
        let threshold = max(absoluteFloorDB, noiseFloorDB + startMarginDB)
        let isLoud = levelDB > threshold

        if !isLoud && !inSpeech {
            // Track the room's noise floor slowly while it is quiet.
            noiseFloorDB = noiseFloorDB * 0.95 + levelDB * 0.05
        }

        if isLoud {
            speechSeconds += duration
            silenceSeconds = 0
            if !inSpeech && speechSeconds >= minSpeechSeconds {
                inSpeech = true
                return .speechStarted
            }
        } else {
            if inSpeech {
                silenceSeconds += duration
                if silenceSeconds >= endSilenceSeconds {
                    inSpeech = false
                    speechSeconds = 0
                    silenceSeconds = 0
                    return .speechEnded
                }
            } else {
                speechSeconds = 0
            }
        }
        return nil
    }
}
