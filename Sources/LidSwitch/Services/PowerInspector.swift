import Darwin
import Foundation
import IOKit
import LidSwitchCore

enum PowerInspector {
    enum InspectionPolicy: Equatable, Sendable { case reuseIfFresh, forceFresh }

    enum LaunchdPresence: Equatable, Sendable {
        case present
        case absent
        case indeterminate
    }

    enum InstallationInventoryState: Equatable, Sendable {
        case pending
        case valid
        case invalid(String)
        case indeterminate(String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        var isPending: Bool {
            if case .pending = self { return true }
            return false
        }
    }

    struct BundleValidationResult: Equatable, Sendable {
        let integrity: Bool
        let version: Bool
        let codesignExitCode: Int32?
        let indeterminate: Bool

        init(
            integrity: Bool,
            version: Bool,
            codesignExitCode: Int32?,
            indeterminate: Bool = false
        ) {
            self.integrity = integrity
            self.version = version
            self.codesignExitCode = codesignExitCode
            self.indeterminate = indeterminate
        }
    }

    private static let powerManagementDomain = "com.apple.PowerManagement"
    private static let installationInventoryTTL: TimeInterval = 60

    struct InstallationInventory: Equatable, Sendable {
        let state: InstallationInventoryState
        let fingerprint: [String]
        let staticArtifactsPresent: Bool
        let helperLaunchd: LaunchdPresence
        let legacyLaunchd: LaunchdPresence
        let bundleIntegrityValid: Bool
        let bundleVersionValid: Bool
        let checkedAt: Date

        static let pending = InstallationInventory(
            state: .pending,
            fingerprint: [],
            staticArtifactsPresent: false,
            helperLaunchd: .indeterminate,
            legacyLaunchd: .indeterminate,
            bundleIntegrityValid: false,
            bundleVersionValid: false,
            checkedAt: .distantPast
        )
    }

    struct DynamicResidue: Equatable, Sendable {
        let appliedState: String
        let helperStatus: String
        let originalAC: String
        let originalBattery: String
        let legacyRoot: String
        let legacyLogin: String

        var hasAnyResidue: Bool { [appliedState, helperStatus, originalAC, originalBattery, legacyRoot, legacyLogin].contains { !$0.hasSuffix(":missing") } }
        var legacyRootPresent: Bool { !legacyRoot.hasSuffix(":missing") }
        var legacyLoginPresent: Bool { !legacyLogin.hasSuffix(":missing") }
    }

    struct DynamicSnapshotDependencies: Sendable {
        let dynamicPaths: (appliedState: String, helperStatus: String, originalAC: String, originalBattery: String, legacyRoot: String, legacyLogin: String)
        let source: @Sendable () -> PowerSource
        let sleepDisabled: @Sendable () -> Bool?
        let acIdleSleep: @Sendable () -> Int?
        let preferences: @Sendable () -> DesiredStateStore.ReadResult
        let systemBuild: @Sendable () -> String?
        let activationLease: @Sendable (String?) -> ActivationLeaseStore.ReadResult
        let helperStatus: @Sendable () -> HelperStatusRecord?
        let dynamicMetadata: @Sendable (String) -> String
        let now: @Sendable () -> Date
    }

    final class DynamicSnapshotEngine: @unchecked Sendable {
        private let dependencies: DynamicSnapshotDependencies

        init(dependencies: DynamicSnapshotDependencies) {
            self.dependencies = dependencies
        }

