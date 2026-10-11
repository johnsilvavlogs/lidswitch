import AppKit
import SwiftUI

struct LidSwitchPanel: View {
    @ObservedObject var controller: PowerController
    let confirmationPresenter: NativeConfirmationPresenter
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.horizontal, 6)
                .padding(.bottom, 14)

            masterCard
                .padding(.bottom, 10)

            powerSourceControls

            Text("Turning off restores normal sleep.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(minHeight: 17, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.top, 14)
                .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 6)

            controls
                .padding(.horizontal, 6)
        }
        .padding(14)
        .frame(minHeight: 438, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // Opening the panel refreshes live power and safety truth.
            controller.refresh()
        }
    }

    private var header: some View {
        Text("LidSwitch")
            .font(.system(size: 27, weight: .semibold))
            .tracking(-0.5)
            .frame(maxWidth: .infinity, minHeight: 45, maxHeight: 45, alignment: .leading)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            keepAwakeSwitch

            statusBlock
                .padding(.leading, 62)

            if let errorMessage = controller.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error. \(errorMessage)")
            } else if let guidance = inlineGuidance {
                Text(guidance)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recoveryAction
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .background(cardSurface)
    }

    private var keepAwakeSwitch: some View {
        HStack(spacing: 22) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 31))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 28)
                .accessibilityHidden(true)

            Toggle("Keep Mac awake", isOn: Binding(
                get: { controller.isKeepAwakeOn },
                set: { controller.setKeepAwakeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.regular)
            .font(.system(size: 20, weight: .medium))
            .disabled(!canChangeKeepAwake)
            .keyboardShortcut("k", modifiers: [.command])
            .accessibilityHint(
                controller.operationPhase == .starting
                    ? "Turn off to cancel the pending start and restore system sleep."
                    : "Keeps this Mac awake on the power sources selected below. Turn off to restore system sleep."
            )
        }
        .frame(minHeight: 28)
    }

    private var statusBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIndicator
                .frame(width: 14, height: 19)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.displayedStatus.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)

                Text(controller.snapshot.source.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.displayedStatus.accessibilityState)
        .accessibilityValue(controller.snapshot.source.title)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if controller.isBusy || controller.isChecking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(progressAccessibilityLabel)
        } else {
            Image(systemName: controller.displayedStatus.tone == .active
                  ? "circle.fill" : controller.displayedStatus.panelSymbol)
                .font(.system(size: 14))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
    }

    private var powerSourceControls: some View {
        VStack(spacing: 0) {
            sourceToggle(
                "Plugged in",
                symbol: "powerplug.fill",
                isOn: Binding(
                    get: { controller.powerPreferences.allowPluggedInKeepAwake },
                    set: { controller.setAllowPluggedInKeepAwake($0) }
                ),
                hint: "Allows Keep Mac awake while connected to power."
            )

            Divider()
                .padding(.leading, 66)
                .padding(.trailing, 16)

            sourceToggle(
                "On battery",
                symbol: "battery.100percent",
                isOn: Binding(
                    get: { controller.powerPreferences.allowBatteryKeepAwake },
                    set: { controller.setAllowBatteryKeepAwake($0) }
                ),
                hint: "Allows Keep Mac awake while using battery power."
            )
        }
        .background(cardSurface)
        .disabled(
            controller.isBusy
                || controller.isChecking
                || controller.operationPhase == .starting
                || controller.operationPhase == .cancelRestoring
                || controller.operationPhase == .endingRestoring
        )
    }

    private func sourceToggle(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>,
        hint: String
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 27))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 17))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
        .accessibilityHint(hint)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(
                accessibilityContrast == .increased ? 1 : 0.65
            ))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        accessibilityContrast == .increased
                            ? Color.primary.opacity(0.45)
                            : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 1
                    )
            }
    }

    private var canChangeKeepAwake: Bool {
        // OFF remains a cancellation path during start verification.
        if controller.operationPhase == .starting { return true }
        guard !controller.isBusy, !controller.isChecking else { return false }
        if controller.isKeepAwakeOn { return true }
        let snapshot = controller.snapshot
        guard controller.operationPhase == .idle,
              snapshot.source.isKnown,
              snapshot.sleepDisabledVerified,
              !snapshot.sleepDisabled,
              !snapshot.restoreRequired,
              controller.powerPreferences.allowPluggedInKeepAwake
                || controller.powerPreferences.allowBatteryKeepAwake
        else { return false }
        if !snapshot.helperReady || snapshot.legacyResiduePresent {
            return snapshot.canPrepareHelper
        }
        // Intent can wait on an excluded source after the safety checks pass.
        return !snapshot.hasCriticalSafetyIssue
    }

    private var inlineGuidance: String? {
        if !controller.powerPreferences.allowPluggedInKeepAwake,
           !controller.powerPreferences.allowBatteryKeepAwake {
            return "Choose Plugged in or On battery to turn on."
        }
        switch controller.operationPhase {
        case .starting:
            return "Verifying protection. Turn off to cancel and restore sleep."
        case .cancelRestoring, .endingRestoring:
            return "Verifying that normal sleep is restored."
        case .preparingHelper:
            return "Approve the macOS request to continue. Protection stays off until verified."
        case .removingHelper:
            return "Restoring sleep and removing the helper."
        case .idle, .recoveryRequired:
            break
        }
        if controller.primaryAction == .prepareHelper,
           controller.snapshot.helperPreparationCTA == .prepare,
           canChangeKeepAwake {
            return "Turn on to install once with macOS administrator approval."
        }
        if controller.displayedStatus.tone == .warning
            || !controller.snapshot.source.isKnown
            || (controller.isKeepAwakeOn && !controller.snapshot.sessionActive)
            || controller.primaryAction == .prepareHelper
            || controller.primaryAction == .restoreSleep {
            return controller.displayedStatus.detail
        }
        return nil
    }

    @ViewBuilder
    private var recoveryAction: some View {
        if controller.primaryAction == .prepareHelper,
           controller.snapshot.helperPreparationCTA == .repair
                || controller.snapshot.restoreRequired
                || controller.operationPhase == .recoveryRequired {
            Button {
                controller.prepareHelper()
            } label: {
                Label("Repair Helper", systemImage: "shield.lefthalf.filled")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(
                controller.isBusy
                    || controller.isChecking
                    || !controller.snapshot.canPrepareHelper
                    || !controller.snapshot.sleepDisabledVerified
            )
            .accessibilityHint(controller.snapshot.helperPreparationCTA.accessibilityHint)
        } else if controller.primaryAction == .restoreSleep {
            Button {
                controller.restoreNow()
            } label: {
                Label("Restore Sleep", systemImage: "moon.zzz.fill")
            }
            .buttonStyle(.bordered)
            .disabled(controller.isBusy)
            .accessibilityHint("Clears the remaining system sleep override and verifies that normal sleep is restored.")
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Menu {
                Text(controller.snapshot.systemSummary)
                Text(controller.displayedStatus.detail)
                Divider()

                Button {
                    controller.refreshManually()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(controller.isBusy || controller.isChecking)
                .accessibilityHint("Reads the current power source, helper status, and system sleep override.")

                if controller.snapshot.helperArtifactsPresent || controller.snapshot.helperLoaded {
                    Divider()
                    Button(role: .destructive) {
                        confirmationPresenter.present(.removeHelper) { controller.uninstallHelper() }
                    } label: {
                        Label("Remove Helper…", systemImage: "trash")
                    }
                    .disabled(controller.isBusy || controller.isChecking)
                    .accessibilityHint("Asks for confirmation, restores system sleep, and removes LidSwitch helper files.")
                }
            } label: {
                utilityRow("Options", symbol: "gearshape", showsChevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityHint("Shows technical status, Refresh, and helper removal.")

            Button {
                controller.quitSafely()
            } label: {
                utilityRow("Quit", symbol: "power", showsChevron: false)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy && controller.operationPhase != .starting)
            .keyboardShortcut("q", modifiers: [.command])
            .accessibilityLabel("Restore and quit LidSwitch")
            .accessibilityHint("Verifies that system sleep is restored before quitting.")
        }
    }

    private func utilityRow(_ title: String, symbol: String, showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var progressAccessibilityLabel: String {
        if controller.isCancelRestoring {
            return "Canceling and restoring LidSwitch session"
        }
        if controller.isEndingRestoring {
            return "Ending and restoring LidSwitch session"
        }
        if controller.operationPhase == .preparingHelper {
            return "Preparing the LidSwitch helper safely"
        }
        if controller.operationPhase == .removingHelper {
            return "Removing the LidSwitch helper safely"
        }
        if controller.snapshot.installationInventoryPending {
            return "Checking LidSwitch installation"
        }
        if controller.isChecking {
            return "Checking current macOS state"
        }
        return "LidSwitch operation in progress"
    }

    private var statusColor: Color {
        switch controller.displayedStatus.tone {
        case .warning:
            return .orange
        case .active:
            return .green
        case .progress, .neutral:
            return .secondary
        }
    }
}
