import AppKit
import SwiftUI

struct LidSwitchPanel: View {
    @ObservedObject var controller: PowerController
    let confirmationPresenter: NativeConfirmationPresenter
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @State private var powerSourcesExpanded = false
    @State private var disclosureInitialized = false

    private var presentation: LidSwitchPanelPresentation {
        LidSwitchPanelPresentation(controller: controller)
    }

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
                powerSourcesExpanded = noPowerSourceSelected
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
            } else if let guidance = presentation.guidance {
                Text(guidance)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inlineAction
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
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
                set: { controller.setKeepAwakeEnabled($0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Keep Mac awake")
            .toggleStyle(.switch)
            .controlSize(.regular)
            .disabled(!presentation.masterEnabled)
            .keyboardShortcut(presentation.masterEnabled
                ? KeyboardShortcut("k", modifiers: [.command]) : nil)
            .accessibilityHint(presentation.masterHint)
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
            VStack(alignment: .leading, spacing: 6) {
                powerSourceControls
                Text("Choices are saved. Keep Mac awake starts off after launch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .disabled(!presentation.sourceChoicesEnabled)
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
                .accessibilityLabel(title)
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

    @ViewBuilder
    private var inlineAction: some View {
        if let action = presentation.inlineAction {
            Button {
                switch action.kind {
                case .prepareHelper: controller.prepareHelper()
                case .restoreSleep: controller.restoreNow()
                case .refresh: controller.refreshManually()
                }
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .buttonStyle(.bordered)
            .disabled(!action.isEnabled)
            .keyboardShortcut(shortcut(for: action))
            .accessibilityHint(action.hint)
        }
    }

    private func shortcut(for action: LidSwitchPanelPresentation.Action) -> KeyboardShortcut? {
        switch action.kind {
        case .prepareHelper: KeyboardShortcut("p", modifiers: [.command])
        case .refresh: KeyboardShortcut("r", modifiers: [.command])
        case .restoreSleep: presentation.commandKRestoresSleep
            ? KeyboardShortcut("k", modifiers: [.command]) : nil
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Text(controller.snapshot.systemSummary)
                Text(controller.displayedStatus.detail)
                Divider()

                // The visible inline Refresh owns Command-R when present.
                if presentation.inlineAction?.kind != .refresh {
                    Button {
                        controller.refreshManually()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(controller.isBusy || controller.isChecking)
                    .accessibilityHint("Reads the current power source, helper status, and system sleep override.")
                }

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
            .accessibilityHint(presentation.inlineAction?.kind == .refresh
                ? "Shows technical status and helper removal."
                : "Shows technical status, Refresh, and helper removal.")

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