        func snapshot(ownedSessionID: UUID?, inventory: InstallationInventory) -> PowerSnapshot {
            BenchmarkProbe.record("dynamic_snapshot")
            let source = dependencies.source()
            let sleepDisabled = dependencies.sleepDisabled()
            let systemBuild = dependencies.systemBuild()
            let paths = dependencies.dynamicPaths
            let residue = DynamicResidue(
                appliedState: dependencies.dynamicMetadata(paths.appliedState),
                helperStatus: dependencies.dynamicMetadata(paths.helperStatus),
                originalAC: dependencies.dynamicMetadata(paths.originalAC),
                originalBattery: dependencies.dynamicMetadata(paths.originalBattery),
                legacyRoot: dependencies.dynamicMetadata(paths.legacyRoot),
                legacyLogin: dependencies.dynamicMetadata(paths.legacyLogin)
            )
            let legacyLaunchdPresent = inventory.legacyLaunchd == .present
            let artifactsPresent = inventory.staticArtifactsPresent || residue.hasAnyResidue || legacyLaunchdPresent
            let helperNeedsUpdate = artifactsPresent && (
                (!inventory.state.isPending && !inventory.state.isValid)
                    || residue.legacyRootPresent
                    || residue.legacyLoginPresent
                    || legacyLaunchdPresent
            )

            let desired = dependencies.preferences()
            let lease = dependencies.activationLease(systemBuild)
            return PowerSnapshot(
                source: source,
                sleepDisabled: sleepDisabled ?? false,
                sleepDisabledVerified: sleepDisabled != nil,
                acIdleSleepMinutes: dependencies.acIdleSleep(),
                preferences: PowerInspector.resolvedPreferences(desired),
                desiredStateTruth: PowerInspector.desiredStateTruth(desired),
                helperArtifactsPresent: artifactsPresent,
                helperLoaded: inventory.helperLaunchd == .present,
                helperNeedsUpdate: helperNeedsUpdate,
                legacyLoginItemPresent: residue.legacyLoginPresent,
                legacyLoginItemLoaded: legacyLaunchdPresent,
                activationLease: PowerInspector.resolvedLease(lease),
                activationLeaseTruth: PowerInspector.activationLeaseTruth(lease),
                activationLeaseRecoveredLegacyEvidence: PowerInspector.hasRecognizedLegacyLeaseArchive(lease),
                staleCanonicalLegacyLeasePresent: PowerInspector.hasStaleCanonicalLegacyLease(lease),
                ownedSessionID: ownedSessionID,
                helperStatus: dependencies.helperStatus(),
                systemBuild: systemBuild,
                systemBuildQualified: systemBuild.map(CompatibilityPolicy.isQualified) ?? false,
                bundleIntegrityValid: inventory.bundleIntegrityValid,
                bundleVersionValid: inventory.bundleVersionValid,
                checkedAt: dependencies.now(),
                installationInventoryState: inventory.state,
                helperLaunchdState: inventory.helperLaunchd,
                legacyLaunchdState: inventory.legacyLaunchd
            )
        }
    }

    struct InstallationInventoryCollection: Equatable, Sendable {
        let staticArtifactsPresent: Bool
        let staticValidationValid: Bool
        let helperLaunchd: LaunchdPresence
        let legacyLaunchd: LaunchdPresence
        let bundleValidation: BundleValidationResult
    }

    struct InstallationInventoryDependencies: Sendable {
        let fingerprintPaths: [String]
        let installedArtifactPathCount: Int
        let now: @Sendable () -> Date
        let staticMetadata: @Sendable (String) -> String
        let collect: @Sendable ([String]) -> InstallationInventoryCollection

        init(
            fingerprintPaths: [String],
            installedArtifactPathCount: Int? = nil,
            now: @escaping @Sendable () -> Date,
            staticMetadata: @escaping @Sendable (String) -> String,
            collect: @escaping @Sendable ([String]) -> InstallationInventoryCollection
        ) {
            self.fingerprintPaths = fingerprintPaths
            self.installedArtifactPathCount = min(
                fingerprintPaths.count,
                max(0, installedArtifactPathCount ?? fingerprintPaths.count)
            )
            self.now = now
            self.staticMetadata = staticMetadata
            self.collect = collect
        }
    }

    enum InstallationInventoryRejection: Equatable, Sendable {
        case superseded
        case drift
    }

    struct InstallationInventoryRequestResult: Equatable, Sendable {
        let generation: UInt64
        let rejection: InstallationInventoryRejection?
        let inventory: InstallationInventory

        var accepted: Bool { rejection == nil }
    }

    final class InstallationInventoryEngine: @unchecked Sendable {
        private let dependencies: InstallationInventoryDependencies
        private let ttl: TimeInterval
        private let queue: DispatchQueue
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var cached: InstallationInventory?
        private var published: InstallationInventory = .pending
        private var pendingFingerprint: [String]?

        init(
            dependencies: InstallationInventoryDependencies,
            ttl: TimeInterval = PowerInspector.installationInventoryTTL,
            queue: DispatchQueue = DispatchQueue(label: "com.johnsilva.LidSwitch.installation-inventory", qos: .utility)
        ) {
            self.dependencies = dependencies
            self.ttl = ttl
            self.queue = queue
        }

