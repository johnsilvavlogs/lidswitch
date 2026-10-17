import Foundation
import LidSwitchXPCBridge

/// Presentation and routing only. No error, status projection, or repair CTA
/// confers authority or proves that macOS sleep has been restored.
extension HelperControlError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "LidSwitch could not connect to its installed helper."
        case .indeterminateTransport:
            return "The helper's reply was interrupted or timed out. The requested change is not yet verified."
        case let .transport(status):
            if status == Int32(LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE.rawValue) {
                return "LidSwitch could not verify the installed helper's identity or reply."
            }
            return "LidSwitch could not complete the helper request."
        case let .rejected(reason):
            switch reason {
            case "containment-pending", "containment-extinction-unproven":
                return "The helper cannot prove that an earlier power-setting process has stopped. Sleep restoration remains blocked for safety."
            default:
                return "The helper could not safely complete this request."
            }
        case .malformedReply:
            return "The helper's reply could not be verified."
        }
    }

    /// A timeout/interruption or pending cleanup may still converge through
    /// ordinary RESTORE. Only a definite failure offers explicit repair.
    /// This classification never requests administrator access by itself.
    var requiresInlineRepair: Bool {
        switch self {
        case .unavailable, .malformedReply:
            return true
        case let .transport(status):
            return status == Int32(LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE.rawValue)
        case let .rejected(reason):
            return reason == "containment-extinction-unproven"
        case .indeterminateTransport:
            return false
        }
    }
}

enum HelperRestoreGuidance {
    static let repairDetail = "Normal sleep has not been verified. Choose Repair Helper to run the administrator recovery check. Keep LidSwitch open until restoration is verified."

    static func failureDetail(_ error: Error) -> String {
        (error as? HelperControlError)?.errorDescription
            ?? "The helper could not finish restoring sleep."
    }
}
