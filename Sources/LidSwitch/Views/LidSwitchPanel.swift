import SwiftUI

struct LidSwitchPanel: View {
    @ObservedObject var controller: PowerController
    let confirmationPresenter: NativeConfirmationPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusBlock
            primaryAction

            if let errorMessage = controller.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error. \(errorMessage)")
            }

            Divider()
            controls
        }
        .padding(18)
        .onAppear {
            // Opening the menu publishes live power/safety truth immediately,
            // then reuses or refreshes the bounded installation inventory.
            controller.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.menuBarSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("LidSwitch")
                    .font(.headline)

                Text(controller.snapshot.source.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if controller.isBusy || controller.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(progressAccessibilityLabel)
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)

                Text(controller.displayedStatus.title)
                    .font(.subheadline.weight(.semibold))
            }

            Text(controller.displayedStatus.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(controller.snapshot.systemSummary, systemImage: "moon.zzz")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.displayedStatus.accessibilityState)
        .accessibilityValue(controller.snapshot.systemSummary)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if controller.primaryAction == .cancelStart {
            Button {
                controller.cancelPendingStart()
            } label: {
                Label("Cancel and Restore", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .accessibilityLabel("Cancel pending session and restore system sleep")
            .accessibilityHint("Cancels the pending start. Protection may not yet be active.")
        } else if controller.primaryAction == .stopAndRestore {
            Button {
                controller.stopSession()
            } label: {
                Label("Stop and Restore", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(controller.isBusy && !controller.isCancelRestoring)
            .accessibilityLabel("Stop and restore system sleep")
            .accessibilityHint("Ends this session, stops lease renewal, and verifies that the sleep override is off.")
        } else if controller.primaryAction == .restoreSleep {
            Button {
                controller.restoreNow()
            } label: {
                Label("Restore Sleep", systemImage: "moon.zzz.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(controller.isBusy && !controller.isCancelRestoring)
            .accessibilityHint("Clears the remaining system sleep override with administrator approval.")
        } else if controller.primaryAction == .cancelRestoringProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Canceling and restoring…")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(controller.displayedStatus.accessibilityState)
        } else if controller.primaryAction == .endingRestoringProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Ending and restoring…")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(controller.displayedStatus.accessibilityState)
        } else if controller.primaryAction == .preparingHelperProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing safe helper…")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(controller.displayedStatus.accessibilityState)
        } else if controller.primaryAction == .removingHelperProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Removing helper…")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(controller.displayedStatus.accessibilityState)
        } else if controller.primaryAction == .prepareHelper {
            Button {
                controller.prepareHelper()
            } label: {
                Label("Prepare Safe Helper", systemImage: "shield.lefthalf.filled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(
                controller.isBusy
                    || controller.isChecking
                    || !controller.snapshot.canPrepareHelper
                    || !controller.snapshot.sleepDisabledVerified
            )
            .accessibilityHint("Removes old startup behavior and installs the crash-safe on-demand helper. Protection stays off.")
        } else {
            Button {
                confirmationPresenter.present(.startSession) { controller.startSession() }
            } label: {
                Label("Start Plugged-In Session", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(controller.isBusy || controller.isChecking || !controller.snapshot.canStartSession)
            .accessibilityLabel("Start plugged-in session")
            .accessibilityHint("Asks for confirmation, then starts one monitored session only while this Mac remains plugged in and LidSwitch stays open.")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                controller.refreshManually()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Refresh power and helper state")
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(controller.isBusy)
            .accessibilityLabel("Refresh LidSwitch state")
            .accessibilityHint("Reads the current power source, helper status, and system sleep override.")

            Spacer()

            if controller.snapshot.helperArtifactsPresent || controller.snapshot.helperLoaded {
                Button(role: .destructive) {
                    confirmationPresenter.present(.removeHelper) { controller.uninstallHelper() }
                } label: {
                    Label("Remove Helper", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(controller.isBusy || controller.isChecking)
                .accessibilityHint("Asks for confirmation, restores system sleep, and removes LidSwitch helper files.")
            }

            Button {
                confirmationPresenter.present(.quit) { controller.quitSafely() }
            } label: {
                Label("Quit", systemImage: "power")
            }
            .controlSize(.small)
            .disabled(controller.isBusy)
            .keyboardShortcut("q", modifiers: [.command])
            .accessibilityLabel("Restore and quit LidSwitch")
            .accessibilityHint("Asks for confirmation and verifies system sleep is restored before quitting.")
        }
    }

    private var statusSymbol: String {
        controller.displayedStatus.panelSymbol
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
        case .progress:
            return .yellow
        case .neutral:
            return .secondary
        }
    }
}
