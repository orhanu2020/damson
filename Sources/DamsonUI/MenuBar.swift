import SwiftUI
import AppKit
import DamsonVoice

/// Draws the butler glyph for the menu bar, with a small badge showing the voice state.
enum MenuBarIcon {
    static let base: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static func image(for mode: VoiceMode) -> NSImage? {
        guard let base = base else { return nil }
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let alpha: CGFloat = (mode == .off) ? 0.5 : 1.0
            base.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: alpha)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch mode {
            case .off:
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2, y: 2))
                slash.line(to: NSPoint(x: 17, y: 16))
                slash.lineWidth = 1.6
                slash.stroke()
            case .listening:
                NSBezierPath(ovalIn: NSRect(x: 16.5, y: 1.5, width: 5, height: 5)).fill()
            case .thinking:
                let ring = NSBezierPath(ovalIn: NSRect(x: 16.5, y: 1.5, width: 5, height: 5))
                ring.lineWidth = 1.2
                ring.stroke()
            case .speaking:
                let ring = NSBezierPath(ovalIn: NSRect(x: 15.5, y: 0.5, width: 7, height: 7))
                ring.lineWidth = 1.1
                ring.stroke()
                NSBezierPath(ovalIn: NSRect(x: 17.7, y: 2.7, width: 2.6, height: 2.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Shows the butler in the menu bar; the badge shows the current voice state.
public struct MenuBarLabel: View {
    @ObservedObject var status: VoiceStatus

    public init(status: VoiceStatus) {
        self.status = status
    }

    var fallbackSymbol: String {
        switch status.mode {
        case .off: return "mic.slash"
        case .listening: return "waveform"
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2"
        }
    }

    public var body: some View {
        if let image = MenuBarIcon.image(for: status.mode) {
            Image(nsImage: image)
        } else {
            Image(systemName: fallbackSymbol)
        }
    }
}

public struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var status: VoiceStatus

    public init(model: AppModel) {
        self.model = model
        self.status = model.voiceStatus
    }

    public var body: some View {
        Text("Damson · \(status.mode.label)")
        if !model.menuBadge.isEmpty {
            Text(model.menuBadge)
        }
        Divider()
        Button("Open Damson") {
            MainWindowManager.shared.show(model: model)
        }
        Button(status.mode == .off ? "Start listening" : "Stop listening") { model.toggleListening() }
        if status.mode == .speaking {
            Button("Stop talking") { model.voice.stopSpeaking() }
        }
        Divider()
        Button("Quit Damson") {
            model.shutdown()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// Keeps Damson running in the menu bar when the window is closed. Quit only from the menu.
public final class DamsonAppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
                if visible.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

/// Owns the main window directly (AppKit), because SwiftUI's openWindow is unreliable from a menu-bar-only app.
@MainActor
final class MainWindowManager {
    static let shared = MainWindowManager()
    private var window: NSWindow?

    func show(model: AppModel) {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let hosting = NSHostingController(rootView: RootView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Damson"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 1100, height: 700))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
