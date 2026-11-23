import SwiftUI
import AppKit
import DamsonProviders
import DamsonTools
import DamsonCore
import DamsonVoice

// MARK: - Chat

struct MessageRow: View {
    let message: ChatMessage

    private var isUser: Bool { message.kind == .user }
    private var labelColor: Color { isUser ? Color.white.opacity(0.75) : Color.secondary }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 4) {
                if message.isLive {
                    Label("Listening\u{2026}", systemImage: "waveform").font(.caption2).foregroundStyle(labelColor)
                } else if message.viaVoice && message.kind == .user {
                    Label("You said", systemImage: "mic.fill").font(.caption2).foregroundStyle(labelColor)
                } else if message.viaVoice && message.kind == .assistant {
                    Label("Damson said", systemImage: "speaker.wave.2.fill").font(.caption2).foregroundStyle(labelColor)
                }
                if message.kind == .tool {
                    Label("Using a tool", systemImage: "wrench.and.screwdriver").font(.caption2).foregroundStyle(.secondary)
                }
                if message.kind == .system {
                    Label("Needs you", systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
                }
                if !message.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                            if let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                if !(message.text.isEmpty && !message.images.isEmpty) { Text(message.text.isEmpty ? "\u{2026}" : message.text)
                    .textSelection(.enabled)
                    .italic(message.isLive)
                    .opacity(message.isLive ? 0.7 : 1)
                    .foregroundStyle(isUser ? Color.white : Color.primary) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(border, lineWidth: 1))
            if !isUser { Spacer(minLength: 80) }
        }
    }

    private var fill: Color {
        switch message.kind {
        case .user: return Theme.green
        case .assistant: return Theme.card
        case .system: return Color.orange.opacity(0.12)
        case .tool: return Theme.chip
        }
    }

    private var border: Color {
        switch message.kind {
        case .user: return Theme.green
        case .assistant: return Theme.stroke
        case .system: return Color.orange.opacity(0.45)
        case .tool: return Theme.stroke
        }
    }
}
