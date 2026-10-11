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
                .frame(width: 320)
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
