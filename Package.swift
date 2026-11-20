// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Damson",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Damson", targets: ["DamsonApp"])
    ],
    targets: [
        // Tiny shared utilities (locking, app paths). No dependencies.
        .target(name: "DamsonSupport"),
        // Vendor-agnostic model layer: neutral types, LLMProvider protocol, Claude + Ollama adapters.
        .target(name: "DamsonProviders", dependencies: ["DamsonSupport"]),
        // SQLite event/task store and Keychain wrapper.
        .target(name: "DamsonStore", dependencies: ["DamsonSupport"]),
        // Tool protocol, policy gate (Observe/Change approvals), shell/files/web/browser/MCP tools.
        .target(name: "DamsonTools", dependencies: ["DamsonSupport", "DamsonProviders"]),
        // Orchestrator: classifier, planner, scheduler, helper agents, reporter, event bus, engine.
        .target(name: "DamsonCore", dependencies: ["DamsonSupport", "DamsonProviders", "DamsonStore", "DamsonTools"]),
        // Voice: wake word, speech-to-text, text-to-speech, conversation controller.
        .target(name: "DamsonVoice", dependencies: ["DamsonSupport"]),
        // SwiftUI: chat, Kanban board, settings, approvals, menu bar.
        .target(name: "DamsonUI", dependencies: ["DamsonSupport", "DamsonProviders", "DamsonStore", "DamsonTools", "DamsonCore", "DamsonVoice"]),
        .executableTarget(name: "DamsonApp", dependencies: ["DamsonUI"]),
        .testTarget(
            name: "DamsonTests",
            dependencies: ["DamsonSupport", "DamsonProviders", "DamsonStore", "DamsonTools", "DamsonCore", "DamsonVoice"]
        ),
    ]
)
