import Darwin
import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch
@testable import LidSwitchHelper

final class SessionSafetyTests: XCTestCase {
    func testFreshManualSessionRequiresVerifiedCurrentAcknowledgement() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let status = HelperStatusRecord(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            updatedAt: now
        )
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: status,
            checkedAt: now
        )

        XCTAssertTrue(snapshot.sessionActive)
        XCTAssertEqual(snapshot.statusTitle, "Protection active — plugged in")
        XCTAssertFalse(snapshot.canStartSession)
    }

    func testStaleAcknowledgementCannotClaimActive() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let status = HelperStatusRecord(
            state: "active",
            reason: "verified",
            sessionID: lease.sessionID,
            updatedAt: now.addingTimeInterval(-30)
        )
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: status,
            checkedAt: now
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testRecoveryRequiredBlocksReadyAndNewSessionsEvenWhenSleepDisabledIsOff() {
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            status: HelperStatusRecord(
                state: "recovery-required",
                reason: "restore-unverified",
                sessionID: UUID(),
                updatedAt: Date()
            )
        )

        XCTAssertTrue(snapshot.restoreRequired)
        XCTAssertTrue(snapshot.helperRecoveryRequired)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Recovery required")
    }

    func testOrphanedLeaseCannotClaimProtectionAfterAppRelaunch() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: HelperStatusRecord(
                state: "active",
                reason: "verified",
                sessionID: lease.sessionID,
                updatedAt: now
            ),
            checkedAt: now,
            ownsLease: false
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertTrue(snapshot.orphanedLeasePresent)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testUnpluggedSnapshotNeverClaimsProtectionOrRearminess() {
        let now = Date()
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        let snapshot = makeSnapshot(
            source: .battery(percent: 80),
            sleepDisabled: true,
            sleepDisabledVerified: true,
            lease: lease,
            status: HelperStatusRecord(
                state: "active",
                reason: "verified",
                sessionID: lease.sessionID,
                updatedAt: now
            ),
            checkedAt: now
        )

        XCTAssertFalse(snapshot.sessionActive)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Restore required")
    }

    func testUnknownLivePowerStateFailsClosed() {
        let snapshot = makeSnapshot(
            source: .unknown("pmset failed"),
            sleepDisabled: false,
            sleepDisabledVerified: false
        )

        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Power status unavailable")
    }

    func testOldLoginItemLoadedIsDistinctLegacyResidue() {
        let snapshot = makeSnapshot(
            source: .ac,
            sleepDisabled: false,
            sleepDisabledVerified: true,
            legacyLoginItemLoaded: true
        )

        XCTAssertTrue(snapshot.legacyResiduePresent)
        XCTAssertFalse(snapshot.canStartSession)
        XCTAssertEqual(snapshot.statusTitle, "Old startup files found")
    }

    func testSleepDisabledParserRejectsMissingAndMalformedValues() {
        XCTAssertEqual(
            PowerInspector.parseSleepDisabled(from: "SleepDisabled 1\n"),
            true
        )
        XCTAssertEqual(
            PowerInspector.parseSleepDisabled(from: "SleepDisabled 0\n"),
            false
        )
        XCTAssertNil(PowerInspector.parseSleepDisabled(from: "SleepDisabled maybe\n"))
        XCTAssertNil(PowerInspector.parseSleepDisabled(from: "sleep 0\n"))
    }

    func testPowerAndACSleepParsing() {
        XCTAssertEqual(
            PowerInspector.parsePowerSource(from: "Now drawing from 'AC Power'\n"),
            .ac
        )
        XCTAssertEqual(
            PowerInspector.parsePowerSource(from: "Now drawing from 'Battery Power'\n -InternalBattery-0\t35%; discharging;\n"),
            .battery(percent: 35)
        )
        XCTAssertEqual(
            PowerInspector.parseACIdleSleep(from: "Battery Power:\n sleep 7\nAC Power:\n sleep 3\n"),
            3
        )
    }

    func testHelperStatusRequiresTimestampAndRejectsDuplicates() {
        XCTAssertNil(HelperStatusRecord.parse("state=active\nreason=verified\nsession=none\n"))
        XCTAssertNil(HelperStatusRecord.parse("state=active\nstate=active\nreason=verified\nsession=none\nupdated=1\n"))
        XCTAssertNotNil(HelperStatusRecord.parse("state=inactive\nreason=restored\nsession=none\nupdated=1\n"))
    }

    func testLeaseParserRejectsDuplicateAndUnknownFields() {
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        XCTAssertNotNil(ActivationLease.parse(lease.storagePayload))
        XCTAssertNil(ActivationLease.parse(lease.storagePayload + "session=\(UUID())\n"))
        XCTAssertNil(ActivationLease.parse(lease.storagePayload + "unexpected=value\n"))
    }

    func testLeaseRejectsRebootExpiryAndExcessiveLifetime() {
        let now = Date()
        let mono = MonotonicClock.seconds()
        let lease = makeLease(sessionID: UUID(), lifetime: 30, now: now, monotonic: mono)

        XCTAssertEqual(
            lease.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: "different-boot",
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .bootMismatch
        )

        let expired = ActivationLease(
            sessionID: lease.sessionID,
            bootID: lease.bootID,
            expiresAt: now.addingTimeInterval(-1),
            issuedMonotonic: mono - 20,
            expiresMonotonic: mono - 1,
            ownerUID: getuid(),
            systemBuild: lease.systemBuild
        )
        XCTAssertEqual(
            expired.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: lease.bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .expired
        )

        let excessive = ActivationLease(
            sessionID: lease.sessionID,
            bootID: lease.bootID,
            expiresAt: now.addingTimeInterval(60),
            issuedMonotonic: mono,
            expiresMonotonic: mono + 60,
            ownerUID: getuid(),
            systemBuild: lease.systemBuild
        )
        XCTAssertEqual(
            excessive.validationFailure(
                now: now,
                nowMonotonic: mono,
                currentBootID: lease.bootID,
                expectedOwnerUID: getuid(),
                currentSystemBuild: lease.systemBuild
            ),
            .excessiveLifetime
        )
    }

    func testSecureLeaseReaderRejectsSymlinkWritableAndMalformedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let real = support.appendingPathComponent("real-lease")
        let link = support.appendingPathComponent("activation-lease")
        let lease = makeLease(sessionID: UUID(), lifetime: 30)
        try lease.storagePayload.write(to: real, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(real.path, 0o600), 0)
        XCTAssertEqual(symlink(real.path, link.path), 0)

        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .unsafeFile
        )

        XCTAssertEqual(unlink(link.path), 0)
        try lease.storagePayload.write(to: link, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(link.path, 0o666), 0)
        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .unsafeFile
        )

        try "not-a-lease\n".write(to: link, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(link.path, 0o600), 0)
        assertLeaseFailure(
            SecureLeaseReader.load(path: link.path, expectedOwnerUID: getuid()),
            equals: .malformed
        )
    }

    func testAppliedStateRejectsStaleZeroBaselineAndUnsafeFile() throws {
        XCTAssertNil(AppliedState.parse("session=\(UUID())\nchanged_sleep_disabled=1\nchanged_ac_sleep=1\noriginal_ac_sleep=0\n"))

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let statePath = root.appendingPathComponent("applied-state").path
        let state = AppliedState(
            sessionID: UUID(),
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 5
        )
        try AppliedStateStore.write(state, path: statePath)
        XCTAssertEqual(AppliedStateStore.load(path: statePath), .success(state))
        XCTAssertEqual(chmod(statePath, 0o666), 0)
        XCTAssertEqual(AppliedStateStore.load(path: statePath), .invalid)
    }

    func testNativeHelperExpiresLeaseAndRestoresOwnedChanges() throws {
        let harness = try makeRuntimeHarness(lifetime: 1)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.power.currentSleepDisabled, false)
        XCTAssertEqual(harness.power.currentACSleep, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testNativeHelperUnplugRestoresAndDoesNotRearmOnReconnect() throws {
        let harness = try makeRuntimeHarness(lifetime: 10)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            harness.power.setSource(.battery)
        }
        let code = harness.runtime.run()
        let activationCalls = harness.power.enableSleepOverrideCalls
        harness.power.setSource(.ac)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.power.currentSleepDisabled, false)
        XCTAssertEqual(harness.power.currentACSleep, 5)
        XCTAssertEqual(activationCalls, 1)
        XCTAssertEqual(harness.power.enableSleepOverrideCalls, 1)
    }

    func testNativeHelperRetainsAppliedStateAndExitsCleanlyWhenRestoreCannotBeVerified() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.failSleepRestore = true
        let harness = try makeRuntimeHarness(lifetime: 1, power: power)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=recovery-required"))
    }

    func testNativeHelperRollsBackWhenPowerChangesDuringActivation() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5)
        power.unplugWhenEnablingSleepOverride = true
        let harness = try makeRuntimeHarness(lifetime: 5, power: power)

        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
        XCTAssertEqual(power.enableSleepOverrideCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
        XCTAssertTrue(try String(contentsOfFile: harness.configuration.statusPath).contains("state=inactive"))
    }

    func testNativeHelperRecoversMatchingAppliedSessionAfterAbnormalExit() throws {
        let power = FakePowerSystem(source: .ac, sleepDisabled: true, acSleep: 0)
        let harness = try makeRuntimeHarness(lifetime: 1, power: power, preapplyState: true)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertEqual(power.currentACSleep, 5)
    }

    func testUnknownPowerSourceNeverActivatesHelper() throws {
        let power = FakePowerSystem(source: .unknown, sleepDisabled: false, acSleep: 5)
        let harness = try makeRuntimeHarness(lifetime: 5, power: power)
        let code = harness.runtime.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(power.enableSleepOverrideCalls, 0)
        XCTAssertEqual(power.currentSleepDisabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configuration.appliedStatePath))
    }

    func testLaunchDaemonIsEventDrivenAndCrashOnly() throws {
        let plist = PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let keepAlive = try XCTUnwrap(decoded["KeepAlive"] as? [String: Any])

        XCTAssertFalse(plist.contains("StartInterval"))
        XCTAssertNotNil(decoded["WatchPaths"] as? [String])
        XCTAssertEqual(keepAlive["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(decoded["ThrottleInterval"] as? Int, 10)
    }

    func testNormalAdminPathsAreOwnershipAwareAndForceRestoreIsExplicit() {
        let install = PrivilegedHelperManager.diagnosticInstallScript()
        let uninstall = PrivilegedHelperManager.diagnosticUninstallScript()
        let restore = PrivilegedHelperManager.diagnosticRestoreScript()

        XCTAssertTrue(install.contains("force=0"))
        XCTAssertTrue(uninstall.contains("force=0"))
        XCTAssertTrue(restore.contains("force=1"))
        XCTAssertTrue(install.contains("lidswitch_parse_applied_state"))
        XCTAssertTrue(uninstall.contains("lidswitch_parse_applied_state"))
        XCTAssertTrue(restore.contains("|0) return 1"))
        XCTAssertTrue(restore.contains("alarm(shift @ARGV)"))
        XCTAssertTrue(restore.contains("if [ \"$changed_ac\" = \"0\" ]"))
        XCTAssertTrue(install.contains("[ \"$owner\" = \"$(/usr/bin/id -u)\" ] && [ \"$links\" = \"1\" ]"))
        XCTAssertFalse(install.contains("[ \"$group\" = \"$(/usr/bin/id -g)\" ]"))
        XCTAssertFalse(install.contains("StartInterval"))
        XCTAssertFalse(install.contains(AppPaths.legacyLoginLabel))
    }

    func testAdministratorCommandSkipsUserZshStartupFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startupMarker = root.appendingPathComponent("startup-sourced")
        let commandMarker = root.appendingPathComponent("command-ran")
        try "/usr/bin/touch \(startupMarker.path)\n".write(
            to: root.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )

        let command = PrivilegedHelperManager.diagnosticAdministratorCommand(
            "/usr/bin/touch \(commandMarker.path)\n"
        )
        XCTAssertTrue(command.hasSuffix("| /bin/zsh -f"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = root.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: startupMarker.path))
    }

    func testAdminRestoreMigratesValidLegacyACBaseline() throws {
        let result = try runAdminRestoreScenario(legacyAC: "5", currentACSleep: 0)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 5)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreMigratesRootAdminLegacyACBaseline() throws {
        let result = try runAdminRestoreScenario(
            legacyAC: "5",
            currentACSleep: 0,
            legacyACGroup: 80
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 5)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreRejectsGroupWritableLegacyBaseline() throws {
        let result = try runAdminRestoreScenario(
            legacyAC: "5",
            currentACSleep: 0,
            legacyACMode: 0o664
        )

        XCTAssertEqual(result.exitCode, 75, result.stderr)
        XCTAssertEqual(result.acSleep, 0)
        XCTAssertTrue(result.legacyFileExists)
        XCTAssertTrue(result.stderr.contains("reason=unsafe-legacy-state"))
    }

    func testAdminRestoreIgnoresStaleZeroLegacyBaseline() throws {
        let result = try runAdminRestoreScenario(legacyAC: "0", currentACSleep: 0)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 0)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreDoesNotOverwriteSupersedingACValue() throws {
        let result = try runAdminRestoreScenario(legacyAC: "5", currentACSleep: 7)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.acSleep, 7)
        XCTAssertFalse(result.legacyFileExists)
    }

    func testAdminRestoreMigratesLegacyBatteryBaselineAndClearsSleepDisabled() throws {
        let result = try runAdminRestoreScenario(
            legacyAC: nil,
            currentACSleep: 5,
            legacyBattery: "9",
            currentBatterySleep: 0,
            sleepDisabled: 1
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.batterySleep, 9)
        XCTAssertEqual(result.sleepDisabled, 0)
        XCTAssertFalse(result.legacyBatteryFileExists)
    }

    func testHelperConfigurationRejectsMissingAndDuplicateArguments() {
        let valid = [
            "LidSwitchHelper", "--lease-path", "/tmp/lease", "--owner-uid", "501",
            "--qualified-build", "25F84", "--support-directory", "/tmp/support",
            "--applied-state", "/tmp/support/state", "--status-path", "/tmp/support/status",
        ]
        XCTAssertNotNil(HelperConfiguration.parse(arguments: valid))
        XCTAssertNil(HelperConfiguration.parse(arguments: Array(valid.dropLast())))
        XCTAssertNil(HelperConfiguration.parse(arguments: valid + ["--lease-path", "/tmp/other"]))
    }

    private func makeSnapshot(
        source: PowerSource,
        sleepDisabled: Bool,
        sleepDisabledVerified: Bool,
        legacyLoginItemLoaded: Bool = false,
        lease: ActivationLease? = nil,
        status: HelperStatusRecord? = nil,
        checkedAt: Date = Date(),
        ownsLease: Bool = true
    ) -> PowerSnapshot {
        PowerSnapshot(
            source: source,
            sleepDisabled: sleepDisabled,
            sleepDisabledVerified: sleepDisabledVerified,
            acIdleSleepMinutes: 5,
            preferences: .disabled,
            helperArtifactsPresent: true,
            helperLoaded: true,
            helperNeedsUpdate: false,
            legacyLoginItemPresent: false,
            legacyLoginItemLoaded: legacyLoginItemLoaded,
            activationLease: lease,
            ownedSessionID: ownsLease ? lease?.sessionID : nil,
            helperStatus: status,
            systemBuild: "25F84",
            systemBuildQualified: true,
            bundleIntegrityValid: true,
            bundleVersionValid: true,
            checkedAt: checkedAt
        )
    }

    private func makeLease(
        sessionID: UUID,
        lifetime: TimeInterval,
        now: Date = Date(),
        monotonic: TimeInterval = MonotonicClock.seconds()
    ) -> ActivationLease {
        ActivationLease(
            sessionID: sessionID,
            bootID: BootIdentity.current() ?? "test-boot",
            expiresAt: now.addingTimeInterval(lifetime),
            issuedMonotonic: monotonic,
            expiresMonotonic: monotonic + lifetime,
            ownerUID: getuid(),
            systemBuild: "25F84"
        )
    }

    private func assertLeaseFailure(
        _ result: Result<ActivationLease, LeaseValidationFailure>,
        equals expected: LeaseValidationFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected lease failure", file: file, line: line)
        case let .failure(actual):
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LidSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private struct AdminRestoreResult {
        let exitCode: Int32
        let acSleep: Int
        let batterySleep: Int
        let sleepDisabled: Int
        let legacyFileExists: Bool
        let legacyBatteryFileExists: Bool
        let stderr: String
    }

    private func runAdminRestoreScenario(
        legacyAC: String?,
        currentACSleep: Int,
        legacyACGroup: gid_t? = nil,
        legacyACMode: mode_t? = nil,
        legacyBattery: String? = nil,
        currentBatterySleep: Int = 5,
        sleepDisabled: Int = 0
    ) throws -> AdminRestoreResult {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("power", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        try "\(sleepDisabled)\n".write(to: state.appendingPathComponent("sleep-disabled"), atomically: true, encoding: .utf8)
        try "\(currentACSleep)\n".write(to: state.appendingPathComponent("ac-sleep"), atomically: true, encoding: .utf8)
        try "\(currentBatterySleep)\n".write(to: state.appendingPathComponent("battery-sleep"), atomically: true, encoding: .utf8)

        let mockPMSet = root.appendingPathComponent("pmset")
        let mockSource = """
        #!/bin/sh
        set -eu
        state="${MOCK_POWER_STATE:?}"
        printf 'state=%s args=%s\n' "$state" "$*" >> "$state/calls.log"
        if [ "$1" = "-g" ] && [ "$2" = "live" ]; then
          output="SleepDisabled $(/bin/cat "$state/sleep-disabled")"
          echo "$output"
        elif [ "$1" = "-g" ] && [ "$2" = "custom" ]; then
          echo "Battery Power:"
          echo " sleep $(/bin/cat "$state/battery-sleep")"
          echo "AC Power:"
          echo " sleep $(/bin/cat "$state/ac-sleep")"
        elif [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
          printf '%s\n' "$3" > "$state/sleep-disabled"
        elif [ "$1" = "-c" ] && [ "$2" = "sleep" ]; then
          printf '%s\n' "$3" > "$state/ac-sleep"
        elif [ "$1" = "-b" ] && [ "$2" = "sleep" ]; then
          printf '%s\n' "$3" > "$state/battery-sleep"
        else
          exit 64
        fi
        """
        try mockSource.write(to: mockPMSet, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(mockPMSet.path, 0o755), 0)

        let applied = support.appendingPathComponent("applied-state").path
        let status = support.appendingPathComponent("helper-status").path
        let legacyACPath = support.appendingPathComponent("original-ac-sleep").path
        let legacyBatteryPath = support.appendingPathComponent("original-battery-sleep").path
        if let legacyAC {
            try "\(legacyAC)\n".write(toFile: legacyACPath, atomically: true, encoding: .utf8)
            if let legacyACGroup {
                XCTAssertEqual(chown(legacyACPath, getuid(), legacyACGroup), 0)
            }
            if let legacyACMode {
                XCTAssertEqual(chmod(legacyACPath, legacyACMode), 0)
            }
        }
        if let legacyBattery {
            try "\(legacyBattery)\n".write(toFile: legacyBatteryPath, atomically: true, encoding: .utf8)
        }

        var script = PrivilegedHelperManager.diagnosticNormalRestoreScriptForTesting()
        for (original, replacement) in [
            (AppPaths.rootAppliedStatePath, applied),
            (AppPaths.rootHelperStatusPath, status),
            (AppPaths.rootOriginalACSleepPath, legacyACPath),
            (AppPaths.rootOriginalBatterySleepPath, legacyBatteryPath),
            ("5 /usr/bin/pmset", "5 \(mockPMSet.path)"),
        ] {
            script = script.replacingOccurrences(of: original, with: replacement)
        }
        let scriptFile = root.appendingPathComponent("restore.zsh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", scriptFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MOCK_POWER_STATE"] = state.path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        var errorText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        if let statusText = try? String(contentsOfFile: status, encoding: .utf8) {
            errorText += "\nstatus:\n\(statusText)"
        }
        if let callLog = try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8) {
            errorText += "\npmset calls:\n\(callLog)"
        }
        let finalAC = try XCTUnwrap(
            Int(String(contentsOf: state.appendingPathComponent("ac-sleep"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let finalBattery = try XCTUnwrap(
            Int(String(contentsOf: state.appendingPathComponent("battery-sleep"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let finalSleepDisabled = try XCTUnwrap(
            Int(String(contentsOf: state.appendingPathComponent("sleep-disabled"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        return AdminRestoreResult(
            exitCode: process.terminationStatus,
            acSleep: finalAC,
            batterySleep: finalBattery,
            sleepDisabled: finalSleepDisabled,
            legacyFileExists: FileManager.default.fileExists(atPath: legacyACPath),
            legacyBatteryFileExists: FileManager.default.fileExists(atPath: legacyBatteryPath),
            stderr: errorText
        )
    }

    private struct RuntimeHarness {
        let root: URL
        let configuration: HelperConfiguration
        let power: FakePowerSystem
        let runtime: HelperRuntime
    }

    private func makeRuntimeHarness(
        lifetime: TimeInterval,
        power: FakePowerSystem = FakePowerSystem(source: .ac, sleepDisabled: false, acSleep: 5),
        preapplyState: Bool = false
    ) throws -> RuntimeHarness {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let userSupport = root.appendingPathComponent("user", isDirectory: true)
        let rootSupport = root.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: userSupport, withIntermediateDirectories: false)
        let leasePath = userSupport.appendingPathComponent("activation-lease").path
        let statePath = rootSupport.appendingPathComponent("applied-state").path
        let statusPath = rootSupport.appendingPathComponent("helper-status").path
        let lease = makeLease(sessionID: UUID(), lifetime: lifetime)
        try lease.storagePayload.write(toFile: leasePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(leasePath, 0o600), 0)
        try FileManager.default.createDirectory(at: rootSupport, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(rootSupport.path, 0o755), 0)

        if preapplyState {
            try AppliedStateStore.write(
                AppliedState(
                    sessionID: lease.sessionID,
                    changedSleepDisabled: true,
                    changedACSleep: true,
                    originalACSleep: 5
                ),
                path: statePath
            )
        }

        let configuration = HelperConfiguration(
            leasePath: leasePath,
            expectedOwnerUID: getuid(),
            qualifiedBuild: "25F84",
            supportDirectory: rootSupport.path,
            appliedStatePath: statePath,
            statusPath: statusPath
        )
        return RuntimeHarness(
            root: root,
            configuration: configuration,
            power: power,
            runtime: HelperRuntime(
                configuration: configuration,
                power: power,
                currentBootID: { lease.bootID },
                currentSystemBuild: { "25F84" }
            )
        )
    }
}

private final class FakePowerSystem: HelperPowerSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var source: HelperPowerSource
    private var sleepDisabledValue: Bool?
    private var acSleepValue: Int?
    private var enableCalls = 0
    private var failRestoreValue = false
    private var unplugOnEnableValue = false

    init(source: HelperPowerSource, sleepDisabled: Bool?, acSleep: Int?) {
        self.source = source
        sleepDisabledValue = sleepDisabled
        acSleepValue = acSleep
    }

    var currentSleepDisabled: Bool? { withLock { sleepDisabledValue } }
    var currentACSleep: Int? { withLock { acSleepValue } }
    var enableSleepOverrideCalls: Int { withLock { enableCalls } }
    var failSleepRestore: Bool {
        get { withLock { failRestoreValue } }
        set { withLock { failRestoreValue = newValue } }
    }
    var unplugWhenEnablingSleepOverride: Bool {
        get { withLock { unplugOnEnableValue } }
        set { withLock { unplugOnEnableValue = newValue } }
    }

    func setSource(_ source: HelperPowerSource) {
        withLock { self.source = source }
    }

    func powerSource() -> HelperPowerSource { withLock { source } }
    func sleepDisabled() -> Bool? { withLock { sleepDisabledValue } }
    func acSleepMinutes() -> Int? { withLock { acSleepValue } }

    func setSleepDisabled(_ enabled: Bool) throws {
        try withLock {
            if !enabled, failRestoreValue {
                throw NSError(domain: "FakePowerSystem", code: 1)
            }
            if enabled {
                enableCalls += 1
                if unplugOnEnableValue {
                    source = .battery
                }
            }
            sleepDisabledValue = enabled
        }
    }

    func setACSleepMinutes(_ minutes: Int) throws {
        withLock { acSleepValue = minutes }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
