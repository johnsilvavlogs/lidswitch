import Darwin
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch
@testable import LidSwitchHelper

private struct SeatbeltContract {
    let deniedOperations: Set<String>
    let deniedMachServices: Set<String>
    let deniedLiteralPaths: Set<String>
    let deniedSubpaths: Set<String>

    init(_ source: String) {
        var operations = Set<String>()
        var services = Set<String>()
        var literals = Set<String>()
        var subpaths = Set<String>()
        for rawLine in source.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("(deny ") else { continue }
            let remainder = line.dropFirst("(deny ".count)
            if let end = remainder.firstIndex(where: { $0 == " " || $0 == ")" }) {
                operations.insert(String(remainder[..<end]))
            }
            for (marker, destination) in [
                ("(global-name \"", "mach"),
                ("(literal \"", "literal"),
                ("(subpath \"", "subpath"),
            ] {
                guard let start = line.range(of: marker)?.upperBound,
                      let end = line[start...].firstIndex(of: "\"") else { continue }
                let value = String(line[start..<end])
                switch destination {
                case "mach": services.insert(value)
                case "literal": literals.insert(value)
                default: subpaths.insert(value)
                }
            }
        }
        deniedOperations = operations
        deniedMachServices = services
        deniedLiteralPaths = literals
        deniedSubpaths = subpaths
    }
}

private func shellWordAssignment(_ name: String, in source: String) -> Set<String> {
    let prefix = name + "=\""
    guard let line = source.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix(prefix) }),
          line.hasSuffix("\"") else { return [] }
    return Set(line.dropFirst(prefix.count).dropLast().split(separator: " ").map(String.init))
}

private final class BenchmarkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func record(_ operation: String, _ count: Int) {
        lock.lock()
        values[operation, default: 0] += count
        lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class BenchmarkInspectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_700_100_000)
    private var statusSequence = 0
    private var validationCalls = 0
    private var staticSequence = 0

    func currentDate() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func recordValidation() {
        lock.lock()
        validationCalls += 1
        lock.unlock()
    }

    func nextStatusTimestamp() -> Int {
        lock.lock()
        defer { lock.unlock() }
        statusSequence += 1
        now = now.addingTimeInterval(1)
        return Int(now.timeIntervalSince1970)
    }

    func nextStaticSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        staticSequence += 1
        return staticSequence
    }
}

private struct BenchmarkFixture: Sendable {
    let root: URL
    let support: URL
    let activationLease: URL
    let legacyPlaintextLease: URL
    let desiredState: URL
    let helperStatus: URL
    let appliedState: URL
    let terminalGenerations: URL
    let lease: ActivationLease
    let inspectionEngine: PowerInspector.InstallationInventoryEngine
    let dynamicEngine: PowerInspector.DynamicSnapshotEngine
    private let inspectionState: BenchmarkInspectionState
    private let mutableStaticArtifact: URL

    init() throws {
        root = try TestSandbox.makeDirectory(label: "benchmark-fixture").url
        support = root.appendingPathComponent("support", isDirectory: true)
        activationLease = support.appendingPathComponent("activation-lease")
        legacyPlaintextLease = support.appendingPathComponent("legacy-activation-lease")
        desiredState = support.appendingPathComponent("desired-state")
        helperStatus = root.appendingPathComponent("helper-status")
        appliedState = root.appendingPathComponent("applied-state")
        terminalGenerations = root.appendingPathComponent("terminal-generations")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard chmod(root.path, 0o700) == 0, chmod(support.path, 0o700) == 0,
              let bootID = BootIdentity.current(), let build = SystemBuild.current()
        else { throw NSError(domain: "BenchmarkFixture", code: 1) }
        let now = MonotonicClock.seconds()
        lease = ActivationLease(
            sessionID: UUID(),
            bootID: bootID,
            expiresAt: Date().addingTimeInterval(30),
            issuedMonotonic: now,
            expiresMonotonic: now + 30,
            ownerUID: getuid(),
            systemBuild: build
        )
        let userStatePolicy = try UserStateFileCapability.AncestryPolicy.testSandbox(root: root)
        try ActivationLeaseStore.write(lease, to: activationLease, ancestryPolicy: userStatePolicy)
        // SecureLeaseReader is the DEBUG-only v0.2.9 compatibility reader and
        // deliberately accepts canonical plaintext, not the current dual-slot
        // user-state journal. Keep its benchmark input separate so neither
        // persisted format is widened to accommodate the other.
        try Data(lease.storagePayload.utf8).write(to: legacyPlaintextLease, options: .atomic)
        guard chmod(legacyPlaintextLease.path, 0o600) == 0 else {
            throw NSError(domain: "BenchmarkFixture", code: 4)
        }
        try DesiredStateStore.write(.disabled, supportDirectory: support, stateFile: desiredState, ancestryPolicy: userStatePolicy)
        HelperStatusFixture.write(state: "inactive", reason: "benchmark-fixture", sessionID: nil, path: helperStatus.path)
        try AppliedStateStore.write(
            AppliedState(sessionID: UUID(), changedSleepDisabled: false, changedACSleep: false, originalACSleep: nil),
            path: appliedState.path
        )
        // TerminalGenerationStore deliberately treats a missing ledger as
        // unsafe: a crash before its initial durable creation must not permit
        // a generation to be resurrected.  Seed the fixture's empty ledger so
        // the benchmark exercises recording rather than that production guard.
        try Data().write(to: terminalGenerations, options: .atomic)
        guard chmod(terminalGenerations.path, 0o644) == 0 else {
            throw NSError(domain: "BenchmarkFixture", code: 2)
        }
        guard TerminalGenerationStore.record(sessionID: UUID(), path: terminalGenerations.path) else {
            throw NSError(domain: "BenchmarkFixture", code: 3)
        }

        let staticURLs = [
            root.appendingPathComponent("inspection-helper"),
            root.appendingPathComponent("inspection-version"),
            root.appendingPathComponent("inspection-daemon.plist"),
            root.appendingPathComponent("inspection-terminal-generations"),
            root.appendingPathComponent("inspection-bundled-helper"),
        ]
        mutableStaticArtifact = staticURLs[0]
        for (index, url) in staticURLs.enumerated() {
            try Data("benchmark-static-\(index)".utf8).write(to: url)
        }
        let originalAC = root.appendingPathComponent("inspection-original-ac")
        let originalBattery = root.appendingPathComponent("inspection-original-battery")
        let legacyRoot = root.appendingPathComponent("inspection-legacy-root")
        let legacyLogin = root.appendingPathComponent("inspection-legacy-login")
        let staticPathSet = Set(staticURLs.map(\.path))
        let dynamicPaths = (
            appliedState.path,
            helperStatus.path,
            originalAC.path,
            originalBattery.path,
            legacyRoot.path,
            legacyLogin.path
        )
        let dynamicPathSet = Set([
            dynamicPaths.0, dynamicPaths.1, dynamicPaths.2,
            dynamicPaths.3, dynamicPaths.4, dynamicPaths.5,
        ])
        let state = BenchmarkInspectionState()
        inspectionState = state
        inspectionEngine = PowerInspector.InstallationInventoryEngine(dependencies: .init(
            fingerprintPaths: staticURLs.map(\.path),
            now: { state.currentDate() },
            staticMetadata: { Self.fullMetadata(path: $0, allowed: staticPathSet) },
            collect: { fingerprint in
                state.recordValidation()
                return .init(
                    staticArtifactsPresent: fingerprint.contains { !$0.hasSuffix(":missing") },
                    staticValidationValid: true,
                    helperLaunchd: .present,
                    legacyLaunchd: .absent,
                    bundleValidation: .init(integrity: true, version: true, codesignExitCode: 0)
                )
            }
        ))
        dynamicEngine = PowerInspector.DynamicSnapshotEngine(dependencies: .init(
            dynamicPaths: (
                appliedState: dynamicPaths.0,
                helperStatus: dynamicPaths.1,
                originalAC: dynamicPaths.2,
                originalBattery: dynamicPaths.3,
                legacyRoot: dynamicPaths.4,
                legacyLogin: dynamicPaths.5
            ),
            source: { .ac },
            sleepDisabled: { false },
            acIdleSleep: { 5 },
            preferences: { .value(.disabled) },
            systemBuild: { "25F84" },
            activationLease: { _ in .missing("benchmark-fixture") },
            helperStatus: {
                PowerInspector.helperStatus(path: dynamicPaths.1, expectedOwnerUID: getuid())
            },
            dynamicMetadata: { Self.structuralMetadata(path: $0, allowed: dynamicPathSet) },
            now: { state.currentDate() },
        ))
        // Prime the steady hit outside measurement. Dedicated drift and
        // force-fresh rows invalidate/revalidate this same production engine.
        _ = inspectionEngine.inspect(policy: .reuseIfFresh)
    }