        func current() -> InstallationInventory {
            let fingerprint = makeFingerprint()
            let now = dependencies.now()
            lock.lock()
            if let cached,
               cached.fingerprint == fingerprint,
               now.timeIntervalSince(cached.checkedAt) >= 0,
               now.timeIntervalSince(cached.checkedAt) < ttl
            {
                let result = cached
                lock.unlock()
                return result
            }
            if pendingFingerprint != fingerprint {
                generation &+= 1
                cached = nil
                published = pendingInventory(fingerprint: fingerprint)
                pendingFingerprint = fingerprint
                BenchmarkProbe.record("installation_inventory_drift_invalidated")
            }
            let result = published
            lock.unlock()
            return result
        }

        func invalidate() {
            lock.lock()
            generation &+= 1
            cached = nil
            published = .pending
            pendingFingerprint = nil
            lock.unlock()
            BenchmarkProbe.record("installation_inventory_invalidated")
        }

        @discardableResult
        func request(
            policy: InspectionPolicy,
            completion: @escaping @Sendable (InstallationInventoryRequestResult) -> Void
        ) -> UInt64 {
            let fingerprint = makeFingerprint()
            let requestGeneration: UInt64
            lock.lock()
            generation &+= 1
            requestGeneration = generation
            let now = dependencies.now()
            let prior = cached
            if case .reuseIfFresh = policy,
               let cached,
               cached.fingerprint == fingerprint,
               now.timeIntervalSince(cached.checkedAt) >= 0,
               now.timeIntervalSince(cached.checkedAt) < ttl
            {
                published = cached
                pendingFingerprint = nil
                lock.unlock()
                BenchmarkProbe.record("installation_inventory_static_hit")
                queue.async { [self] in
                    // A cache hit is still a publication. Re-evaluate its
                    // fingerprint/TTL at delivery time so a queued callback
                    // cannot outlive drift, force-fresh, or invalidation.
                    _ = current()
                    completion(publish(cached, generation: requestGeneration))
                }
                return requestGeneration
            }
            let miss = prior == nil ? "installation_inventory_static_miss_cold" :
                (prior?.fingerprint == fingerprint ? "installation_inventory_static_miss_expired" : "installation_inventory_static_miss_drift")
            cached = nil
            published = pendingInventory(fingerprint: fingerprint)
            pendingFingerprint = fingerprint
            lock.unlock()
            BenchmarkProbe.record(miss)

            queue.async { [self] in
                let before = makeFingerprint()
                BenchmarkProbe.record("inspection_artifact_validation")
                let collection = dependencies.collect(before)
                let after = makeFingerprint()
                guard before == after else {
                    completion(rejectDrift(generation: requestGeneration, fingerprint: after))
                    return
                }
                let candidate = makeInventory(collection: collection, fingerprint: before)
                let result = publish(candidate, generation: requestGeneration)
                completion(result)
            }
            return requestGeneration
        }

        func inspect(policy: InspectionPolicy) -> InstallationInventory {
            let fingerprint = makeFingerprint()
            lock.lock()
            generation &+= 1
            let requestGeneration = generation
            let now = dependencies.now()
            let prior = cached
            if case .reuseIfFresh = policy,
               let cached,
               cached.fingerprint == fingerprint,
               now.timeIntervalSince(cached.checkedAt) >= 0,
               now.timeIntervalSince(cached.checkedAt) < ttl
            {
                published = cached
                pendingFingerprint = nil
                lock.unlock()
                BenchmarkProbe.record("installation_inventory_static_hit")
                return cached
            }
            cached = nil
            published = pendingInventory(fingerprint: fingerprint)
            pendingFingerprint = fingerprint
            lock.unlock()
            if policy == .forceFresh {
                BenchmarkProbe.record("installation_inventory_force_fresh")
            } else if prior == nil {
                BenchmarkProbe.record("installation_inventory_static_miss_cold")
            } else if prior?.fingerprint == fingerprint {
                BenchmarkProbe.record("installation_inventory_static_miss_expired")
            } else {
                BenchmarkProbe.record("installation_inventory_static_miss_drift")
            }
            BenchmarkProbe.record("inspection_artifact_validation")
            let before = makeFingerprint()
            let collection = dependencies.collect(before)
            let after = makeFingerprint()
            let candidate = before == after
                ? makeInventory(collection: collection, fingerprint: before)
                : InstallationInventory(
                    state: .indeterminate("Installation changed during inspection."),
                    fingerprint: after,
                    staticArtifactsPresent: collection.staticArtifactsPresent,
                    helperLaunchd: .indeterminate,
                    legacyLaunchd: .indeterminate,
                    bundleIntegrityValid: false,
                    bundleVersionValid: false,
                    checkedAt: dependencies.now()
                )
            return publish(candidate, generation: requestGeneration).inventory
        }

