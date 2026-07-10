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

            if controller.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("LidSwitch operation in progress")
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)

                Text(controller.isStarting ? "Starting and verifying…" : controller.snapshot.statusTitle)
                    .font(.subheadline.weight(.semibold))
            }

            Text(controller.isStarting
                 ? "LidSwitch is checking current power, issuing a monitored lease, and waiting for the helper to verify the system sleep override."
                 : controller.snapshot.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(controller.snapshot.systemSummary, systemImage: "moon.zzz")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.isStarting
                            ? "Starting and verifying LidSwitch session. Protection is not active yet."
                            : controller.snapshot.accessibilityState)
        .accessibilityValue(controller.snapshot.systemSummary)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if controller.isStarting {
            Button {} label: {
                Label("Starting and verifying…", systemImage: "clock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .accessibilityLabel("Starting and verifying LidSwitch session")
        } else if controller.snapshot.sessionActive || controller.snapshot.sessionPending {
            Button {
                controller.stopSession()
            } label: {
                Label("Stop and Restore", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(controller.isBusy)
            .accessibilityLabel("Stop and restore system sleep")
            .accessibilityHint("Ends this session, stops lease renewal, and verifies that the sleep override is off.")
        } else if controller.snapshot.restoreRequired {
            Button {
                controller.restoreNow()
            } label: {
                Label("Restore Sleep", systemImage: "moon.zzz.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(controller.isBusy)
            .accessibilityHint("Clears the remaining system sleep override with administrator approval.")
        } else if !controller.snapshot.helperReady || controller.snapshot.legacyResiduePresent {
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
            .disabled(controller.isBusy || !controller.snapshot.canStartSession)
            .accessibilityLabel("Start plugged-in session")
            .accessibilityHint("Asks for confirmation, then starts one monitored session only while this Mac remains plugged in and LidSwitch stays open.")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                controller.refresh()
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
                .disabled(controller.isBusy)
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
        if controller.isStarting { return "clock.fill" }
        if controller.snapshot.hasCriticalSafetyIssue {
            return "exclamationmark.triangle.fill"
        }
        if controller.snapshot.sessionActive {
            return "checkmark.circle.fill"
        }
        if controller.snapshot.sessionPending {
            return "clock.fill"
        }
        return "circle"
    }

    private var statusColor: Color {
        if controller.isStarting { return .yellow }
        if controller.snapshot.hasCriticalSafetyIssue {
            return .orange
        }
        if controller.snapshot.sessionActive {
            return .green
        }
        if controller.snapshot.sessionPending {
            return .yellow
        }
        return .secondary
    }
}