    func inspectStatusChurn() throws {
        let updated = inspectionState.nextStatusTimestamp()
        let reason = "benchmark-fixture-churn-\(updated)"
        let payload = "state=active\nreason=\(reason)\nsession=none\nupdated=\(updated)\n"
        try Data(payload.utf8).write(to: helperStatus)

        let parentRecorder = BenchmarkProbe.recorder
        let nested = BenchmarkCounter()
        let inspection = BenchmarkProbe.withRecorder({ operation, count in
            nested.record(operation, count)
            parentRecorder?(operation, count)
        }) {
            inspectionEngine.inspect(policy: .reuseIfFresh)
        }
        guard let status = PowerInspector.helperStatus(path: helperStatus.path, expectedOwnerUID: getuid()),
              status.reason == reason,
              Int(status.updatedAt.timeIntervalSince1970) == updated
        else { throw BenchmarkHarness.failure("status churn did not parse newest fixture status") }

        let counters = nested.snapshot()
        guard counters["installation_inventory_static_hit"] == 1,
              counters["inspection_artifact_validation", default: 0] == 0,
              counters["helper_byte_comparison", default: 0] == 0,
              counters["child_process", default: 0] == 0,
              inspection.state.isValid
        else { throw BenchmarkHarness.failure("status churn missed the steady static-cache contract") }
    }

    func fastDynamicSnapshot() {
        _ = dynamicEngine.snapshot(ownedSessionID: nil, inventory: inspectionEngine.current())
    }

    func staticCacheHit() {
        _ = inspectionEngine.inspect(policy: .reuseIfFresh)
    }

    func staticDrift() throws {
        let generation = inspectionState.nextStaticSequence()
        try Data("benchmark-static-drift-\(generation)".utf8).write(to: mutableStaticArtifact)
        _ = inspectionEngine.inspect(policy: .reuseIfFresh)
    }

    func forceFreshInventory() {
        _ = inspectionEngine.inspect(policy: .forceFresh)
    }

    func rollbackDynamicSnapshot() {
        _ = dynamicEngine.snapshot(ownedSessionID: nil, inventory: .pending)
    }