        private func makeFingerprint() -> [String] {
            dependencies.fingerprintPaths.map(dependencies.staticMetadata)
        }

        private func pendingInventory(fingerprint: [String]) -> InstallationInventory {
            InstallationInventory(
                state: .pending,
                fingerprint: fingerprint,
                staticArtifactsPresent: fingerprint.prefix(dependencies.installedArtifactPathCount)
                    .contains { !$0.hasSuffix(":missing") },
                helperLaunchd: .indeterminate,
                legacyLaunchd: .indeterminate,
                bundleIntegrityValid: false,
                bundleVersionValid: false,
                checkedAt: .distantPast
            )
        }

        private func makeInventory(
            collection: InstallationInventoryCollection,
            fingerprint: [String]
        ) -> InstallationInventory {
            let state: InstallationInventoryState
            if collection.helperLaunchd == .indeterminate || collection.legacyLaunchd == .indeterminate {
                state = .indeterminate("Launchd installation state is unavailable.")
            } else if collection.bundleValidation.indeterminate {
                state = .indeterminate("Application bundle validation is unavailable.")
            } else if !collection.bundleValidation.integrity || !collection.bundleValidation.version {
                state = .invalid("Application bundle validation failed.")
            } else if collection.legacyLaunchd == .present {
                state = .invalid("A legacy launchd service is still present.")
            } else if !collection.staticValidationValid || collection.helperLaunchd != .present {
                state = .invalid(collection.staticArtifactsPresent ? "Installed helper validation failed." : "The helper is not installed.")
            } else {
                state = .valid
            }
            return InstallationInventory(
                state: state,
                fingerprint: fingerprint,
                staticArtifactsPresent: collection.staticArtifactsPresent,
                helperLaunchd: collection.helperLaunchd,
                legacyLaunchd: collection.legacyLaunchd,
                bundleIntegrityValid: collection.bundleValidation.integrity,
                bundleVersionValid: collection.bundleValidation.version,
                checkedAt: dependencies.now()
            )
        }

        private func publish(
            _ candidate: InstallationInventory,
            generation requestGeneration: UInt64
        ) -> InstallationInventoryRequestResult {
            lock.lock()
            guard generation == requestGeneration else {
                let current = published
                lock.unlock()
                BenchmarkProbe.record("installation_inventory_stale_completion_rejected")
                return InstallationInventoryRequestResult(
                    generation: requestGeneration,
                    rejection: .superseded,
                    inventory: current
                )
            }
            cached = candidate
            published = candidate
            pendingFingerprint = nil
            lock.unlock()
            BenchmarkProbe.record("installation_inventory_published")
            return InstallationInventoryRequestResult(
                generation: requestGeneration,
                rejection: nil,
                inventory: candidate
            )
        }

        private func rejectDrift(
            generation requestGeneration: UInt64,
            fingerprint: [String]
        ) -> InstallationInventoryRequestResult {
            lock.lock()
            guard generation == requestGeneration else {
                let current = published
                lock.unlock()
                BenchmarkProbe.record("installation_inventory_stale_completion_rejected")
                return InstallationInventoryRequestResult(
                    generation: requestGeneration,
                    rejection: .superseded,
                    inventory: current
                )
            }
            generation &+= 1
            cached = nil
            published = pendingInventory(fingerprint: fingerprint)
            pendingFingerprint = fingerprint
            let current = published
            lock.unlock()
            BenchmarkProbe.record("installation_inventory_drift_rejected")
            return InstallationInventoryRequestResult(
                generation: requestGeneration,
                rejection: .drift,
                inventory: current
            )
        }
    }

    typealias InspectionEngine = InstallationInventoryEngine
    typealias InspectionDependencies = InstallationInventoryDependencies

