import AppKit
import Combine

enum NativeConfirmationAction: CaseIterable, Equatable {
    case startSession
    case removeHelper
    case quit

    var title: String {
        switch self {
        case .startSession: "Start Plugged-In Session?"
        case .removeHelper: "Remove LidSwitch Helper?"
        case .quit: "Restore Sleep and Quit?"
        }
    }

    var message: String {
        switch self {
        case .startSession:
            "LidSwitch will block lid-close sleep for this session only. Unplugging, quitting, restarting, or a missed safety check ends it. Reconnecting power never starts it automatically."
        case .removeHelper:
            "This ends any active session, restores system sleep, and removes LidSwitch helper files."
        case .quit:
            "LidSwitch will stop this session and verify that the system sleep override is off before quitting."
        }
    }

    var confirmTitle: String {
        switch self {
        case .startSession: "Start and Verify"
        case .removeHelper: "Remove Helper"
        case .quit: "Restore and Quit"
        }
    }

    var isDestructive: Bool { self == .removeHelper }
    var confirmsWithReturn: Bool { true }
    var cancelsWithEscape: Bool { true }
}

enum NativeConfirmationResponse: Equatable { case confirm, cancel }

@MainActor
final class NativeConfirmationPresenter: ObservableObject {
    typealias ResponseProvider = @MainActor (NativeConfirmationAction) -> NativeConfirmationResponse

    private let responseProvider: ResponseProvider
    private var isPresenting = false

    init(responseProvider: @escaping ResponseProvider = NativeConfirmationPresenter.presentAlert) {
        self.responseProvider = responseProvider
    }

    @discardableResult
    func present(_ action: NativeConfirmationAction, perform: () -> Void) -> Bool {
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        guard responseProvider(action) == .confirm else { return true }
        perform()
        return true
    }

    private static func presentAlert(_ action: NativeConfirmationAction) -> NativeConfirmationResponse {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = action.isDestructive ? .critical : .warning
        alert.messageText = action.title
        alert.informativeText = action.message
        alert.addButton(withTitle: action.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = action.confirmsWithReturn ? "\r" : ""
        alert.buttons[1].keyEquivalent = action.cancelsWithEscape ? "\u{1b}" : ""
        if action.isDestructive, #available(macOS 11.0, *) {
            alert.buttons[0].hasDestructiveAction = true
        }
        return alert.runModal() == .alertFirstButtonReturn ? .confirm : .cancel
    }
}