    private static func fullMetadata(path: String, allowed: Set<String>) -> String {
        precondition(allowed.contains(path), "benchmark static metadata escaped its fixture")
        var status = stat()
        guard lstat(path, &status) == 0 else { return "\(path):missing" }
        return [
            path, "present", String(status.st_dev), String(status.st_ino), String(status.st_mode & S_IFMT), String(status.st_mode),
            String(status.st_uid), String(status.st_gid), String(status.st_nlink), String(status.st_size),
            String(status.st_mtimespec.tv_sec), String(status.st_mtimespec.tv_nsec),
            String(status.st_ctimespec.tv_sec), String(status.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    private static func structuralMetadata(path: String, allowed: Set<String>) -> String {
        precondition(allowed.contains(path), "benchmark dynamic metadata escaped its fixture")
        var status = stat()
        guard lstat(path, &status) == 0 else { return "\(path):missing" }
        return [
            path, "present", String(status.st_dev), String(status.st_mode & S_IFMT), String(status.st_mode), String(status.st_uid),
            String(status.st_gid), String(status.st_nlink),
        ].joined(separator: ":")
    }

}

private struct ArtifactContract: Sendable {
    let appBundle: URL
    let installedHelperPath: String
    let expectedInstalledOwner: uid_t
}

private enum BenchmarkHarness {
    typealias Scenario = (name: String, kind: String, operation: @Sendable (BenchmarkFixture) throws -> Void)
    static let schemaVersion = "lidswitch-benchmark-v3"
    static let snapshotCoreLimitation = "Default rows are isolated fixture-backed production engines; real bundle validation and helper comparison run only with an explicit artifact contract."
    static let scenarios: [Scenario] = [
        ("fixture.power.fast-dynamic", "fixture-fast-dynamic", { fixture in
            fixture.fastDynamicSnapshot()
        }),
        ("fixture.installation.static-hit", "fixture-static-hit", { fixture in
            fixture.staticCacheHit()
        }),
        ("fixture.installation.static-drift", "fixture-static-drift", { fixture in
            try fixture.staticDrift()
        }),
        ("fixture.installation.force-fresh", "fixture-force-fresh", { fixture in
            fixture.forceFreshInventory()
        }),
        ("fixture.power.rollback-dynamic", "fixture-rollback-dynamic", { fixture in
            fixture.rollbackDynamicSnapshot()
        }),
        ("fixture.activation-lease.read", "fixture", { fixture in
            guard case let .value(readLease) = ActivationLeaseStore.read(
                from: fixture.activationLease, ancestorPolicy: .testTemporaryDirectory,
                capabilityPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: fixture.root)
            ),
                  readLease.sessionID == fixture.lease.sessionID else { throw failure("lease read") }
        }),
        ("fixture.activation-lease.write", "fixture", { fixture in
            try ActivationLeaseStore.write(fixture.lease, to: fixture.activationLease, ancestryPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: fixture.root))
        }),
        ("fixture.desired-state.read", "fixture", { fixture in
            guard DesiredStateStore.readPreferences(
                from: fixture.desiredState, ancestorPolicy: .testTemporaryDirectory,
                capabilityPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: fixture.root)
            ) == .value(.disabled) else { throw failure("desired read") }
        }),
        ("fixture.desired-state.write", "fixture", { fixture in
            try DesiredStateStore.write(.disabled, supportDirectory: fixture.support, stateFile: fixture.desiredState, ancestryPolicy: try UserStateFileCapability.AncestryPolicy.testSandbox(root: fixture.root))
        }),
        ("fixture.helper-status.write", "fixture", { fixture in
            HelperStatusFixture.write(state: "inactive", reason: "benchmark-fixture", sessionID: nil, path: fixture.helperStatus.path)
            guard FileManager.default.fileExists(atPath: fixture.helperStatus.path) else { throw failure("status write") }
        }),
        ("fixture.helper-status.read", "fixture", { fixture in
            guard PowerInspector.helperStatus(path: fixture.helperStatus.path, expectedOwnerUID: getuid()) != nil else { throw failure("status read") }
        }),
        ("fixture.helper-status.churn-static-cache-hit", "fixture-status-churn", { fixture in
            try fixture.inspectStatusChurn()
        }),
        ("fixture.applied-state.read", "fixture", { fixture in
            guard case .success = AppliedStateStore.load(path: fixture.appliedState.path) else { throw failure("applied read") }
        }),
        ("fixture.applied-state.write", "fixture", { fixture in
            try AppliedStateStore.write(
                AppliedState(sessionID: UUID(), changedSleepDisabled: false, changedACSleep: false, originalACSleep: nil),
                path: fixture.appliedState.path
            )
        }),
        ("fixture.secure-lease.read", "fixture", { fixture in
            guard case .success = SecureLeaseReader.load(path: fixture.legacyPlaintextLease.path, expectedOwnerUID: getuid()) else { throw failure("secure lease read") }
        }),
        ("fixture.terminal-generations.read", "fixture", { fixture in
            guard PowerInspector.terminalGenerationsValid(path: fixture.terminalGenerations.path, expectedOwnerUID: getuid()) else { throw failure("ledger read") }
        }),
        ("fixture.terminal-generations.write", "fixture", { fixture in
            guard TerminalGenerationStore.record(sessionID: UUID(), path: fixture.terminalGenerations.path) else { throw failure("ledger write") }
        }),
        ("fixture.diagnostics.renewal-coalesced", "fixture", { fixture in
            let sessionID = UUID()
            // Each cold/warm invocation measures one fresh publication rather
            // than accumulating history from an earlier sample.
            let file = fixture.root.appendingPathComponent("diagnostics-\(sessionID.uuidString.lowercased()).json")
            let diagnostics = SessionDiagnosticStore(file: file)
            for _ in 0..<38 {
                diagnostics.recordRenewal(reason: "safety-probes-valid", sessionID: sessionID)
            }
            guard diagnostics.flushForTesting() else { throw failure("diagnostic publication") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([SessionDiagnosticEntry].self, from: Data(contentsOf: file))
            let summaries = entries.filter { $0.event == "renew-summary" }
            guard summaries.count == 1, summaries[0].renewalCount == 38 else {
                throw failure("diagnostic coalescing")
            }
        }),
        ("controller.main-actor.refresh-scheduling", "controller-main-actor", { _ in
            MainActor.assumeIsolated {
                let controller = PowerController(bootstrap: false, snapshotProvider: { _ in .empty }, sideEffects: .fixture)
                controller.refresh()
            }
        }),
    ]

    static func run(
        output: URL,
        warmSamples: Int,
        artifactContract: ArtifactContract? = nil
    ) throws {
        guard (5...100).contains(warmSamples) else { throw failure("warm sample count must be 5...100") }
        let validatedArtifactContract = try artifactContract.map(validateArtifactContract)
        let handle: FileHandle
        do {
            handle = try TestSandbox.createBenchmarkOutput(at: output)
        } catch {
            throw failure(error.localizedDescription)
        }
        defer { try? handle.close() }
        let fixture = try BenchmarkFixture()

        var runRecord: [String: Any] = [
            "record_type": "run", "schema_version": schemaVersion, "warm_samples": warmSamples,
            "fixture_root": fixture.root.path, "artifact_scenarios_included": validatedArtifactContract != nil,
            "snapshot_core_context": "test-host",
            "snapshot_core_limitations": snapshotCoreLimitation,
        ]
        if let validatedArtifactContract {
            runRecord["app_bundle"] = validatedArtifactContract.appBundle.path
            runRecord["installed_helper_path"] = validatedArtifactContract.installedHelperPath
        }
        try write(runRecord, to: handle)
        try write([
            "record_type": "methodology", "schema_version": schemaVersion,
            "snapshot_core_context": "test-host", "snapshot_core_limitations": snapshotCoreLimitation,
            "artifact_validation": "explicit external app only; no guessed fallback",
            "helper_comparison": "production exact-byte comparison against installed root helper",
        ], to: handle)
        try write([
            "record_type": "environment", "schema_version": schemaVersion,
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture(),
        ], to: handle)
        for scenario in scenarios {
            try measure(name: scenario.name, kind: scenario.kind, classification: "cold", index: 0, fixture: fixture, handle: handle) {
                try scenario.operation(fixture)
            }
        }

        if let validatedArtifactContract {
            _ = try measureBundleArtifacts(
                artifactContract: validatedArtifactContract,
                classification: "cold",
                index: 0,
                fixture: fixture,
                handle: handle
            )
        }

        var samplesByScenario: [String: [UInt64]] = [:]
        let all = scenarios
        for sample in 1...warmSamples {
            for scenario in all {
                let elapsed = try measure(name: scenario.0, kind: scenario.1, classification: "warm", index: sample, fixture: fixture, handle: handle) {
                    try scenario.2(fixture)
                }
                samplesByScenario[scenario.0, default: []].append(elapsed)
            }
            if let validatedArtifactContract {
                let artifactSamples = try measureBundleArtifacts(
                    artifactContract: validatedArtifactContract,
                    classification: "warm",
                    index: sample,
                    fixture: fixture,
                    handle: handle
                )
                for (scenario, elapsed) in artifactSamples {
                    samplesByScenario[scenario, default: []].append(elapsed)
                }
            }
        }
        for (scenario, samples) in samplesByScenario.sorted(by: { $0.key < $1.key }) {
            try write(summary(scenario: scenario, samples: samples), to: handle)
        }
    }

    @discardableResult
    static func measure<T>(
        name: String,
        kind: String,
        classification: String,
        index: Int,
        fixture: BenchmarkFixture,
        handle: FileHandle,
        metadata: (T) -> [String: Any] = { _ in [:] },
        operation: () throws -> T
    ) throws -> UInt64 {
        let counter = BenchmarkCounter()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try BenchmarkProbe.withRecorder(counter.record) { try operation() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let counters = counter.snapshot()
        var record: [String: Any] = [
            "record_type": "sample", "schema_version": schemaVersion, "scenario": name, "scenario_kind": kind,
            "classification": classification, "sample_index": index, "elapsed_nanoseconds": elapsed,
            "main_thread_elapsed_nanoseconds": Thread.isMainThread ? elapsed : 0,
            "counters": counters, "fixture_root": fixture.root.path,
        ]
        for (key, value) in metadata(result) { record[key] = value }
        try write(record, to: handle)
        return elapsed
    }

    static func measureBundleArtifacts(
        artifactContract: ArtifactContract,
        classification: String,
        index: Int,
        fixture: BenchmarkFixture,
        handle: FileHandle
    ) throws -> [(String, UInt64)] {
        let bundleElapsed = try measure(
            name: "artifact.app-bundle.validation",
            kind: "external-app-artifact",
            classification: classification,
            index: index,
            fixture: fixture,
            handle: handle,
            metadata: { result in
                let exitCode: Any = result.codesignExitCode.map { Int($0) } ?? NSNull()
                return [
                    "app_bundle": artifactContract.appBundle.path,
                    "bundle_integrity_valid": result.integrity,
                    "bundle_version_valid": result.version,
                    "codesign_exit_code": exitCode,
                ]
            }
        ) {
            PowerInspector.validateBundle(at: artifactContract.appBundle)
        }
        let bundledHelper = artifactContract.appBundle
            .appendingPathComponent("Contents/Library/LaunchServices/LidSwitchHelper", isDirectory: false)
        let helperElapsed = try measure(
            name: "artifact.helper-byte-comparison",
            kind: "external-app-artifact",
            classification: classification,
            index: index,
            fixture: fixture,
            handle: handle,
            metadata: { result in
                [
                    "app_bundle": artifactContract.appBundle.path,
                    "bundled_helper_path": bundledHelper.path,
                    "installed_helper_path": artifactContract.installedHelperPath,
                    "helper_bytes_match": result,
                ]
            }
        ) {
            PowerInspector.helperArtifactMatches(
                bundledHelper: bundledHelper,
                installedHelperPath: artifactContract.installedHelperPath,
                expectedInstalledOwner: artifactContract.expectedInstalledOwner
            )
        }
        return [
            ("artifact.app-bundle.validation", bundleElapsed),
            ("artifact.helper-byte-comparison", helperElapsed),
        ]
    }

    static func validateArtifactContract(_ contract: ArtifactContract) throws -> ArtifactContract {
        let appBundle = contract.appBundle
        guard appBundle.isFileURL, appBundle.path.hasPrefix("/"), appBundle.pathExtension == "app" else {
            throw failure("app bundle must be an absolute .app path")
        }
        var bundleStatus = stat()
        guard lstat(appBundle.path, &bundleStatus) == 0,
              (bundleStatus.st_mode & S_IFMT) == S_IFDIR,
              (bundleStatus.st_mode & S_IFMT) != S_IFLNK,
              Bundle(url: appBundle) != nil
        else {
            throw failure("app bundle is missing, symlinked, or malformed")
        }
        let bundledHelper = appBundle.appendingPathComponent("Contents/Library/LaunchServices/LidSwitchHelper")
        var helperStatus = stat()
        guard lstat(bundledHelper.path, &helperStatus) == 0,
              (helperStatus.st_mode & S_IFMT) == S_IFREG
        else {
            throw failure("app bundle is missing a regular bundled helper")
        }
        var installedStatus = stat()
        guard lstat(contract.installedHelperPath, &installedStatus) == 0,
              installedStatus.st_mode & S_IFMT == S_IFREG,
              installedStatus.st_uid == contract.expectedInstalledOwner,
              installedStatus.st_nlink == 1,
              installedStatus.st_size > 0,
              installedStatus.st_mode & 0o022 == 0
        else {
            throw failure("installed helper failed ownership or metadata validation")
        }
        return contract
    }

    static func architecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: machine)) {
                String(cString: $0)
            }
        }
    }

    static func summary(scenario: String, samples: [UInt64]) -> [String: Any] {
        let values = samples.map { Double($0) }.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.count > 1 ? values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1) : 0
        let p95Index = Double(values.count - 1) * 0.95
        let lower = Int(p95Index.rounded(.down)); let upper = Int(p95Index.rounded(.up))
        let p95 = values[lower] + (values[upper] - values[lower]) * (p95Index - Double(lower))
        return ["record_type": "summary", "schema_version": schemaVersion, "scenario": scenario,
                "sample_count": values.count, "median_nanoseconds": percentile(values, 0.5),
                "p95_nanoseconds": p95, "sample_standard_deviation_nanoseconds": sqrt(variance),
                "quantile": "R-7 linear interpolation"]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let index = Double(values.count - 1) * p
        let lower = Int(index.rounded(.down)); let upper = Int(index.rounded(.up))
        return values[lower] + (values[upper] - values[lower]) * (index - Double(lower))
    }

    static func write(_ object: [String: Any], to handle: FileHandle) throws {
        // The host-side publisher requires one byte-canonical JSONL spelling;
        // keeping slashes literal matches its UTF-8 sorted-key serializer.
        // Foundation may expand an otherwise shortest Double spelling (for
        // example, 27330308.4) into 27330308.399999999. Summary rows therefore
        // render their closed schema explicitly with Swift's shortest
        // round-tripping Double spelling, which is also the publisher's
        // canonical JSON number spelling. Other rows contain no floating-point
        // values and remain on JSONSerialization's sorted-key path.
        let data: Data
        if object["record_type"] as? String == "summary" {
            data = try canonicalSummaryData(object)
        } else {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func canonicalSummaryData(_ object: [String: Any]) throws -> Data {
        let keys = [
            "median_nanoseconds", "p95_nanoseconds", "quantile", "record_type",
            "sample_count", "sample_standard_deviation_nanoseconds", "scenario", "schema_version",
        ]
        guard Set(object.keys) == Set(keys),
              let median = object["median_nanoseconds"] as? Double,
              let p95 = object["p95_nanoseconds"] as? Double,
              let quantile = object["quantile"] as? String,
              let recordType = object["record_type"] as? String,
              let sampleCount = object["sample_count"] as? Int,
              let deviation = object["sample_standard_deviation_nanoseconds"] as? Double,
              let scenario = object["scenario"] as? String,
              let schema = object["schema_version"] as? String,
              sampleCount > 0 else {
            throw failure("invalid summary record")
        }
        let fields = [
            "\"median_nanoseconds\":" + (try canonicalJSONNumber(median)),
            "\"p95_nanoseconds\":" + (try canonicalJSONNumber(p95)),
            "\"quantile\":" + (try canonicalJSONString(quantile)),
            "\"record_type\":" + (try canonicalJSONString(recordType)),
            "\"sample_count\":\(sampleCount)",
            "\"sample_standard_deviation_nanoseconds\":" + (try canonicalJSONNumber(deviation)),
            "\"scenario\":" + (try canonicalJSONString(scenario)),
            "\"schema_version\":" + (try canonicalJSONString(schema)),
        ]
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    private static func canonicalJSONNumber(_ value: Double) throws -> String {
        guard value.isFinite, value >= 0 else { throw failure("invalid summary number") }
        if value.rounded(.towardZero) == value, value <= Double(UInt64.max) {
            return String(UInt64(value))
        }
        let rendered = String(value)
        guard rendered.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw failure("summary number is not canonical JSON")
        }
        return rendered
    }

    private static func canonicalJSONString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let rendered = String(data: data, encoding: .utf8) else { throw failure("invalid summary string") }
        return rendered
    }

    static func failure(_ message: String) -> NSError { NSError(domain: "BenchmarkHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

final class BenchmarkHarnessTests: XCTestCase {
    func testFixtureHarnessProducesSchemaAndConsistentCounters() throws {
        let root = try TestSandbox.makeDirectory(label: "benchmark-output").url
        let output = root.appendingPathComponent("results.jsonl")
        try BenchmarkHarness.run(output: output, warmSamples: 5)
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        let records = try lines.map { line -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertTrue(records.allSatisfy { $0["schema_version"] as? String == BenchmarkHarness.schemaVersion })
        let runRecord = try XCTUnwrap(records.first { $0["record_type"] as? String == "run" })
        XCTAssertEqual(runRecord["artifact_scenarios_included"] as? Bool, false)
        XCTAssertFalse(records.contains { ($0["scenario"] as? String)?.hasPrefix("artifact.") == true })
        let summaries = records.filter { $0["record_type"] as? String == "summary" }
        XCTAssertTrue(summaries.allSatisfy { $0["sample_count"] as? Int == 5 && ($0["p95_nanoseconds"] as? Double ?? 0) >= 0 })
        let fixtureWrites = records.filter { ($0["scenario"] as? String)?.hasPrefix("fixture.") == true && $0["classification"] as? String == "warm" }
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path + "/"
        XCTAssertTrue(fixtureWrites.allSatisfy { !($0["fixture_root"] as? String ?? "").hasPrefix(repository) })
        XCTAssertTrue(records.contains { (($0["counters"] as? [String: Int])?["file_open"] ?? 0) > 0 })
        let cacheHits = records.filter {
            $0["scenario"] as? String == "fixture.helper-status.churn-static-cache-hit"
                && $0["classification"] as? String == "warm"
        }
        XCTAssertEqual(cacheHits.count, 5)
        XCTAssertTrue(cacheHits.allSatisfy {
            let counters = $0["counters"] as? [String: Int] ?? [:]
            return (counters["installation_inventory_static_hit"] ?? 0) == 1
                && (counters["inspection_artifact_validation"] ?? 0) == 0
                && (counters["child_process"] ?? 0) == 0
                && (counters["helper_byte_comparison"] ?? 0) == 0
        })
        let requiredRows = [
            "fixture.power.fast-dynamic",
            "fixture.installation.static-hit",
            "fixture.installation.static-drift",
            "fixture.installation.force-fresh",
            "fixture.power.rollback-dynamic",
        ]
        for row in requiredRows {
            XCTAssertEqual(records.filter {
                $0["scenario"] as? String == row && $0["classification"] as? String == "warm"
            }.count, 5, "missing benchmark row \(row)")
        }
        for row in ["fixture.power.fast-dynamic", "fixture.installation.static-hit", "fixture.power.rollback-dynamic"] {
            let samples = records.filter {
                $0["scenario"] as? String == row && $0["classification"] as? String == "warm"
            }
            XCTAssertTrue(samples.allSatisfy {
                let counters = $0["counters"] as? [String: Int] ?? [:]
                return (counters["inspection_artifact_validation"] ?? 0) == 0
                    && (counters["child_process"] ?? 0) == 0
                    && (counters["helper_byte_comparison"] ?? 0) == 0
            }, "expensive operation leaked into \(row)")
        }
        XCTAssertFalse(records.contains { ($0["scenario"] as? String)?.hasPrefix("native.power-inspector") == true })
    }

    func testSummaryWriterUsesShortestCanonicalFloatingPointJSON() throws {
        let root = try TestSandbox.makeDirectory(label: "benchmark-canonical-summary").url
        let output = root.appendingPathComponent("summary.jsonl")
        let handle = try TestSandbox.createBenchmarkOutput(at: output)
        try BenchmarkHarness.write(
            BenchmarkHarness.summary(
                scenario: "fixture.power.fast-dynamic",
                samples: [1, 2, 3, 27_000_000, 27_000_003]
            ),
            to: handle
        )
        try handle.close()
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("\"p95_nanoseconds\":27000002.4"))
        XCTAssertFalse(text.contains("27000002.399999999"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testHarnessRejectsTrackedOutputAndTooFewWarmSamples() throws {
        let tracked = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("benchmark.jsonl")
        XCTAssertThrowsError(try BenchmarkHarness.run(output: tracked, warmSamples: 5))
        XCTAssertThrowsError(try BenchmarkHarness.run(output: URL(fileURLWithPath: "/tmp/lidswitch-benchmark.jsonl"), warmSamples: 4))
        let boundedRoot = try TestSandbox.makeDirectory(label: "benchmark-max-samples").url
        XCTAssertThrowsError(try BenchmarkHarness.run(output: boundedRoot.appendingPathComponent("results.jsonl"), warmSamples: 101))
    }

    func testSandboxPathPolicyIsBoundaryAwareAndDoesNotConsultTMPDIR() throws {
        XCTAssertTrue(TestPathPolicy.isEqualOrDescendant("/safe/root/result.jsonl", root: "/safe/root"))
        XCTAssertTrue(TestPathPolicy.isEqualOrDescendant("/safe/root", root: "/safe/root"))
        XCTAssertFalse(TestPathPolicy.isEqualOrDescendant("/safe/root-sibling/result.jsonl", root: "/safe/root"))
        XCTAssertFalse(TestPathPolicy.isEqualOrDescendant("/safe/other", root: "/safe/root"))
        XCTAssertEqual(TestSandbox.literalRoot, "/private/tmp")
        XCTAssertFalse(TestSandbox.literalRoot.contains("TMPDIR"))

        var rootStatus = stat()
        XCTAssertEqual(lstat(TestSandbox.literalRoot, &rootStatus), 0)
        XCTAssertEqual(rootStatus.st_uid, 0)
        XCTAssertEqual(rootStatus.st_gid, 0)
        XCTAssertEqual(rootStatus.st_mode, S_IFDIR | S_ISVTX | 0o777)

        let directory = try TestSandbox.makeDirectory(label: "sandbox-contract")
        let fixtureRoot = try TestSandbox.configuredFixtureRoot()
        XCTAssertEqual(directory.url.deletingLastPathComponent().path, fixtureRoot)
        XCTAssertTrue(fixtureRoot.hasPrefix("/private/tmp/lidswitch-swift."))
        var status = stat()
        XCTAssertEqual(lstat(directory.url.path, &status), 0)
        XCTAssertEqual(status.st_uid, getuid())
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(status.st_mode, S_IFDIR | 0o700)
        XCTAssertEqual(status.st_dev, directory.device)
        XCTAssertEqual(status.st_ino, directory.inode)
    }

    func testBenchmarkOutputContractUsesExclusiveOwnerOnlyDescriptor() throws {
        let directory = try TestSandbox.makeDirectory(label: "benchmark-contract")
        let output = directory.url.appendingPathComponent("results.jsonl")
        let protectedRoots = ["/repo", "/user-support", "/root-support"]
        let handle = try TestSandbox.createBenchmarkOutput(at: output, protectedRoots: protectedRoots)
        handle.write(Data("sentinel\n".utf8))
        try handle.close()
        var status = stat()
        XCTAssertEqual(lstat(output.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_uid, getuid())
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(status.st_nlink, 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("sentinel\n".utf8))
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(at: output, protectedRoots: protectedRoots))
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(
            at: URL(fileURLWithPath: "/tmp/lidswitch-output.jsonl"),
            protectedRoots: protectedRoots
        ))
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(
            at: URL(fileURLWithPath: "/repo/live.jsonl"),
            protectedRoots: protectedRoots
        ))

        let nested = directory.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(
            at: nested.appendingPathComponent("nested.jsonl"),
            protectedRoots: protectedRoots
        ))

        let nonPrivate = try TestSandbox.makeDirectory(label: "nonprivate-parent")
        XCTAssertEqual(chmod(nonPrivate.url.path, 0o755), 0)
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(
            at: nonPrivate.url.appendingPathComponent("mode.jsonl"),
            protectedRoots: protectedRoots
        ))

        let targetLink = directory.url.appendingPathComponent("linked.jsonl")
        XCTAssertEqual(symlink("results.jsonl", targetLink.path), 0)
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(at: targetLink, protectedRoots: protectedRoots))
        XCTAssertEqual(try Data(contentsOf: output), Data("sentinel\n".utf8))

        let linkedParentName = "lidswitch-linked-parent-\(UUID().uuidString)"
        let linkedParent = URL(fileURLWithPath: try TestSandbox.configuredFixtureRoot()).appendingPathComponent(linkedParentName, isDirectory: true)
        XCTAssertEqual(symlink(directory.url.path, linkedParent.path), 0)
        XCTAssertThrowsError(try TestSandbox.createBenchmarkOutput(
            at: linkedParent.appendingPathComponent("symlink-parent.jsonl"),
            protectedRoots: protectedRoots
        ))
    }

    func testSafeWrappersOwnHostEnvelopeSandboxAndRetainedReceipt() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let wrapper = try String(contentsOf: root.appendingPathComponent("script/run_swift_tests_safely.sh"), encoding: .utf8)
        let common = try String(contentsOf: root.appendingPathComponent("script/swift_sandbox_common.sh"), encoding: .utf8)
        let build = try String(contentsOf: root.appendingPathComponent("script/run_swift_build_safely.sh"), encoding: .utf8)
        let envelope = try String(contentsOf: root.appendingPathComponent("script/live_state_envelope.sh"), encoding: .utf8)
        let profile = try String(contentsOf: root.appendingPathComponent("script/swift_test_sandbox.sb.in"), encoding: .utf8)
        let powerTests = try String(contentsOf: root.appendingPathComponent("Tests/LidSwitchTests/PowerInspectorTests.swift"), encoding: .utf8)
        let benchmark = try String(contentsOf: root.appendingPathComponent("script/benchmark_baseline.sh"), encoding: .utf8)
        let session = try String(contentsOf: root.appendingPathComponent("script/validate_session_safety.sh"), encoding: .utf8)
        let ci = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let safeFile = try String(contentsOf: root.appendingPathComponent("script/safe_file_capability.py"), encoding: .utf8)
        let supervisor = try String(contentsOf: root.appendingPathComponent("script/safe_process_supervisor.py"), encoding: .utf8)
        let sandboxContract = SeatbeltContract(profile)

        for command in [wrapper, build] {
            // Both wrappers are invoked only through the held entry.  The
            // shared common/envelope sources therefore arrive through their
            // authenticated descriptor slots rather than repository paths.
            XCTAssertTrue(command.contains("source /dev/fd/31"))
            XCTAssertTrue(command.contains("source /dev/fd/32"))
            XCTAssertTrue(command.contains("LIDSWITCH_HELD_ENTRY:-"))
            XCTAssertTrue(command.contains("LIDSWITCH_HELD_FD_MAP:-"))
            XCTAssertTrue(command.contains("swift_sandbox_reject_inherited_paths"))
            XCTAssertTrue(command.contains("swift_sandbox_reject_inherited_fds"))
            XCTAssertTrue(command.contains("swift_sandbox_setup \"$ROOT_DIR\""))
            XCTAssertTrue(command.contains("live_envelope_preflight"))
            XCTAssertTrue(command.contains("swift_sandbox_run"))
            XCTAssertTrue(command.contains("live_envelope_postflight"))
            XCTAssertTrue(command.contains("live_envelope_finalize_terminal_receipt"))
            XCTAssertFalse(command.contains("live_envelope_finalize_receipt"))
            XCTAssertTrue(command.contains("swift_sandbox_publish_benchmark"))
            XCTAssertTrue(command.contains("${BASH_SOURCE[0]}"))
            XCTAssertTrue(command.contains("Retained host receipt"))
            let preflight = try XCTUnwrap(command.range(of: "live_envelope_preflight"))
            let invocation = try XCTUnwrap(command.range(of: "swift_sandbox_run", range: preflight.upperBound..<command.endIndex))
            let postflight = try XCTUnwrap(command.range(of: "live_envelope_postflight", range: invocation.upperBound..<command.endIndex))
            let receipt = try XCTUnwrap(command.range(of: "live_envelope_finalize_terminal_receipt", range: postflight.upperBound..<command.endIndex))
            XCTAssertLessThan(preflight.lowerBound, invocation.lowerBound)
            XCTAssertLessThan(invocation.lowerBound, postflight.lowerBound)
            XCTAssertLessThan(postflight.lowerBound, receipt.lowerBound)
            XCTAssertTrue(command.contains("live_envelope_finalize_terminal_receipt \"$command_status\" \"$status\""))
            XCTAssertTrue(command.contains("trap - EXIT HUP INT TERM\nexit \"$status\""))
        }

        XCTAssertTrue(common.contains("lidswitch-swift."))
        XCTAssertTrue(common.contains("lidswitch-envelope."))
        XCTAssertTrue(common.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertTrue(common.contains("/usr/bin/env -i"))
        XCTAssertTrue(common.contains("export HOME=\"$LIDSWITCH_SWIFT_EXEC_ROOT/home\""))
        XCTAssertTrue(common.contains("CFFIXED_USER_HOME"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_SCRATCH_PATH"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_SANDBOX_PROFILE"))
        XCTAssertTrue(common.contains("/usr/bin/sandbox-exec"))
        XCTAssertTrue(common.contains("safe_process_supervisor.py"))
        XCTAssertTrue(common.contains("--cleanup-source-root \"$LIDSWITCH_SWIFT_SOURCE_ROOT\""))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_XCODE_DEVELOPER_DIR"))
        XCTAssertTrue(common.contains("swift_sandbox_assert_developer_toolchain"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_DEVELOPER_SEAL"))
        XCTAssertTrue(profile.contains("@XCODE_DEVELOPER@"))
        XCTAssertTrue(profile.contains("@XCODE_XCTEST_TOOL@"))
        XCTAssertFalse(profile.contains("/Applications/Xcode.app/Contents/Developer"))
        XCTAssertTrue(common.contains("swift_sandbox_read_supervisor_result"))
        XCTAssertTrue(common.contains("--result \"$LIDSWITCH_SWIFT_CONTROL_ROOT/supervisor-$capture_name.result\""))
        XCTAssertTrue(common.contains("safe_file_capability.py"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_SANDBOX_PROFILE_SEAL"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_ENVELOPE_NONCE"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_PREFLIGHT"))
        XCTAssertTrue(common.contains("LIDSWITCH_SWIFT_POSTFLIGHT"))
        XCTAssertTrue(envelope.contains("live-state-retained.receipt"))
        XCTAssertTrue(envelope.contains("host_preserved="))
        XCTAssertTrue(envelope.contains("schema=3"))
        XCTAssertTrue(envelope.contains("child_command_exit="))
        XCTAssertTrue(envelope.contains("wrapper_exit="))
        XCTAssertTrue(envelope.contains("\"$child_command_exit\" == 256"))
        XCTAssertTrue(envelope.contains("preflight_sha256="))
        XCTAssertTrue(envelope.contains("postflight_sha256="))
        XCTAssertTrue(envelope.contains("benchmark_published="))
        XCTAssertTrue(common.contains("\"$app\" == /private/tmp/*"))
        XCTAssertTrue(common.contains("\"$app_parent\" != \"/private/tmp\""))
        XCTAssertTrue(common.contains("\"$parent_name\" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$"))
        XCTAssertTrue(common.contains("[A-Za-z0-9._-]{0,91}\\.app"))
        XCTAssertTrue(common.contains("\"$samples\" -le 100"))
        XCTAssertTrue(common.contains("%u:%g:%p"))
        XCTAssertTrue(common.contains("0:0:41777"))
        XCTAssertTrue(common.contains("/usr/bin/id -g"))
        XCTAssertTrue(benchmark.contains("\"$APP_BUNDLE\" == /private/tmp/*"))
        XCTAssertTrue(benchmark.contains("\"$APP_PARENT\" != \"/private/tmp\""))
        XCTAssertTrue(benchmark.contains("\"$PARENT_NAME\" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$"))
        XCTAssertTrue(benchmark.contains("[A-Za-z0-9._-]{0,91}\\.app"))
        XCTAssertTrue(benchmark.contains("\"$SAMPLES\" -le 100"))
        XCTAssertTrue(benchmark.contains("%u:%g:%p"))
        XCTAssertTrue(benchmark.contains("0:0:41777"))
        XCTAssertTrue(benchmark.contains("/usr/bin/id -g"))
        XCTAssertTrue(safeFile.contains("ArtifactTreeCapability"))
        XCTAssertTrue(safeFile.contains("benchmark app parent is not private"))
        XCTAssertTrue(safeFile.contains("os.O_EXCL"))
        XCTAssertTrue(safeFile.contains("os.O_NOFOLLOW"))
        XCTAssertTrue(safeFile.contains("os.fsync(parent_fd)"))
        XCTAssertTrue(safeFile.contains("int(pieces[4], 8)"))
        XCTAssertTrue(safeFile.contains("verify_named_file"))
        XCTAssertTrue(safeFile.contains("unlink_created_if_same"))
        XCTAssertTrue(supervisor.contains("start_new_session=True"))
        XCTAssertTrue(supervisor.contains("import re"))
        XCTAssertTrue(supervisor.contains("create_supervisor_result"))
        XCTAssertTrue(supervisor.contains("install_interruption_handlers"))
        XCTAssertTrue(supervisor.contains("run_cleanup_state_machine"))
        XCTAssertTrue(supervisor.contains("direct_containment_signal"))
        XCTAssertTrue(supervisor.contains("darwin_process_identity"))
        XCTAssertTrue(supervisor.contains("PROC_PIDTBSDINFO"))
        XCTAssertTrue(supervisor.contains("open_verified_cleanup_script"))
        XCTAssertTrue(supervisor.contains("CLEANUP_BOOTSTRAP"))
        XCTAssertTrue(supervisor.contains("os.closerange(3"))
        XCTAssertTrue(powerTests.contains("#if LIDSWITCH_OBSOLETE_IN_PROCESS_LIVE_GUARD"))
        let activeTests = try XCTUnwrap(powerTests.range(of: "final class SessionSafetyTests"))
        XCTAssertFalse(powerTests[activeTests.lowerBound...].contains("LiveStatePreservationToken.capture"))
        XCTAssertFalse(powerTests[activeTests.lowerBound...].contains("LiveControllerSessionGuard.capture"))
        XCTAssertTrue(build.contains("--print-bin-path"))
        XCTAssertTrue(build.contains("--scratch-path \"$LIDSWITCH_SWIFT_HELPER_SCRATCH_PATH\""))
        XCTAssertTrue(build.contains("--scratch-path \"$LIDSWITCH_SWIFT_APP_SCRATCH_PATH\""))

        for protected in [
            "@REPO_ROOT@", "@REAL_HOME@/Library/Application Support/LidSwitch",
            "/Library/Application Support/LidSwitch",
            "/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist",
            "/Applications/LidSwitch.app",
        ] {
            XCTAssertTrue(profile.contains(protected))
        }
        XCTAssertTrue(profile.contains("(deny file-write* (literal \"@SOURCE_ROOT@\"))"))
        XCTAssertTrue(profile.contains("(allow file-write* (subpath \"@EXEC_ROOT@\"))"))
        XCTAssertTrue(sandboxContract.deniedLiteralPaths.contains("@CONTROL_ROOT@"))
        XCTAssertTrue(sandboxContract.deniedSubpaths.contains("@CONTROL_ROOT@"))
        XCTAssertFalse(profile.contains("@BENCHMARK_OUTPUT@"))
        XCTAssertFalse(profile.contains("/dev/fd/[0-9]"))
        XCTAssertFalse(profile.contains("^/private/tmp/lidswitch-"), "sandbox cannot write sibling retained runs")
        XCTAssertTrue(profile.contains("(deny mach-lookup (global-name \"com.johnsilva.lidswitch.helper.control\"))"))
        XCTAssertTrue(profile.contains("(deny mach-lookup (global-name \"com.apple.PowerManagement.control\"))"))
        XCTAssertTrue(profile.contains("(deny mach-lookup (global-name \"com.apple.iokit.powerdxpc\"))"))
        XCTAssertTrue(profile.contains("com.apple.PowerManagement."))
        XCTAssertTrue(profile.contains("(deny appleevent-send)"))
        XCTAssertTrue(profile.contains("(deny iokit-open)"))
        XCTAssertTrue(profile.contains("(allow signal (target self))"))
        XCTAssertTrue(Set([
            "authorization-right-obtain", "job-creation", "mach-bootstrap", "mach-register",
            "process-info-setcontrol", "distributed-notification-post", "darwin-notification-post",
        ]).isSubset(of: sandboxContract.deniedOperations))
        XCTAssertTrue(Set([
            "com.apple.coreservices.launchservicesd", "com.apple.lsd.open", "com.apple.lsd.openurl",
            "com.apple.xpc.smd", "com.apple.xpc.loginitemregisterd", "com.apple.backgroundtaskmanagement",
            "com.apple.backgroundtaskmanagementagent", "com.apple.coreservices.sharedfilelistd.xpc",
            "com.apple.ak.authorizationservices.xpc", "com.apple.authd",
        ]).isSubset(of: sandboxContract.deniedMachServices))
        for executable in [
            "/bin/launchctl", "/usr/bin/pmset", "/usr/bin/osascript", "/usr/bin/sudo",
            "/usr/bin/open", "/usr/bin/caffeinate", "/usr/sbin/systemsetup",
        ] {
            XCTAssertTrue(profile.contains("(deny process-exec (literal \"\(executable)\"))"))
            XCTAssertTrue(profile.contains("(deny file-read-data (literal \"\(executable)\"))"))
        }

        XCTAssertFalse(ci.contains("./script/run_swift_build_safely.sh"))
        XCTAssertFalse(ci.contains("./script/run_swift_tests_safely.sh"))
        XCTAssertTrue(ci.contains("Immutable candidate release validation is a separate required future gate."))
        XCTAssertFalse(ci.contains("--scratch-path /tmp"))
        for script in [benchmark, session] {
            XCTAssertTrue(script.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
            XCTAssertTrue(script.contains("/usr/bin/dirname"))
            XCTAssertTrue(script.contains("/bin/pwd -P"))
        }
        XCTAssertTrue(benchmark.contains("/usr/bin/basename"))
        XCTAssertTrue(common.contains("/bin/mkdir"))
        XCTAssertFalse(benchmark.contains("mkdir -p"))
        XCTAssertFalse(benchmark.contains("run_swift_tests_safely.sh"))
        XCTAssertTrue(benchmark.contains("manager-held benchmark required"))
        for flag in ["--benchmark-output", "--benchmark-app-bundle", "--benchmark-samples"] {
            XCTAssertTrue(wrapper.contains(flag))
        }
        XCTAssertTrue(wrapper.contains("partial benchmark request is forbidden"))
        XCTAssertTrue(wrapper.contains("benchmark request requires the exact benchmark test"))
        XCTAssertTrue(common.contains("LIDSWITCH_BENCHMARK_OUTPUT=\"$LIDSWITCH_SWIFT_BENCHMARK_OUTPUT\""))
        XCTAssertTrue(common.contains("LIDSWITCH_BENCHMARK_APP_BUNDLE=\"$LIDSWITCH_SWIFT_BENCHMARK_APP\""))
        XCTAssertTrue(session.contains("run_swift_tests_safely.sh"))
    }

    func testSafeWrapperStaticallyRejectsAdversarialEnvironmentOverrides() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let wrapper = try String(contentsOf: root.appendingPathComponent("script/run_swift_tests_safely.sh"), encoding: .utf8)
        let build = try String(contentsOf: root.appendingPathComponent("script/run_swift_build_safely.sh"), encoding: .utf8)
        let common = try String(contentsOf: root.appendingPathComponent("script/swift_sandbox_common.sh"), encoding: .utf8)
        for override in [
            "LIDSWITCH_SCRATCH_PATH", "LIDSWITCH_BENCHMARK_SCRATCH_PATH",
            "LIDSWITCH_SWIFT_SANDBOX_PROFILE", "LIDSWITCH_SWIFT_ENVELOPE_NONCE",
            "LIDSWITCH_SWIFT_CONTROL_ROOT", "LIDSWITCH_SWIFT_EXEC_ROOT",
            "LIDSWITCH_TEST_FIXTURE_ROOT",
            "SWIFTPM_BUILD_DIR", "SWIFTPM_MODULECACHE_OVERRIDE",
            "SWIFTPM_TESTS_MODULECACHE", "SWIFTPM_TESTS_PACKAGECACHE",
            "SWIFTPM_CACHE_PATH", "SWIFTPM_CONFIG_PATH", "SWIFTPM_SECURITY_PATH",
            "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "DEVELOPER_DIR",
            "SWIFT_EXEC", "DYLD_INSERT_LIBRARIES", "BASH_ENV", "ENV", "BASH_XTRACEFD",
        ] {
            XCTAssertTrue(common.contains(override), "missing rejection for \(override)")
        }
        XCTAssertTrue(common.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertFalse(common.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("source ") },
                       "common setup must not source caller-selected files")
        XCTAssertTrue(common.contains("! -L /usr/bin/sandbox-exec"))
        XCTAssertTrue(common.contains("XCODE_[A-Z_]+"))
        XCTAssertTrue(common.contains("nonstandard inherited file descriptor is not permitted"))
        XCTAssertTrue(wrapper.hasPrefix("#!/bin/bash -p\n"))
        XCTAssertTrue(build.hasPrefix("#!/bin/bash -p\n"))
    }

    func testLiveFingerprintAllowsOnlySameActiveGenerationOrExactSafeIdle() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let envelope = try String(contentsOf: root.appendingPathComponent("script/live_state_envelope.sh"), encoding: .utf8)
        for evidence in [
            "power_source", "sleep_disabled", "ac_sleep_minutes", "status_session",
            "status_reason_class", "status_monotonic", "launchd_pid", "launchd_program",
            "status_schema", "status_evidence", "kernel_boot", "kernel_build", "kernel_monotonic",
            "authority_kind",
            "plist_sha256", "plist_qualified_build", "helper_meta", "private_applied_meta", "private_terminal_meta",
            "private_reservations_meta", "private_proof_meta", "private_lock_meta",
            "lease_session", "lease_issued_mono", "lease_expires_mono",
            "user_history_diagnostic_meta",
        ] {
            XCTAssertTrue(envelope.contains(evidence), "missing fingerprint evidence \(evidence)")
        }
        XCTAssertTrue(envelope.contains("BSD stat uses lstat(2) unless -L is supplied"))
        XCTAssertTrue(envelope.contains("$LIVE_STATUS_SESSION"))
        XCTAssertTrue(envelope.contains("live_envelope_numeric_not_decreased"))
        XCTAssertTrue(envelope.contains("live_envelope_numeric_strictly_increased"))
        XCTAssertTrue(envelope.contains("$LIVE_LEASE_BOOT\" == \"$LIVE_KERNEL_BOOT"))
        XCTAssertTrue(envelope.contains("mach_continuous_time"))
        XCTAssertTrue(envelope.contains("issued <= status && status <= expires && status <= current"))
        XCTAssertTrue(envelope.contains("renewal-did-not-advance"))
        XCTAssertTrue(envelope.contains("reconnect-pending"))
        XCTAssertTrue(envelope.contains("Could not find service"))
        XCTAssertEqual(shellWordAssignment("LIDSWITCH_CANDIDATE_STEADY_REASONS", in: envelope), [
            "verified", "renewed", "reconnected", "override-recovered",
        ])
        XCTAssertFalse(shellWordAssignment("LIDSWITCH_CANDIDATE_STEADY_REASONS", in: envelope).contains("reconnect-pending"))
        XCTAssertTrue(envelope.contains("candidate-private|"))
        XCTAssertTrue(envelope.contains("legacy-root-evidence|"))
        XCTAssertTrue(envelope.contains("/Groups/admin PrimaryGroupID"))
        XCTAssertTrue(envelope.contains("\"$mode\" == \"640\""))
        XCTAssertTrue(envelope.contains("postflight-fingerprint-mismatch"))
        XCTAssertFalse(envelope.contains("/usr/bin/sudo"))
        XCTAssertFalse(envelope.contains("pmset -a"))
    }

    func testBenchmarkScriptRejectsMissingOutputValue() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["script/benchmark_baseline.sh", "--output", "/tmp/results.jsonl"]
        let output = Pipe()
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 64)
        XCTAssertTrue(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("usage:") == true)
    }

    func testArtifactContractRejectsNonAppAndSymlinkInputs() throws {
        let fixture = try makeArtifactBundle()
        XCTAssertThrowsError(try BenchmarkHarness.validateArtifactContract(
            ArtifactContract(
                appBundle: URL(string: "relative.app")!,
                installedHelperPath: fixture.installedHelper.path,
                expectedInstalledOwner: getuid()
            )
        ))
        let notApp = fixture.root.appendingPathComponent("not-an-app", isDirectory: true)
        try FileManager.default.createDirectory(at: notApp, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BenchmarkHarness.validateArtifactContract(
            ArtifactContract(
                appBundle: notApp,
                installedHelperPath: fixture.installedHelper.path,
                expectedInstalledOwner: getuid()
            )
        ))
        let linkedApp = fixture.root.appendingPathComponent("linked.app")
        XCTAssertEqual(symlink(fixture.app.path, linkedApp.path), 0)
        XCTAssertThrowsError(try BenchmarkHarness.validateArtifactContract(
            ArtifactContract(
                appBundle: linkedApp,
                installedHelperPath: fixture.installedHelper.path,
                expectedInstalledOwner: getuid()
            )
        ))
        XCTAssertThrowsError(try BenchmarkHarness.validateArtifactContract(
            ArtifactContract(
                appBundle: fixture.app,
                installedHelperPath: fixture.installedHelper.path,
                expectedInstalledOwner: 0
            )
        ))
        let linkedHelper = fixture.root.appendingPathComponent("linked-helper")
        XCTAssertEqual(symlink(fixture.installedHelper.path, linkedHelper.path), 0)
        XCTAssertThrowsError(try BenchmarkHarness.validateArtifactContract(
            ArtifactContract(
                appBundle: fixture.app,
                installedHelperPath: linkedHelper.path,
                expectedInstalledOwner: getuid()
            )
        ))
    }

    func testArtifactHarnessIncludesValidationAndHelperComparison() throws {
        let fixture = try makeArtifactBundle()
        let output = fixture.root.appendingPathComponent("results.jsonl")
        try BenchmarkHarness.run(
            output: output,
            warmSamples: 5,
            artifactContract: ArtifactContract(
                appBundle: fixture.app,
                installedHelperPath: fixture.installedHelper.path,
                expectedInstalledOwner: getuid()
            )
        )
        let records = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(records.first { $0["record_type"] as? String == "run" }?["artifact_scenarios_included"] as? Bool, true)
        let artifactSamples = records.filter { ($0["scenario"] as? String)?.hasPrefix("artifact.") == true && $0["classification"] as? String == "warm" }
        XCTAssertEqual(artifactSamples.count, 10)
        XCTAssertTrue(artifactSamples.contains { $0["scenario"] as? String == "artifact.app-bundle.validation" && $0["codesign_exit_code"] != nil })
        XCTAssertTrue(artifactSamples.contains { $0["scenario"] as? String == "artifact.helper-byte-comparison" && $0["helper_bytes_match"] as? Bool == true })
    }

    func testEnvironmentBenchmarkCommandWritesOnlyWhenExplicitlyRequested() throws {
        guard let raw = ProcessInfo.processInfo.environment["LIDSWITCH_BENCHMARK_OUTPUT"] else { return }
        let samples = Int(ProcessInfo.processInfo.environment["LIDSWITCH_BENCHMARK_WARM_SAMPLES"] ?? "5") ?? 0
        guard let appBundle = ProcessInfo.processInfo.environment["LIDSWITCH_BENCHMARK_APP_BUNDLE"] else {
            throw BenchmarkHarness.failure("missing explicit app bundle")
        }
        try BenchmarkHarness.run(
            output: URL(fileURLWithPath: raw),
            warmSamples: samples,
            artifactContract: ArtifactContract(
                appBundle: URL(fileURLWithPath: appBundle),
                installedHelperPath: AppPaths.rootHelperPath,
                expectedInstalledOwner: 0
            )
        )
    }

    private func makeArtifactBundle() throws -> (root: URL, app: URL, installedHelper: URL) {
        let root = try TestSandbox.makeDirectory(label: "artifact").url
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let bundledHelper = contents.appendingPathComponent("Library/LaunchServices/LidSwitchHelper")
        let installedHelper = root.appendingPathComponent("installed-helper")
        try FileManager.default.createDirectory(at: bundledHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.johnsilva.LidSwitch</string>
          <key>CFBundleShortVersionString</key><string>0.2.9</string>
          <key>CFBundleVersion</key><string>1</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try Data("fixture-helper".utf8).write(to: bundledHelper)
        try Data("fixture-helper".utf8).write(to: installedHelper)
        return (root, app, installedHelper)
    }
}
