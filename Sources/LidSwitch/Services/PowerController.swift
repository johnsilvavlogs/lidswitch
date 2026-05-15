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
        if snapshot.desiredEnabled && snapshot.source.isAC && snapshot.sleepDisabled {
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
        guard !isBusy else {
            return
        }

        let helperInstalled = snapshot.helperInstalled
        let sleepDisabled = snapshot.sleepDisabled

        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                if enabled {
                    if helperInstalled {
                        try DesiredStateStore.write(true)
                    } else {
                        try PrivilegedHelperManager.install(initiallyEnabled: true)
                    }
                } else {
                    try DesiredStateStore.write(false)
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
        setEnabled(true)
    }

    func restoreNow() {
        guard !isBusy else {
            return
        }

        isBusy = true
        errorMessage = nil

        Task.detached {
            do {
                try DesiredStateStore.write(false)
                try PrivilegedHelperManager.restoreSleepNow()
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
                try PrivilegedHelperManager.uninstall()
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
