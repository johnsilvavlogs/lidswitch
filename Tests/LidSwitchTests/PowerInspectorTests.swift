import Darwin
import XCTest
@testable import LidSwitch

final class PowerInspectorTests: XCTestCase {
    func testParsesACPowerSource() {
        let output = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=25165923)	35%; charging; 1:05 remaining present: true
        """

        XCTAssertEqual(PowerInspector.parsePowerSource(from: output), .ac)
    }

    func testParsesBatteryPowerSourceAndPercent() {
        let output = """
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=25165923)	35%; discharging; 1:05 remaining present: true
        """

        XCTAssertEqual(PowerInspector.parsePowerSource(from: output), .battery(percent: 35))
    }

    func testParsesSleepDisabled() {
        let output = """
        System-wide power settings:
         SleepDisabled		1
        Currently in use:
         sleep                0
        """

        XCTAssertTrue(PowerInspector.parseSleepDisabled(from: output))
    }

    func testParsesACIdleSleep() {
        let output = """
        Battery Power:
         sleep                1
        AC Power:
         displaysleep         10
         sleep                0
        """

        XCTAssertEqual(PowerInspector.parseACIdleSleep(from: output), 0)
    }

    func testParsesBatteryIdleSleep() {
        let output = """
        Battery Power:
         displaysleep         10
         sleep                7
        AC Power:
         sleep                0
        """

        XCTAssertEqual(PowerInspector.parseBatteryIdleSleep(from: output), 7)
    }

    func testLegacyEnabledPreferencesStayACOnly() {
        let preferences = PowerPreferences.parse("enabled\n")

        XCTAssertTrue(preferences.keepAwakeEnabled)
        XCTAssertFalse(preferences.allowBatteryKeepAwake)
    }

    func testKeyValuePreferencesCanAllowBattery() {
        let preferences = PowerPreferences.parse("""
        mode=enabled
        battery=enabled
        """)

        XCTAssertEqual(
            preferences,
            PowerPreferences(keepAwakeEnabled: true, allowBatteryKeepAwake: true)
        )
    }

    func testDisabledPreferencesDropBatteryOptIn() {
        let preferences = PowerPreferences.parse("""
        mode=disabled
        battery=enabled
        """)

        XCTAssertFalse(preferences.keepAwakeEnabled)
        XCTAssertFalse(preferences.allowBatteryKeepAwake)
        XCTAssertEqual(preferences.storagePayload, "mode=disabled\nbattery=disabled\n")
    }

    func testBatteryKeepAwakeRequiresBothToggles() {
        let acOnly = PowerPolicy.decision(
            preferences: .acOnlyEnabled,
            source: .battery(percent: 40)
        )
        let batteryAllowed = PowerPolicy.decision(
            preferences: PowerPreferences(keepAwakeEnabled: true, allowBatteryKeepAwake: true),
            source: .battery(percent: 40)
        )
        let disabled = PowerPolicy.decision(
            preferences: PowerPreferences(keepAwakeEnabled: false, allowBatteryKeepAwake: true),
            source: .battery(percent: 40)
        )

        XCTAssertFalse(acOnly.sleepDisabledShouldBeOn)
        XCTAssertFalse(acOnly.batterySleepShouldBeNever)
        XCTAssertTrue(acOnly.restoreBatterySleep)
        XCTAssertTrue(batteryAllowed.sleepDisabledShouldBeOn)
        XCTAssertTrue(batteryAllowed.batterySleepShouldBeNever)
        XCTAssertFalse(batteryAllowed.restoreBatterySleep)
        XCTAssertFalse(disabled.sleepDisabledShouldBeOn)
        XCTAssertTrue(disabled.restoreBatterySleep)
    }

    func testACKeepAwakeCanArmBatteryProfileOnlyWhenAllowed() {
        let acOnly = PowerPolicy.decision(
            preferences: .acOnlyEnabled,
            source: .ac
        )
        let batteryAllowed = PowerPolicy.decision(
            preferences: PowerPreferences(keepAwakeEnabled: true, allowBatteryKeepAwake: true),
            source: .ac
        )

        XCTAssertTrue(acOnly.sleepDisabledShouldBeOn)
        XCTAssertTrue(acOnly.acSleepShouldBeNever)
        XCTAssertFalse(acOnly.batterySleepShouldBeNever)
        XCTAssertTrue(acOnly.restoreBatterySleep)
        XCTAssertTrue(batteryAllowed.sleepDisabledShouldBeOn)
        XCTAssertTrue(batteryAllowed.acSleepShouldBeNever)
        XCTAssertTrue(batteryAllowed.batterySleepShouldBeNever)
        XCTAssertFalse(batteryAllowed.restoreBatterySleep)
    }

    func testSnapshotWarnsWhenBatteryModeIsOffWhileOnBattery() {
        let snapshot = PowerSnapshot(
            source: .battery(percent: 91),
            sleepDisabled: false,
            acIdleSleepMinutes: 0,
            batteryIdleSleepMinutes: 1,
            preferences: .acOnlyEnabled,
            helperInstalled: true,
            helperNeedsUpdate: false,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.statusTitle, "Battery sleep allowed")
        XCTAssertEqual(snapshot.statusDetail, "Battery mode is off. Closing the lid on battery will still sleep.")
        XCTAssertTrue(snapshot.batterySleepAllowedNow)
    }

    func testSnapshotExplainsBatteryOverrideClearingWhenPolicyAndSystemDrift() {
        let snapshot = PowerSnapshot(
            source: .battery(percent: 70),
            sleepDisabled: true,
            acIdleSleepMinutes: 0,
            batteryIdleSleepMinutes: 1,
            preferences: .acOnlyEnabled,
            helperInstalled: true,
            helperNeedsUpdate: false,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.statusTitle, "Clearing battery override")
        XCTAssertEqual(snapshot.statusDetail, "Battery mode is off. The helper is clearing the sleep override now.")
        XCTAssertTrue(snapshot.batterySleepAllowedNow)
    }

    func testSnapshotStillShowsPluggedInProtectionWhenACOnlyIsActiveOnAC() {
        let snapshot = PowerSnapshot(
            source: .ac,
            sleepDisabled: true,
            acIdleSleepMinutes: 0,
            batteryIdleSleepMinutes: 1,
            preferences: .acOnlyEnabled,
            helperInstalled: true,
            helperNeedsUpdate: false,
            checkedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.statusTitle, "Keeping awake when plugged in")
        XCTAssertEqual(snapshot.statusDetail, "Lid-close sleep is blocked while charging. Battery lid-close sleep remains allowed.")
        XCTAssertFalse(snapshot.batterySleepAllowedNow)
    }

    func testCurrentHelperArtifactsDoNotNeedUpdate() {
        XCTAssertFalse(
            PowerInspector.helperNeedsUpdate(
                helperInstalled: true,
                installedVersion: "\(AppPaths.helperVersion)\n",
                installedHelperScript: PrivilegedHelperManager.diagnosticHelperScript(),
                installedLaunchDaemonPlist: PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
            )
        )
    }

    func testPrivilegedInstallScriptDoesNotWriteUserDesiredStateAsRoot() {
        let script = PrivilegedHelperManager.diagnosticInstallScript(initialPreferences: .acOnlyEnabled)

        XCTAssertFalse(script.contains("/bin/cat > \"$desired_state_file\""))
        XCTAssertFalse(script.contains("/usr/sbin/chown \(getuid()):\(getgid()) \"$desired_state_file\""))
        XCTAssertFalse(script.contains("/bin/chmod 0644 \"$desired_state_file\""))
        XCTAssertFalse(script.contains("user_support_dir="))
        XCTAssertTrue(script.contains("state_file='\(AppPaths.desiredStateFile.path)'"))
    }

    func testPrivilegedUninstallScriptDoesNotWriteUserDesiredStateAsRoot() {
        let script = PrivilegedHelperManager.diagnosticUninstallScript()

        XCTAssertFalse(script.contains("desired_state_file="))
        XCTAssertFalse(script.contains("/bin/cat > \"$desired_state_file\""))
        XCTAssertFalse(script.contains("/usr/sbin/chown \(getuid()):\(getgid()) \"$desired_state_file\""))
        XCTAssertFalse(script.contains("/bin/chmod 0644 \"$desired_state_file\""))
    }

    func testPrivilegedHelperScriptFailsClosedOnSymlinkedDesiredState() {
        let script = PrivilegedHelperManager.diagnosticHelperScript()

        XCTAssertTrue(script.contains("[ -L \"$state_file\" ] || [ ! -f \"$state_file\" ]"))
    }

    func testDesiredStateStoreWritesRegularStateFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)

        try DesiredStateStore.write(
            .acOnlyEnabled,
            supportDirectory: supportDirectory,
            stateFile: stateFile
        )

        XCTAssertEqual(
            try String(contentsOf: stateFile, encoding: .utf8),
            PowerPreferences.acOnlyEnabled.storagePayload
        )
    }

    func testDesiredStateStoreRejectsSymlinkedSupportDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(target.path, supportDirectory.path), 0)

        XCTAssertThrowsError(
            try DesiredStateStore.write(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
    }

    func testDesiredStateStoreRejectsNonDirectorySupportPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        try "not a directory".write(to: supportDirectory, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try DesiredStateStore.write(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
    }

    func testDesiredStateStoreRejectsSymlinkedStateFileWithoutTouchingTarget() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        let target = root.appendingPathComponent("target-state", isDirectory: false)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try "keep this\n".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(symlink(target.path, stateFile.path), 0)

        XCTAssertThrowsError(
            try DesiredStateStore.write(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep this\n")
    }

    func testDesiredStateStoreRejectsNonRegularStateFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(stateFile.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertThrowsError(
            try DesiredStateStore.write(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
    }

    func testHelperLifecycleDesiredStateIgnoresUnsafeStateFileWithoutTouchingTarget() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        let target = root.appendingPathComponent("target-state", isDirectory: false)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try "keep this\n".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(symlink(target.path, stateFile.path), 0)

        XCTAssertNoThrow(
            try HelperLifecycleDesiredState.writeBestEffort(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep this\n")
    }

    func testHelperLifecycleDesiredStateIgnoresNonRegularStateFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(stateFile.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertNoThrow(
            try HelperLifecycleDesiredState.writeBestEffort(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
    }

    func testHelperLifecycleDesiredStateIgnoresUnsafeSupportDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = supportDirectory.appendingPathComponent("desired-state", isDirectory: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(target.path, supportDirectory.path), 0)

        XCTAssertNoThrow(
            try HelperLifecycleDesiredState.writeBestEffort(
                .disabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
    }

    func testHelperLifecycleDesiredStateStillThrowsNonUnsafeWriteFailures() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("LidSwitch", isDirectory: true)
        let stateFile = root.appendingPathComponent("missing-parent/desired-state", isDirectory: false)

        XCTAssertThrowsError(
            try HelperLifecycleDesiredState.writeBestEffort(
                .acOnlyEnabled,
                supportDirectory: supportDirectory,
                stateFile: stateFile
            )
        )
    }

    func testInstalledHelperArtifactsAllowShellTrailingNewline() {
        XCTAssertFalse(
            PowerInspector.helperNeedsUpdate(
                helperInstalled: true,
                installedVersion: "\(AppPaths.helperVersion)\n",
                installedHelperScript: PrivilegedHelperManager.diagnosticHelperScript() + "\n",
                installedLaunchDaemonPlist: PrivilegedHelperManager.diagnosticLaunchDaemonPlist() + "\n"
            )
        )
    }

    func testMissingLoadedHelperDoesNotShowUpdateInsteadOfInstall() {
        XCTAssertFalse(
            PowerInspector.helperNeedsUpdate(
                helperInstalled: false,
                installedVersion: "stale",
                installedHelperScript: nil,
                installedLaunchDaemonPlist: nil
            )
        )
    }

    func testStaleHelperArtifactsNeedUpdateEvenWhenVersionMatches() {
        XCTAssertTrue(
            PowerInspector.helperNeedsUpdate(
                helperInstalled: true,
                installedVersion: "\(AppPaths.helperVersion)\n",
                installedHelperScript: "#!/bin/zsh\nexit 0\n",
                installedLaunchDaemonPlist: PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
            )
        )

        XCTAssertTrue(
            PowerInspector.helperNeedsUpdate(
                helperInstalled: true,
                installedVersion: "\(AppPaths.helperVersion)\n",
                installedHelperScript: PrivilegedHelperManager.diagnosticHelperScript(),
                installedLaunchDaemonPlist: "<plist><dict/></plist>\n"
            )
        )
    }

    func testStaleHelperVersionNeedsUpdate() {
        XCTAssertTrue(
            PowerInspector.helperNeedsUpdate(
                helperInstalled: true,
                installedVersion: "1\n",
                installedHelperScript: PrivilegedHelperManager.diagnosticHelperScript(),
                installedLaunchDaemonPlist: PrivilegedHelperManager.diagnosticLaunchDaemonPlist()
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