    private static let productionDynamicSnapshotEngine = DynamicSnapshotEngine(dependencies: DynamicSnapshotDependencies(
        dynamicPaths: (AppPaths.rootAppliedStatePath, AppPaths.rootHelperStatusPath, AppPaths.rootOriginalACSleepPath, AppPaths.rootOriginalBatterySleepPath, AppPaths.legacyRootHelperPath, AppPaths.legacyLoginAgentFile.path),
        source: nativePowerSource,
        sleepDisabled: nativeSleepDisabled,
        acIdleSleep: nativeACIdleSleep,
        preferences: { DesiredStateStore.readPreferences() },
        systemBuild: SystemBuild.current,
        activationLease: validatedActivationLease,
        helperStatus: { helperStatus() },
        dynamicMetadata: structuralMetadataFingerprint,
        now: Date.init
    ))

    private static let productionInstallationInventoryEngine = InstallationInventoryEngine(dependencies: InstallationInventoryDependencies(
        fingerprintPaths: productionInventoryFingerprintPaths,
        installedArtifactPathCount: 3,
        now: Date.init,
        staticMetadata: staticMetadataFingerprint,
        collect: { fingerprint in
            let bundle = validateBundle(at: Bundle.main.bundleURL)
            return InstallationInventoryCollection(
                staticArtifactsPresent: fingerprint.prefix(3).contains { !$0.hasSuffix(":missing") },
                staticValidationValid: staticArtifactValidation(),
                helperLaunchd: helperLoadedState(),
                legacyLaunchd: legacyLoadedState(),
                bundleValidation: bundle
            )
        }
    ))

    private static var productionInventoryFingerprintPaths: [String] {
        [
            AppPaths.rootHelperPath,
            AppPaths.rootHelperVersionPath,
            AppPaths.launchDaemonPath,
            AppPaths.bundledHelperFile.path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist").path,
            Bundle.main.executableURL?.path ?? Bundle.main.bundleURL.path,
            Bundle.main.bundleURL.path,
        ]
    }

    static func snapshot(
        ownedSessionID: UUID? = nil,
        inspectionPolicy: InspectionPolicy = .reuseIfFresh
    ) -> PowerSnapshot {
        let inventory = productionInstallationInventoryEngine.inspect(policy: inspectionPolicy)
        return dynamicSnapshot(ownedSessionID: ownedSessionID, inventory: inventory)
    }

    static func dynamicSnapshot(
        ownedSessionID: UUID? = nil,
        inventory: InstallationInventory? = nil
    ) -> PowerSnapshot {
        productionDynamicSnapshotEngine.snapshot(
            ownedSessionID: ownedSessionID,
            inventory: inventory ?? productionInstallationInventoryEngine.current()
        )
    }

    static func rollbackDynamicSnapshot(ownedSessionID: UUID? = nil) -> PowerSnapshot {
        BenchmarkProbe.record("rollback_dynamic_snapshot")
        return productionDynamicSnapshotEngine.snapshot(
            ownedSessionID: ownedSessionID,
            inventory: .pending
        )
    }

    @discardableResult
    static func requestInstallationInventory(
        policy: InspectionPolicy,
        completion: @escaping @Sendable (InstallationInventoryRequestResult) -> Void
    ) -> UInt64 {
        productionInstallationInventoryEngine.request(policy: policy, completion: completion)
    }

    static func invalidateInstallationInventory() {
        productionInstallationInventoryEngine.invalidate()
    }

    private static func staticMetadataFingerprint(_ path: String) -> String {
        var status = stat(); BenchmarkProbe.record("inspection_metadata_lstat")
        guard lstat(path, &status) == 0 else { return "\(path):missing" }
        return [path, "present", String(status.st_dev), String(status.st_ino), String(status.st_mode & S_IFMT), String(status.st_mode), String(status.st_uid), String(status.st_gid), String(status.st_nlink), String(status.st_size), String(status.st_mtimespec.tv_sec), String(status.st_mtimespec.tv_nsec), String(status.st_ctimespec.tv_sec), String(status.st_ctimespec.tv_nsec)].joined(separator: ":")
    }

    private static func structuralMetadataFingerprint(_ path: String) -> String {
        var status = stat(); BenchmarkProbe.record("inspection_metadata_lstat")
        guard lstat(path, &status) == 0 else { return "\(path):missing" }
        return [path, "present", String(status.st_dev), String(status.st_mode & S_IFMT), String(status.st_mode), String(status.st_uid), String(status.st_gid), String(status.st_nlink)].joined(separator: ":")
    }

    static func helperLoadedState() -> LaunchdPresence {
        let target = "system/\(AppPaths.helperLabel)"
        let result = Shell.run(.launchctlPrint("system/\(AppPaths.helperLabel)"))
        guard result.outcome == .completed else { return .indeterminate }
        if result.exitCode == 0 { return .present }
        let prefix = "Could not find service \"\(target)\""
        return result.stdout.isEmpty && result.stderr.hasPrefix(prefix) ? .absent : .indeterminate
    }

