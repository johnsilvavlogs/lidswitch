import AppKit
import Darwin
import SwiftUI

@main
struct LidSwitchApp: App {
    private let instanceLock: AppInstanceLock
    @NSApplicationDelegateAdaptor(LidSwitchApplicationDelegate.self) private var appDelegate
    @StateObject private var controller: PowerController
    @StateObject private var confirmationPresenter: NativeConfirmationPresenter

    init() {
        // Diagnostic/packaging commands must exit before a controller is created.
        // Production explicitly selects the authenticated raw-XPC client.
        DebugCommands.handleIfNeeded()
        do {
            guard let lock = try AppInstanceLock.acquireForCurrentUser() else {
                // No controller exists, so a losing launch cannot restore or
                // revoke the active owner's session during termination.
                exit(0)
            }
            instanceLock = lock
        } catch {
            FileHandle.standardError.write(Data("LidSwitch could not safely acquire its instance lock: \(error)\n".utf8))
            exit(EX_CANTCREAT)
        }
        let client = try? RawHelperControlClient.production()
        let controller = PowerController(sideEffects: .production(client: client))
        let confirmationPresenter = NativeConfirmationPresenter()
        _controller = StateObject(wrappedValue: controller)
        _confirmationPresenter = StateObject(wrappedValue: confirmationPresenter)
        LidSwitchApplicationDelegate.controller = controller
        LidSwitchApplicationDelegate.confirmationPresenter = confirmationPresenter
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
    static weak var confirmationPresenter: NativeConfirmationPresenter?

    private var controlPanelWindow: NSWindowController?

    // Finder, Spotlight and `open -a LidSwitch` send a normal reopen event to
    // the existing owner. Provide access to the same controls without requiring
    // a physical status-item click or creating another power controller.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let controller = Self.controller,
              let confirmationPresenter = Self.confirmationPresenter else {
            return false
        }
        if controlPanelWindow == nil {
            let hostingController = NSHostingController(
                rootView: LidSwitchPanel(
                    controller: controller,
                    confirmationPresenter: confirmationPresenter
                ).frame(width: 320)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "LidSwitch"
            window.identifier = NSUserInterfaceItemIdentifier("LidSwitchControlPanel")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            controlPanelWindow = NSWindowController(window: window)
        }
        controller.refresh()
        controlPanelWindow?.showWindow(nil)
        controlPanelWindow?.window?.deminiaturize(nil)
        controlPanelWindow?.window?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

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
