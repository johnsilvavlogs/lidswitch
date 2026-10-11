import AppKit
import SwiftUI

struct LidSwitchPanel: View {
    @ObservedObject var controller: PowerController
    let confirmationPresenter: NativeConfirmationPresenter
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @State private var powerSourcesExpanded = false
    @State private var disclosureInitialized = false
    @FocusState private var masterHasFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            masterCard
            powerSourceDisclosure
            Divider()
            controls
        }
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if !disclosureInitialized {
                powerSourcesExpanded = controller.isKeepAwakeOn || noPowerSourceSelected
                disclosureInitialized = true
            }
            // Opening the panel refreshes live power and safety truth.
            controller.refresh()
        }
        .onChange(of: noPowerSourceSelected) { empty in
            if empty { powerSourcesExpanded = true }
        }
    }

    private var header: some View {
        Text("LidSwitch")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            keepAwakeSwitch

            statusBlock
                .padding(.leading, 30)

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
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keepAwakeSwitch: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text("Keep Mac awake")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle("Keep Mac awake", isOn: Binding(
                get: { controller.isKeepAwakeOn },
                set: { enabled in
                    if enabled {
                        powerSourcesExpanded = true
                    } else if !noPowerSourceSelected {
                        // Explicit OFF may hide a focused source control.
                        masterHasFocus = true
                        powerSourcesExpanded = false
                    }
                    controller.setKeepAwakeEnabled(enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .focused($masterHasFocus)
            .disabled(!canChangeKeepAwake)
            .keyboardShortcut("k", modifiers: [.command])
            .accessibilityHint(
                controller.operationPhase == .starting
                    ? "Turn off to cancel the pending start and restore system sleep."
                    : "Keeps this Mac awake on the selected power sources. Turn off to restore system sleep."
            )
        }
        .frame(minHeight: 28)
    }

    private var statusBlock: some View {
        HStack(alignment: .top, spacing: 6) {
            statusIndicator
                .frame(width: 12, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.displayedStatus.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)

                Text(controller.snapshot.source.title)
                    .font(.system(size: 12))
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
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
    }

    private var noPowerSourceSelected: Bool {
        !controller.powerPreferences.allowPluggedInKeepAwake
            && !controller.powerPreferences.allowBatteryKeepAwake
    }

    private var powerSourceSummary: String {
        switch (controller.powerPreferences.allowPluggedInKeepAwake,
                controller.powerPreferences.allowBatteryKeepAwake) {
        case (true, true): "Plugged in and on battery"
        case (true, false): "Plugged in only"
        case (false, true): "Battery only"
        case (false, false): "None selected"
        }
    }

    private var powerSourceDisclosure: some View {
        DisclosureGroup(isExpanded: $powerSourcesExpanded) {
            powerSourceControls
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text("Power sources")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                Text(powerSourceSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityHint("Saved preferences. Expand to choose when Keep Mac awake applies.")
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
                .padding(.leading, 42)
                .padding(.trailing, 12)

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
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .accessibilityHint(hint)
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 12)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(
                accessibilityContrast == .increased ? 1 : 0.35
            ))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        accessibilityContrast == .increased
                            ? Color.primary.opacity(0.45)
                            : Color(nsColor: .separatorColor).opacity(0.3),
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
            return "Choose a power source."
        }
        switch controller.operationPhase {
        case .starting:
            return "Turn off to cancel."
        case .cancelRestoring, .endingRestoring:
            return nil
        case .preparingHelper:
            return "Approve the macOS request to continue."
        case .removingHelper:
            return nil
        case .idle, .recoveryRequired:
            break
        }
        if controller.primaryAction == .prepareHelper,
           controller.snapshot.helperPreparationCTA == .prepare,
           canChangeKeepAwake {
            return "Turn on to set up. macOS requires administrator approval."
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
        HStack(spacing: 12) {
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
                Label("Options", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityHint("Shows technical status, Refresh, and helper removal.")

            Spacer(minLength: 0)
            Button {
                controller.quitSafely()
            } label: {
                Text("Quit")
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy && controller.operationPhase != .starting)
            .keyboardShortcut("q", modifiers: [.command])
            .accessibilityLabel("Restore and quit LidSwitch")
            .accessibilityHint("Verifies that system sleep is restored before quitting.")
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
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
