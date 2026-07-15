import AppKit
import SwiftUI

@main
struct LidSwitchApp: App {
    @NSApplicationDelegateAdaptor(LidSwitchApplicationDelegate.self) private var appDelegate
    @StateObject private var controller: PowerController
    @StateObject private var confirmationPresenter: NativeConfirmationPresenter

    init() {
        // Diagnostic/packaging commands must exit before a controller is created.
        // Production explicitly selects the authenticated raw-XPC client.
        DebugCommands.handleIfNeeded()
        let client = try? RawHelperControlClient.production()
        let controller = PowerController(sideEffects: .production(client: client))
        _controller = StateObject(wrappedValue: controller)
        _confirmationPresenter = StateObject(wrappedValue: NativeConfirmationPresenter())
        LidSwitchApplicationDelegate.controller = controller
    }

    var body: some Scene {
        MenuBarExtra {
            LidSwitchPanel(controller: controller, confirmationPresenter: confirmationPresenter)
                .frame(width: 370)
        } label: {
            Label(controller.displayedStatus.title, systemImage: controller.menuBarSymbol)
                .accessibilityLabel(controller.displayedStatus.accessibilityState)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class LidSwitchApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var controller: PowerController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = Self.controller else {
            return .terminateNow
        }
        if controller.consumeAuthorizedTermination() {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore sleep and quit LidSwitch?"
        alert.informativeText = "LidSwitch will stop renewing any session and verify that the system sleep override is off before it quits."
        alert.addButton(withTitle: "Restore and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        guard controller.requiresTerminationCleanup else {
            return .terminateNow
        }
        controller.prepareForSystemTermination { restored in
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.controller?.revokeForImmediateTermination()
    }
}
