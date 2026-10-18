import Foundation

/// Presentation only: all mutations still pass through PowerController's
/// existing preflights, authenticated session termination and repair handoff.
/// The panel and its shortcuts consume the same availability decisions.
struct LidSwitchPanelPresentation: Equatable {
    struct Action: Equatable {
        enum Kind: Equatable { case prepareHelper, restoreSleep, refresh }
        let kind: Kind
        let title: String
        let symbol: String
        let hint: String
        let isEnabled: Bool
    }

    let masterEnabled: Bool
    let masterHint: String
    let sourceChoicesEnabled: Bool
    let guidance: String?
    let inlineAction: Action?

    /// Exactly one visible control owns Command-K. A detached restore must
    /// not compete with a disabled master switch for the same shortcut.
    var commandKRestoresSleep: Bool {
        !masterEnabled && inlineAction?.kind == .restoreSleep
            && inlineAction?.isEnabled == true
    }

    @MainActor
    init(controller: PowerController) {
        let snapshot = controller.snapshot
        let phase = controller.operationPhase
        let isOn = controller.isKeepAwakeOn
        let available = !controller.isBusy && !controller.isChecking
        let noSources = controller.powerPreferences.sessionPowerPolicy == nil
        let primary = controller.primaryAction

        switch phase {
        case .starting:
            masterEnabled = true
        case .preparingHelper:
            // OFF cancels only the requested activation, not the administrator
            // transaction. Finishing setup must not turn a canceled request on.
            masterEnabled = isOn
        case .idle:
            if isOn {
                // A read in flight is not a reason to withhold authenticated
                // END or cancellation of a paused request.
                masterEnabled = !controller.isBusy
            } else {
                masterEnabled = available && !noSources
                    && snapshot.source.isKnown && snapshot.sleepDisabledVerified
                    && !snapshot.sleepDisabled && !snapshot.restoreRequired
                    && snapshot.ownedSessionID == nil
                    && (primary == .startSession || primary == .prepareHelper)
                    && (snapshot.helperReady && !snapshot.legacyResiduePresent
                        ? !snapshot.hasCriticalSafetyIssue
                        : snapshot.canPrepareHelper && !controller.requiresExplicitHelperPreparation)
            }
        case .cancelRestoring, .endingRestoring, .removingHelper, .recoveryRequired:
            masterEnabled = false
        }

        // Source edits are not actionable during recovery or a transition.
        // In particular, do not render enabled controls whose controller setter
        // will reject the edit while a detached cleanup owner is retained.
        sourceChoicesEnabled = available && phase == .idle
            && !snapshot.hasCriticalSafetyIssue && primary != .restoreSleep
            && !controller.restoreRequiresHelperRepair
            && controller.displayedStatus.tone != .warning

        let settled = phase == .idle || phase == .recoveryRequired
        let canRetryRead = !snapshot.sleepDisabledVerified || !snapshot.source.isKnown
            || snapshot.installationInventoryIndeterminate
        if settled, primary == .restoreSleep, !isOn {
            inlineAction = Action(kind: .restoreSleep, title: "Restore Sleep", symbol: "moon.zzz.fill",
                                  hint: "Restores and verifies normal sleep. Command-K.",
                                  isEnabled: !controller.isBusy)
        } else if settled, primary == .prepareHelper,
                  snapshot.canPrepareHelper, snapshot.sleepDisabledVerified,
                  snapshot.helperPreparationCTA == .repair || snapshot.legacyResiduePresent
                    || snapshot.restoreRequired || phase == .recoveryRequired
                    || controller.restoreRequiresHelperRepair
                    || controller.requiresExplicitHelperPreparation {
            let title = snapshot.helperNeedsUpdate ? "Update Helper" : snapshot.helperPreparationCTA.title
            inlineAction = Action(kind: .prepareHelper, title: title, symbol: "shield.lefthalf.filled",
                                  hint: "Requires administrator approval. Setup and sleep restoration are verified before continuing.",
                                  isEnabled: available)
        } else if settled, !isOn, canRetryRead {
            inlineAction = Action(kind: .refresh, title: "Refresh", symbol: "arrow.clockwise",
                                  hint: "Checks the power source, sleep settings, and helper again. Command-R.",
                                  isEnabled: available)
        } else {
            inlineAction = nil
        }

        if phase == .preparingHelper {
            masterHint = isOn
                ? "Turn off to finish setup without turning on Keep Mac awake."
                : "Setup will finish with Keep Mac awake off."
        } else if phase == .starting, primary == .cancelStart {
            masterHint = "Turn off to cancel the pending start and restore system sleep."
        } else if isOn {
            masterHint = "Turn off to stop keeping your Mac awake and restore your sleep settings."
        } else if masterEnabled {
            masterHint = "Keeps your Mac awake on the selected power sources. Command-K turns it on."
        } else if let action = inlineAction, action.isEnabled {
            masterHint = "Use \(action.title) before turning on Keep Mac awake."
        } else if noSources {
            masterHint = "Choose at least one power source below."
        } else {
            masterHint = controller.displayedStatus.detail
        }

        switch phase {
        case .preparingHelper:
            guidance = isOn
                ? "Setting up the helper. Turn off to finish with Keep Mac awake off."
                : "Finishing setup. Keep Mac awake will stay off."
        case .starting:
            guidance = controller.displayedStatus.detail
        case .cancelRestoring, .endingRestoring:
            guidance = "Restoring your sleep settings. Keep LidSwitch open."
        case .removingHelper:
            guidance = "Restoring sleep and removing the helper. Keep LidSwitch open."
        case .idle, .recoveryRequired:
            if let action = inlineAction, action.kind == .restoreSleep {
                guidance = "Sleep restoration is not verified. Keep LidSwitch open and choose Restore Sleep."
            } else if let action = inlineAction, action.kind == .prepareHelper {
                guidance = "Choose \(action.title) to continue. macOS requires administrator approval."
            } else if controller.isChecking, !isOn {
                guidance = "Checking power and helper status…"
            } else if inlineAction?.kind == .refresh {
                guidance = "LidSwitch could not verify the current state. Refresh to check again."
            } else if snapshot.hasCriticalSafetyIssue || phase == .recoveryRequired {
                guidance = controller.displayedStatus.detail
            } else if noSources {
                guidance = "Choose at least one power source below."
            } else if isOn {
                guidance = controller.displayedStatus.detail
            } else if primary == .prepareHelper, masterEnabled {
                guidance = "Turn on to set up once. macOS requires administrator approval."
            } else {
                guidance = nil
            }
        }
    }
}
