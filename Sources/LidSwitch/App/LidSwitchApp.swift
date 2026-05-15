import SwiftUI

@main
struct LidSwitchApp: App {
    @StateObject private var controller = PowerController()

    init() {
        DebugCommands.handleIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra("LidSwitch", systemImage: controller.menuBarSymbol) {
            LidSwitchPanel(controller: controller)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)
    }
}