    static func helperInstalled() -> Bool {
        helperLoadedState() == .present
    }

    private static func legacyLoadedState() -> LaunchdPresence {
        switch LegacyAutostartManager.loadedState() {
        case .present: return .present
        case .absent: return .absent
        case .indeterminate: return .indeterminate
        }
    }

    private static func staticArtifactValidation() -> Bool {
        rootArtifactText(AppPaths.rootHelperVersionPath, maximumBytes: 256)?.trimmingCharacters(in: .whitespacesAndNewlines) == AppPaths.helperVersion
            && artifact(rootArtifactText(AppPaths.launchDaemonPath, maximumBytes: 64 * 1_024), matches: PrivilegedHelperManager.diagnosticLaunchDaemonPlist())
            && helperArtifactMatches(bundledHelper: AppPaths.bundledHelperFile, installedHelperPath: AppPaths.rootHelperPath)
    }

    #if DEBUG
    // Fixture-only parser coverage for the helper-owned private ledger. The
    // release GUI does not compile this content-read path; production consumes
    // only the public helper-status projection above.
    static func terminalGenerationsValid(
        path: String = AppPaths.rootTerminalGenerationsPath,
        expectedOwnerUID: uid_t = 0
    ) -> Bool {
        let policy = BoundedFileReadPolicy(
            maximumBytes: Int(TerminalGenerationLedger.maximumBytes),
            expectedOwnerUID: expectedOwnerUID,
            requireSingleLink: true,
            rejectGroupOrWorldWritable: true,
            requireNonEmpty: false,
            safeParentDepth: 1
        )
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: path, policy: policy) else {
            return false
        }
        return TerminalGenerationLedger.parse(raw) != nil
    }
    #endif

