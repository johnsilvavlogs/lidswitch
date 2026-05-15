import SwiftUI

struct LidSwitchPanel: View {
    @ObservedObject var controller: PowerController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            enableToggle
            batteryToggle
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

                Text(controller.snapshot.batteryKeepAwakeEnabled ? "AC and battery allowed." : "Battery sleep stays normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Keep awake on power")
        .accessibilityHint(enableToggleHint)
        .accessibilityValue(controller.snapshot.desiredEnabled ? "On" : "Off")
        .keyboardShortcut("k", modifiers: [.command])
        .disabled(controller.isBusy)
    }

    private var batteryToggle: some View {
        Toggle(
            isOn: Binding(
                get: { controller.snapshot.batteryKeepAwakeEnabled },
                set: { controller.setBatteryEnabled($0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow on battery")
                    .font(.subheadline.weight(.medium))

                Text(batteryToggleDetail)
                    .font(.caption)
                    .foregroundStyle(controller.snapshot.batteryKeepAwakeEnabled ? .orange : .secondary)
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Allow on battery")
        .accessibilityHint(batteryToggleHint)
        .accessibilityValue(controller.snapshot.batteryKeepAwakeEnabled ? "On" : "Off")
        .disabled(controller.isBusy || !controller.snapshot.desiredEnabled)
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
                if let batterySleep = controller.snapshot.batteryIdleSleepMinutes {
                    Label("Battery \(batterySleep == 0 ? "never" : "\(batterySleep)m")", systemImage: "battery.100percent")
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
            } else if controller.snapshot.helperNeedsUpdate {
                Button {
                    controller.updateHelper()
                } label: {
                    Label("Update Helper", systemImage: "arrow.triangle.2.circlepath")
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
        if controller.snapshot.helperInstalled && controller.snapshot.helperNeedsUpdate {
            return .orange
        }

        if controller.snapshot.desiredEnabled && controller.snapshot.batteryKeepAwakeEnabled && controller.snapshot.sleepDisabled {
            return controller.snapshot.source.isAC ? .green : .orange
        }

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

    private var batteryToggleDetail: String {
        if !controller.snapshot.desiredEnabled {
            return "Turn on keep-awake first."
        }

        if controller.snapshot.batteryKeepAwakeEnabled {
            return "Risk: battery can drain with the lid closed."
        }

        return "Off unless you explicitly allow it."
    }

    private var enableToggleHint: String {
        if controller.snapshot.batteryKeepAwakeEnabled {
            return "Prevents lid-close sleep while connected to power and while running on battery."
        }

        return "Prevents lid-close sleep while connected to power. Battery sleep stays normal."
    }

    private var batteryToggleHint: String {
        if !controller.snapshot.desiredEnabled {
            return "Turn on Keep awake on power before allowing battery mode."
        }

        return "Allows LidSwitch to prevent lid-close sleep while running from battery power."
    }
}
