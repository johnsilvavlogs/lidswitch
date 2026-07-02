import Combine
import Foundation

@MainActor
final class PowerController: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot = .empty
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    var menuBarSymbol: String {
        if snapshot.desiredEnabled && snapshot.sleepDisabled {
            return "bolt.circle.fill"
        }

        if snapshot.desiredEnabled {
            return "bolt.circle"
        }

        return "power.circle"
    }

    func refresh() {
        snapshot = PowerInspector.snapshot()
    }

    func setEnabled(_ enabled: Bool) {
        applyPreferences(snapshot.preferences.withKeepAwakeEnabled(enabled))
    }

    func setBatteryEnabled(_ enabled: Bool) {
        applyPreferences(snapshot.preferences.withBatteryKeepAwakeAllowed(enabled))
    }

    func updateHelper() {
        guard !isBusy else {
            return
        }

        let preferences = snapshot.preferences

        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                try HelperLifecycleDesiredState.performAfterBestEffortWrite(preferences) {
                    try PrivilegedHelperManager.install(initialPreferences: preferences)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                }
            } catch {
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription.isEmpty
                        ? "Helper update did not complete."
                        : error.localizedDescription
                }
            }
        }
    }

    private func applyPreferences(_ preferences: PowerPreferences) {
        guard !isBusy else {
            return
        }

        let helperInstalled = snapshot.helperInstalled
        let helperNeedsUpdate = snapshot.helperNeedsUpdate
        let sleepDisabled = snapshot.sleepDisabled

        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                try DesiredStateStore.write(preferences)
                if preferences.keepAwakeEnabled {
                    if !helperInstalled || helperNeedsUpdate {
                        try PrivilegedHelperManager.install(initialPreferences: preferences)
                    }
                } else {
                    if !helperInstalled && sleepDisabled {
                        try PrivilegedHelperManager.restoreSleepNow()
                    }
                }

                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                }
            } catch {
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription.isEmpty
                        ? "The operation did not complete."
                        : error.localizedDescription
                }
            }
        }
    }

    func installHelper() {
        applyPreferences(snapshot.preferences.withKeepAwakeEnabled(true))
    }

    func restoreNow() {
        guard !isBusy else {
            return
        }

        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                try HelperLifecycleDesiredState.performAfterBestEffortWrite(.disabled) {
                    try PrivilegedHelperManager.restoreSleepNow()
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                }
            } catch {
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription.isEmpty
                        ? "Restore did not complete."
                        : error.localizedDescription
                }
            }
        }
    }

    func uninstallHelper() {
        guard !isBusy else {
            return
        }

        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                try HelperLifecycleDesiredState.performAfterBestEffortWrite(.disabled) {
                    try PrivilegedHelperManager.uninstall()
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                }
            } catch {
                let nextSnapshot = PowerInspector.snapshot()
                await MainActor.run {
                    self.snapshot = nextSnapshot
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription.isEmpty
                        ? "Uninstall did not complete."
                        : error.localizedDescription
                }
            }
        }
    }
}
