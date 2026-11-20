import SwiftUI
import DamsonUI

@main
struct DamsonApp: App {
    @NSApplicationDelegateAdaptor(DamsonAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(status: model.voiceStatus)
        }
    }
}