    static func parsePowerSource(from output: String) -> PowerSource {
        if output.contains("Now drawing from 'AC Power'") { return .ac }
        if output.contains("Now drawing from 'Battery Power'") {
            return .battery(percent: parseBatteryPercent(from: output))
        }
        return .unknown(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseSleepDisabled(from output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count >= 2 {
                if parts[1] == "1" { return true }
                if parts[1] == "0" { return false }
                return nil
            }
        }
        return nil
    }

    static func parseACIdleSleep(from output: String) -> Int? {
        var inAC = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "AC Power:" { inAC = true; continue }
            if trimmed == "Battery Power:" { inAC = false; continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if inAC, parts.first == "sleep", parts.count >= 2 { return Int(parts[1]) }
        }
        return nil
    }

    private static func nativePowerSource() -> PowerSource {
        BenchmarkProbe.record("native_iokit_read")
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            return .unknown("IOKit power source unavailable")
        }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedSource = IOPSGetProvidingPowerSourceType(info) else {
            return .unknown("IOKit power source unavailable")
        }
        let source = unmanagedSource.takeUnretainedValue() as String
        if source == kIOPMACPowerKey { return .ac }
        guard source == kIOPMBatteryPowerKey else {
            return .unknown(source)
        }

        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else {
            return .battery(percent: nil)
        }
        let sources = unmanagedSources.takeRetainedValue() as NSArray
        var descriptions: [[String: Any]] = []
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source as CFTypeRef) else {
                continue
            }
            guard let description = unmanagedDescription.takeUnretainedValue() as? [String: Any] else { continue }
            descriptions.append(description)
        }
        return .battery(percent: internalBatteryPercent(from: descriptions))
    }

    static func internalBatteryPercent(from descriptions: [[String: Any]]) -> Int? {
        var currentTotal = 0.0
        var maximumTotal = 0.0
        for description in descriptions {
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  let currentValue = strictNonnegativeNumber(current),
                  let maximumValue = strictPositiveNumber(maximum),
                  currentValue <= maximumValue
            else { continue }
            currentTotal += currentValue
            maximumTotal += maximumValue
        }
        guard currentTotal.isFinite,
              maximumTotal.isFinite,
              maximumTotal > 0
        else { return nil }
        let percent = (currentTotal / maximumTotal) * 100
        guard percent.isFinite, percent >= 0, percent <= 100 else { return nil }
        return Int(percent.rounded())
    }

    private static func nativeSleepDisabled() -> Bool? {
        BenchmarkProbe.record("native_iokit_read")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let raw = IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return strictBool(raw)
    }

    private static func nativeACIdleSleep() -> Int? {
        guard let settings = currentPowerPreference("AC Power") as? [String: Any] else { return nil }
        return strictInt(settings["System Sleep Timer"])
    }

    private static func currentPowerPreference(_ key: String) -> Any? {
        BenchmarkProbe.record("native_cfpreferences_read", count: 2)
        _ = CFPreferencesSynchronize(
            powerManagementDomain as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        )
        return CFPreferencesCopyValue(
            key as CFString,
            powerManagementDomain as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesCurrentHost
        )
    }

    static func strictBool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    static func strictInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= 0,
              value <= Double(Int32.max)
        else { return nil }
        return Int(value)
    }

    private static func strictNonnegativeNumber(_ number: NSNumber) -> Double? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }

    private static func strictPositiveNumber(_ number: NSNumber) -> Double? {
        guard let value = strictNonnegativeNumber(number), value > 0 else { return nil }
        return value
    }

    private static func parseBatteryPercent(from output: String) -> Int? {
        guard let range = output.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        return Int(output[range].dropLast())
    }

    private static func validatedActivationLease(systemBuild: String?) -> ActivationLeaseStore.ReadResult {
        classifyActivationLeaseObservation(
            ActivationLeaseStore.read(),
            now: Date(),
            nowMonotonic: MonotonicClock.seconds(),
            bootID: BootIdentity.current(),
            systemBuild: systemBuild,
            expectedOwnerUID: getuid()
        )
    }

    /// Production liveness classifier. Only the capability's exact canonical
    /// legacy-plaintext provenance can become recoverable stale residue;
    /// malformed, journal-backed, or generic retained data stays typed as-is.
    static func classifyActivationLeaseObservation(
        _ result: ActivationLeaseStore.ReadResult,
        now: Date,
        nowMonotonic: TimeInterval,
        bootID: String?,
        systemBuild: String?,
        expectedOwnerUID: uid_t
    ) -> ActivationLeaseStore.ReadResult {
        switch result {
        case let .legacyPlaintext(lease):
            guard let bootID, let systemBuild,
                  lease.validationFailure(
                    now: now, nowMonotonic: nowMonotonic, currentBootID: bootID,
                    expectedOwnerUID: expectedOwnerUID, currentSystemBuild: systemBuild
                  ) == nil
            else { return .staleLegacyCanonical(lease) }
            // An active legacy plaintext lease remains read-only diagnostic
            // state; preserving .value keeps existing active behavior intact.
            return .value(lease)
        case let .value(lease):
            guard let bootID, let systemBuild,
                  lease.validationFailure(
                    now: now, nowMonotonic: nowMonotonic, currentBootID: bootID,
                    expectedOwnerUID: expectedOwnerUID, currentSystemBuild: systemBuild
                  ) == nil
            else { return .invalid(AppPaths.activationLeaseFile.path) }
            return .value(lease)
        case let other:
            return other
        }
    }

    private static func resolvedPreferences(_ result: DesiredStateStore.ReadResult) -> PowerPreferences {
        if case let .value(preferences) = result { return preferences }
        return .disabled
    }

    private static func desiredStateTruth(_ result: DesiredStateStore.ReadResult) -> UserStatePersistenceTruth {
        switch result {
        case .value: return .valid
        case .missing: return .missing
        case .invalid: return .invalid
        case .retainedResidue: return .retainedResidue
        case .unsafePath: return .unsafe
        case .io: return .io
        case .indeterminate: return .indeterminate
        }
    }

    private static func resolvedLease(_ result: ActivationLeaseStore.ReadResult) -> ActivationLease? {
        if case let .value(lease) = result { return lease }
        return nil
    }

    private static func activationLeaseTruth(_ result: ActivationLeaseStore.ReadResult) -> UserStatePersistenceTruth {
        switch result {
        case .value: return .valid
        case .legacyPlaintext, .staleLegacyCanonical: return .invalid
        case .missing: return .missing
        case .missingWithRecognizedLegacyArchive: return .missing
        case .invalid: return .invalid
        case .retainedResidue: return .retainedResidue
        case .unsafePath: return .unsafe
        case .io: return .io
        case .indeterminate: return .indeterminate
        }
    }

    private static func hasRecognizedLegacyLeaseArchive(_ result: ActivationLeaseStore.ReadResult) -> Bool {
        if case .missingWithRecognizedLegacyArchive = result { return true }
        return false
    }

    private static func hasStaleCanonicalLegacyLease(_ result: ActivationLeaseStore.ReadResult) -> Bool {
        if case .staleLegacyCanonical = result { return true }
        return false
    }

    static func helperStatus(
        path: String = AppPaths.rootHelperStatusPath,
        expectedOwnerUID: uid_t = 0
    ) -> HelperStatusRecord? {
        let policy = BoundedFileReadPolicy(
            maximumBytes: 4_096, expectedOwnerUID: expectedOwnerUID, requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: false, safeParentDepth: 1
        )
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: path, policy: policy) else { return nil }
        BenchmarkProbe.record("file_read")
        BenchmarkProbe.record("decoded_bytes", count: raw.utf8.count)
        return HelperStatusRecord.parse(raw)
    }

    static func sessionHeartbeatObservation(sessionID: UUID) -> SessionHeartbeatObservation {
        BenchmarkProbe.record("native_iokit_read")
        let power: SessionHeartbeatObservation.Power
        if let unmanagedInfo = IOPSCopyPowerSourcesInfo() {
            let powerInfo = unmanagedInfo.takeRetainedValue()
            if let unmanagedSource = IOPSGetProvidingPowerSourceType(powerInfo) {
                let source = unmanagedSource.takeUnretainedValue() as String
                if source == kIOPMACPowerKey {
                    power = .ac
                } else if source == kIOPMBatteryPowerKey {
                    power = .disconnected
                } else {
                    power = .unknown
                }
            } else {
                power = .unknown
            }
        } else {
            power = .unknown
        }

        let leaseOutcome = ActivationLeaseStore.read()
        let leaseIsValid: Bool
        switch leaseOutcome {
        case let .value(lease):
            leaseIsValid = lease.sessionID == sessionID
                && BootIdentity.current().map { bootID in
                    SystemBuild.current().map { build in
                        lease.validationFailure(
                            now: Date(), nowMonotonic: MonotonicClock.seconds(), currentBootID: bootID,
                            expectedOwnerUID: getuid(), currentSystemBuild: build
                        ) == nil
                    } ?? false
                } ?? false
        case .legacyPlaintext, .staleLegacyCanonical, .unsafePath, .retainedResidue, .io, .indeterminate:
            BenchmarkProbe.record("activation_lease_read_rejected")
            leaseIsValid = false
        case .missing, .missingWithRecognizedLegacyArchive, .invalid:
            leaseIsValid = false
        }

        return SessionHeartbeatObservation(
            power: power,
            leaseIsValid: leaseIsValid,
            helperStatus: helperStatus()
        )
    }

    private static func rootArtifactText(_ path: String, maximumBytes: Int) -> String? {
        let policy = BoundedFileReadPolicy(
            maximumBytes: maximumBytes, expectedOwnerUID: 0, requireSingleLink: true,
            rejectGroupOrWorldWritable: true, requireNonEmpty: true, safeParentDepth: 1
        )
        guard case let .success(raw) = BoundedFileReader.readUTF8(path: path, policy: policy) else { return nil }
        return raw
    }

    private static func artifact(_ installed: String?, matches expected: String) -> Bool {
        installed?.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines)
    }

    static func helperArtifactMatches(
        bundledHelper: URL,
        installedHelperPath: String = AppPaths.rootHelperPath,
        expectedInstalledOwner: uid_t = 0
    ) -> Bool {
        BoundedHelperComparator.matches(
            installed: installedHelperPath,
            bundled: bundledHelper.path,
            maximumBytes: 64 * 1_024 * 1_024,
            expectedInstalledOwner: expectedInstalledOwner
        )
    }

    static func validateBundle(at bundleURL: URL) -> BundleValidationResult {
        guard bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL) else {
            return BundleValidationResult(integrity: false, version: false, codesignExitCode: nil)
        }
        let signature = Shell.run(.codeSignatureVerification(bundleURL.path))
        let versionMatches = bundle.bundleIdentifier == AppPaths.bundleIdentifier
            && bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == AppPaths.appVersion
            && bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == AppPaths.appBuild
        return BundleValidationResult(
            integrity: signature.outcome == .completed && signature.exitCode == 0,
            version: versionMatches,
            codesignExitCode: signature.exitCode,
            indeterminate: signature.outcome != .completed
        )
    }
}
