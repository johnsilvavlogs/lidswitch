import SwiftUI

struct LidSwitchPanel: View {
    @ObservedObject var controller: PowerController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            enableToggle
            statusBlock

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                .foregroundStyle(controller.snapshot.desiredEnabled ? .green : .secondary)
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
        }
    }

    private var enableToggle: some View {
        Toggle(
            isOn: Binding(
                get: { controller.snapshot.desiredEnabled },
                set: { controller.setEnabled($0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep awake on power")
                    .font(.subheadline.weight(.medium))

                Text("Battery sleep stays normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Keep awake on power")
        .accessibilityHint("Prevents lid-close sleep while connected to power. Battery sleep stays normal.")
        .accessibilityValue(controller.snapshot.desiredEnabled ? "On" : "Off")
        .keyboardShortcut("k", modifiers: [.command])
        .disabled(controller.isBusy)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(controller.snapshot.statusTitle)
                    .font(.subheadline.weight(.medium))

                Spacer()

                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(controller.snapshot.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label(controller.snapshot.sleepDisabled ? "SleepDisabled on" : "SleepDisabled off", systemImage: "moon")
                if let acSleep = controller.snapshot.acIdleSleepMinutes {
                    Label("AC sleep \(acSleep == 0 ? "never" : "\(acSleep)m")", systemImage: "powerplug")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
            .help("Refresh power state")
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(controller.isBusy)

            Spacer()

            if !controller.snapshot.helperInstalled {
                Button {
                    controller.installHelper()
                } label: {
                    Label("Install Helper", systemImage: "plus.circle")
                }
                .controlSize(.small)
                .disabled(controller.isBusy)
            }

            if controller.snapshot.sleepDisabled {
                Button {
                    controller.restoreNow()
                } label: {
                    Label("Restore", systemImage: "moon.zzz")
                }
                .controlSize(.small)
                .disabled(controller.isBusy)
            }

            if controller.snapshot.helperInstalled {
                Button(role: .destructive) {
                    controller.uninstallHelper()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(controller.isBusy)
            }
        }
    }

    private var statusColor: Color {
        if controller.snapshot.desiredEnabled && controller.snapshot.source.isAC && controller.snapshot.sleepDisabled {
            return .green
        }

        if controller.snapshot.desiredEnabled {
            return .yellow
        }

        if controller.snapshot.sleepDisabled {
            return .orange
        }

        return .secondary
    }
}
