import SwiftUI
import AppKit
import DamsonProviders
import DamsonTools
import DamsonCore
import DamsonVoice

// MARK: - Chat

struct ChatView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: VoiceStatus

    private struct Suggestion: Identifiable {
        let label: String
        let text: String
        var id: String { label }
    }

    private let suggestions: [Suggestion] = [
        Suggestion(label: "What time is it?", text: "What time is it in Tokyo?"),
        Suggestion(label: "Tell me a fact", text: "Tell me something interesting."),
        Suggestion(label: "What can you do?", text: "What can you do for me?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(model: model, status: status)
            Divider()
            if !model.notice.isEmpty {
                Text(model.notice).font(.caption).padding(6).frame(maxWidth: .infinity).background(Color.red.opacity(0.1))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.chip))
                            .frame(maxWidth: .infinity)
                        if model.messages.isEmpty {
                            GreetingCard()
                        }
                        ForEach(model.messages) { m in
                            MessageRow(message: m).id(m.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: model.messages.last?.text) { _, _ in
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            VoiceStrip(model: model, status: status)
            FlowLayout(spacing: 8) {
                ForEach(suggestions) { item in
                    Button {
                        model.inputText = item.text
                        model.send()
                    } label: {
                        Text(item.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.green)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().stroke(Theme.green.opacity(0.55), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isResponding)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            InputBar(model: model, status: status)
        }
        .background(Theme.chatBackground)
        .navigationTitle("Damson")
    }
}

struct ChatHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: VoiceStatus

    private var statusLine: String {
        return status.mode.label
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.green)
                Text("D")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Damson").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.mode == .off ? Color.gray : Theme.onlineGreen)
                        .frame(width: 7, height: 7)
                    Text(statusLine).font(.caption).foregroundStyle(Theme.onlineGreen)
                }
            }
            Spacer()
            Text(model.usesClaude ? "CLAUDE" : "LOCAL MODELS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.olive)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Theme.olive.opacity(0.7), lineWidth: 1))
            Button { model.clearChat() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear conversation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card)
    }
}

struct GreetingCard: View {
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning." }
        if hour < 18 { return "Good afternoon." }
        return "Good evening."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(greeting) I'm Damson, your assistant.")
            Text("Type a request, tap a suggestion below, or press the **microphone** and just speak. . Anything that changes your Mac or an online account needs your approval first.")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InputBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: VoiceStatus

    private var micActive: Bool { status.mode == .listening || status.mode == .thinking || status.mode == .speaking }
    private var canSend: Bool { !model.inputText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
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
            .help("Start or stop listening (Control+Option+D).")

            TextField("Ask Damson", text: $model.inputText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .onSubmit { model.send() }

            if model.isResponding {
                Button { model.cancelResponse() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.green))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.green.opacity(canSend ? 1 : 0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

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
                Text(message.text.isEmpty ? "\u{2026}" : message.text)
                    .textSelection(.enabled)
                    .italic(message.isLive)
                    .opacity(message.isLive ? 0.7 : 1)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
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
