import Darwin
import Foundation
import XCTest
@testable import LidSwitchCore
@testable import LidSwitchHelper

/// Source-only deterministic fixtures for the shipped v0.1 no-session-UUID
/// boundary. These fixtures use an owned /private/tmp capability and fake
/// native power; they never launch the app/helper, inspect launchd, or invoke
/// pmset. Runtime execution remains behind the manager's incident gate.
final class LegacyMigrationFixtureTests: XCTestCase {
    func testHelperOnlyHistoryIsMigratedNotPristineAndReadsNoTimerDuringMigration() throws {
        let fixture = try LegacyFixture(disabled: false, ac: nil, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyHelper()

        XCTAssertEqual(fixture.provisionAndRecover(), .migratedIdle("legacy-migration"))
        XCTAssertEqual(
            fixture.store.proof(),
            RecoveryProof(kind: .migrated, sessionID: nil, reason: "legacy-migration")
        )
        XCTAssertEqual(fixture.power.acReads, 0)
        XCTAssertEqual(fixture.power.batteryReads, 0)
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertNotEqual(fixture.store.proof()?.kind, .pristine)
    }

    func testRepeatedInventoryNeverForgetsRecognizedHistory() throws {
        let fixture = try LegacyFixture(disabled: false, ac: nil, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyHelper()

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertTrue(fixture.store.authorityRootInventoryIsSafe)
        XCTAssertEqual(fixture.store.prepareAuthorityAfterWriterQuiescence(), .ready)
        XCTAssertNotEqual(fixture.store.proof()?.kind, .pristine)
        XCTAssertNotEqual(fixture.store.journalRecord(), .absent)
    }

    func testHelperOnlyActiveSleepOverrideIsAmbiguousAndNeverCleared() throws {
        let fixture = try LegacyFixture(disabled: true, ac: nil, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyHelper()

        XCTAssertEqual(
            fixture.provisionAndRecover(),
            .recoveryRequired("legacy-sleep-override-ambiguous")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.power.disabled, true)
        XCTAssertNotEqual(fixture.store.journalRecord(), .absent)
    }

    func testDaemonObservationBeforeWriterQuiescenceMutatesOnlyTheExplicitLock() throws {
        let fixture = try LegacyFixture(disabled: true, ac: 0, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyHelper()
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 8)
        let timerBytes = try fixture.read(RecoveryAuthorityStore.legacyACBasename)

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(
            fixture.coordinator.recover(intent: .startup, allowReconnect: true),
            .recoveryRequired("legacy-writers-not-quiesced")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertNil(fixture.store.proof())
        XCTAssertEqual(fixture.store.journalRecord(), .absent)
        XCTAssertEqual(fixture.store.ledger(RecoveryAuthorityStore.terminalBasename), .absent)
        XCTAssertEqual(fixture.store.ledger(RecoveryAuthorityStore.reservationBasename), .absent)
        XCTAssertEqual(try fixture.read(RecoveryAuthorityStore.legacyACBasename), timerBytes)
    }

    func testTimerTargetsCoverZeroEqualRestoreAndSupersededWithoutOverwriting() throws {
        struct Case {
            let target: Int
            let current: Int
            let expectedCurrent: Int
            let expectedTimerSet: Bool
            let expectedReason: String
        }
        let cases = [
            Case(target: 0, current: 0, expectedCurrent: 0, expectedTimerSet: false, expectedReason: "legacy-migration"),
            Case(target: 9, current: 9, expectedCurrent: 9, expectedTimerSet: false, expectedReason: "legacy-migration"),
            Case(target: 9, current: 0, expectedCurrent: 9, expectedTimerSet: true, expectedReason: "legacy-migration"),
            Case(target: 9, current: 12, expectedCurrent: 12, expectedTimerSet: false,
                 expectedReason: "legacy-migration-superseded"),
            Case(target: 0, current: 12, expectedCurrent: 12, expectedTimerSet: false,
                 expectedReason: "legacy-migration-superseded"),
        ]
        for test in cases {
            let fixture = try LegacyFixture(disabled: true, ac: test.current, battery: nil)
            defer { fixture.dispose() }
            try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: test.target)

            XCTAssertEqual(
                fixture.provisionAndRecover(),
                .migratedIdle(test.expectedReason),
                "target=\(test.target) current=\(test.current)"
            )
            XCTAssertEqual(fixture.power.disabled, false)
            XCTAssertEqual(fixture.power.ac, test.expectedCurrent)
            XCTAssertEqual(fixture.power.setCalls.contains("ac=\(test.target)"), test.expectedTimerSet)
            XCTAssertFalse(fixture.power.setCalls.contains("ac=0"), "migration must never rearm")
        }
    }

    func testBatteryEvidenceUsesTheSameConditionalNonDestructiveSemantics() throws {
        let restored = try LegacyFixture(disabled: true, ac: nil, battery: 0)
        defer { restored.dispose() }
        try restored.installLegacyTimer(RecoveryAuthorityStore.legacyBatteryBasename, value: 11)
        XCTAssertEqual(restored.provisionAndRecover(), .migratedIdle("legacy-migration"))
        XCTAssertEqual(restored.power.battery, 11)
        XCTAssertTrue(restored.power.setCalls.contains("battery=11"))
        XCTAssertEqual(restored.power.acReads, 0)

        let superseded = try LegacyFixture(disabled: false, ac: nil, battery: 6)
        defer { superseded.dispose() }
        try superseded.installLegacyTimer(RecoveryAuthorityStore.legacyBatteryBasename, value: 11)
        XCTAssertEqual(
            superseded.provisionAndRecover(),
            .migratedIdle("legacy-migration-superseded")
        )
        XCTAssertEqual(superseded.power.battery, 6)
        XCTAssertFalse(superseded.power.setCalls.contains("battery=11"))
    }

    func testPositiveTimerAppearingAtMutationBoundaryIsPreserved() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 9)
        fixture.power.scriptedACReads = [0, 12]

        XCTAssertEqual(
            fixture.provisionAndRecover(),
            .recoveryRequired("legacy-timer-superseded")
        )
        XCTAssertEqual(fixture.power.ac, 12)
        XCTAssertFalse(fixture.power.setCalls.contains("ac=9"))
    }

    func testNilRequiredNativeFieldsPreserveEvidenceAndPerformNoSetter() throws {
        for missingBattery in [false, true] {
            let fixture = try LegacyFixture(
                disabled: false,
                ac: nil,
                battery: nil
            )
            defer { fixture.dispose() }
            let basename = missingBattery
                ? RecoveryAuthorityStore.legacyBatteryBasename
                : RecoveryAuthorityStore.legacyACBasename
            try fixture.installLegacyTimer(basename, value: 10)

            XCTAssertEqual(
                fixture.provisionAndRecover(),
                .recoveryRequired("legacy-timer-state-unknown")
            )
            XCTAssertEqual(fixture.power.setCalls, [])
            XCTAssertEqual(fixture.store.evidenceState(for: basename), .present)
            XCTAssertNotEqual(fixture.store.journalRecord(), .absent)
        }

        let missingSleep = try LegacyFixture(disabled: nil, ac: 0, battery: nil)
        defer { missingSleep.dispose() }
        try missingSleep.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 10)
        XCTAssertEqual(
            missingSleep.provisionAndRecover(),
            .recoveryRequired("legacy-sleep-disabled-unknown")
        )
        XCTAssertEqual(missingSleep.power.setCalls, [])
    }

    func testTimerBoundsAccept1440AndReject1441AndNonCanonicalZero() throws {
        let accepted = try LegacyFixture(disabled: false, ac: 1_440, battery: nil)
        defer { accepted.dispose() }
        try accepted.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, raw: "1440\n")
        XCTAssertEqual(accepted.provisionAndRecover(), .migratedIdle("legacy-migration"))

        for raw in ["1441\n", "00\n", "01\n", "-1\n", " 1\n", "1\n\n"] {
            let rejected = try LegacyFixture(disabled: false, ac: 0, battery: nil)
            defer { rejected.dispose() }
            try rejected.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, raw: raw)
            XCTAssertEqual(rejected.coordinator.provision(), .ready)
            guard case .recoveryRequired = rejected.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ) else { return XCTFail("accepted invalid timer bytes \(raw.debugDescription)") }
            XCTAssertEqual(rejected.power.setCalls, [])
        }
    }

    func testUnsafeTimerLeavesSymlinkHardlinkWritableOversizeAndGrowthAreRejected() throws {
        let symlinked = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { symlinked.dispose() }
        try symlinked.installSymlinkTimer()
        XCTAssertTrue(symlinked.prepareMustFailWithoutSetter())

        // The held Swift sandbox deliberately denies link(2). Exercise the
        // exact production metadata predicate with the post-hardlink nlink
        // instead of weakening the sandbox or production validation.
        var hardlinked = stat()
        hardlinked.st_mode = S_IFREG | 0o644
        hardlinked.st_uid = getuid()
        hardlinked.st_gid = getgid()
        hardlinked.st_nlink = 2
        hardlinked.st_size = 2
        XCTAssertFalse(RecoveryAuthorityStore.historicalRegularMetadataIsAccepted(
            hardlinked,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid(),
            expectedMode: 0o644,
            maximumBytes: 128
        ))

        let writable = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { writable.dispose() }
        try writable.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, raw: "7\n", mode: 0o666)
        XCTAssertTrue(writable.prepareMustFailWithoutSetter())

        let oversized = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { oversized.dispose() }
        try oversized.installLegacyTimer(
            RecoveryAuthorityStore.legacyACBasename,
            raw: String(repeating: "1", count: 129),
            mode: 0o644
        )
        XCTAssertTrue(oversized.prepareMustFailWithoutSetter())

        let growing = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { growing.dispose() }
        try growing.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 7)
        try growing.replaceStore(fileOperations: .init(
            openLeaf: { directory, basename in
                Darwin.openat(directory, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            },
            afterOpen: { directory, basename in
                guard basename == RecoveryAuthorityStore.legacyACBasename else { return }
                let fd = Darwin.openat(directory, basename, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    var byte: UInt8 = 0x78
                    _ = Darwin.write(fd, &byte, 1)
                    Darwin.close(fd)
                }
            }
        ))
        XCTAssertTrue(growing.prepareMustFailWithoutSetter())
    }

    func testUnknownRootLeafAndCanonicalMutableStageFailClosedWhileReceiptIsDiagnosticOnly() throws {
        let unknown = try LegacyFixture(disabled: false, ac: 1, battery: 1)
        defer { unknown.dispose() }
        try unknown.installRegular(name: "surprise", bytes: "x", mode: 0o600)
        XCTAssertTrue(unknown.prepareMustFailWithoutSetter())
        XCTAssertEqual(try unknown.read("surprise"), "x")
        XCTAssertNil(unknown.store.proof())

        let transaction = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let staged = try LegacyFixture(disabled: false, ac: 1, battery: 1)
        defer { staged.dispose() }
        try staged.installTransactionStage(transaction: transaction)
        try staged.installTransactionReceipt(transaction: transaction)
        XCTAssertEqual(staged.coordinator.provision(), .ready)
        XCTAssertEqual(
            staged.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .recoveryRequired("unsafe-authority-root-inventory")
        )
        XCTAssertNil(staged.store.proof())
        XCTAssertEqual(staged.power.setCalls, [])

        let receiptOnly = try LegacyFixture(disabled: false, ac: 1, battery: 1)
        defer { receiptOnly.dispose() }
        try receiptOnly.installTransactionReceipt(transaction: transaction)
        XCTAssertEqual(receiptOnly.store.provision(), .ready)
        XCTAssertEqual(receiptOnly.store.proof()?.kind, .pristine)
        XCTAssertEqual(receiptOnly.power.setCalls, [])
    }

    func testHistoricalGroupContractAcceptsWheelAndAdminOnlyForRoot() {
        XCTAssertTrue(RecoveryAuthorityStore.historicalGroupIsAccepted(
            ownerUID: 0, expectedGroupID: 0, actualGroupID: 0
        ))
        XCTAssertTrue(RecoveryAuthorityStore.historicalGroupIsAccepted(
            ownerUID: 0, expectedGroupID: 0, actualGroupID: 80
        ))
        XCTAssertFalse(RecoveryAuthorityStore.historicalGroupIsAccepted(
            ownerUID: 0, expectedGroupID: 0, actualGroupID: 20
        ))
        XCTAssertFalse(RecoveryAuthorityStore.historicalGroupIsAccepted(
            ownerUID: 501, expectedGroupID: 20, actualGroupID: 80
        ))
    }

    func testProductionJournalParserEnforcesCompletePhaseDispositionMatrix() {
        func journal(
            phase: LegacyRecoveryJournal.Phase,
            ac: Int?,
            battery: Int?,
            acDisposition: LegacyRecoveryJournal.TimerDisposition,
            batteryDisposition: LegacyRecoveryJournal.TimerDisposition
        ) -> LegacyRecoveryJournal {
            .init(
                phase: phase,
                ownsSleepDisabled: ac != nil || battery != nil,
                acTarget: ac,
                batteryTarget: battery,
                acDisposition: acDisposition,
                batteryDisposition: batteryDisposition
            )
        }

        let phases: [LegacyRecoveryJournal.Phase] = [.prepared, .nativeSafe, .proofPublished]
        let targets: [Int?] = [nil, 0, 9, 1_440]
        let dispositions: [LegacyRecoveryJournal.TimerDisposition] = [
            .notRequired, .pending, .satisfied, .restored,
            .superseded(0), .superseded(9), .superseded(1_440),
        ]
        func expected(
            phase: LegacyRecoveryJournal.Phase,
            target: Int?,
            disposition: LegacyRecoveryJournal.TimerDisposition
        ) -> Bool {
            guard let target else { return disposition == .notRequired }
            if phase == .prepared { return disposition == .pending }
            switch disposition {
            case .satisfied: return true
            case .restored: return target > 0
            case let .superseded(value): return value > 0 && value != target
            case .notRequired, .pending: return false
            }
        }
        for phase in phases {
            for target in targets {
                for disposition in dispositions {
                    for batteryLane in [false, true] {
                        let candidate = batteryLane
                            ? journal(phase: phase, ac: nil, battery: target,
                                      acDisposition: .notRequired, batteryDisposition: disposition)
                            : journal(phase: phase, ac: target, battery: nil,
                                      acDisposition: disposition, batteryDisposition: .notRequired)
                        XCTAssertEqual(
                            LegacyRecoveryJournal.parse(candidate.payload) != nil,
                            expected(phase: phase, target: target, disposition: disposition),
                            candidate.payload
                        )
                    }
                }
            }
        }

        let valid = [
            journal(phase: .prepared, ac: nil, battery: nil,
                    acDisposition: .notRequired, batteryDisposition: .notRequired),
            journal(phase: .prepared, ac: 0, battery: 1_440,
                    acDisposition: .pending, batteryDisposition: .pending),
            journal(phase: .nativeSafe, ac: 0, battery: nil,
                    acDisposition: .satisfied, batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 9, battery: nil,
                    acDisposition: .restored, batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 9, battery: nil,
                    acDisposition: .superseded(1), batteryDisposition: .notRequired),
            journal(phase: .proofPublished, ac: 9, battery: 1_440,
                    acDisposition: .superseded(1_440), batteryDisposition: .satisfied),
        ]
        for candidate in valid {
            XCTAssertEqual(LegacyRecoveryJournal.parse(candidate.payload), candidate)
        }

        let invalid = [
            journal(phase: .prepared, ac: 9, battery: nil,
                    acDisposition: .satisfied, batteryDisposition: .notRequired),
            journal(phase: .prepared, ac: 9, battery: nil,
                    acDisposition: .restored, batteryDisposition: .notRequired),
            journal(phase: .prepared, ac: 9, battery: nil,
                    acDisposition: .superseded(8), batteryDisposition: .notRequired),
            journal(phase: .prepared, ac: 9, battery: nil,
                    acDisposition: .notRequired, batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 9, battery: nil,
                    acDisposition: .pending, batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 9, battery: nil,
                    acDisposition: .notRequired, batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 0, battery: nil,
                    acDisposition: .restored, batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 9, battery: nil,
                    acDisposition: .superseded(9), batteryDisposition: .notRequired),
            journal(phase: .nativeSafe, ac: 9, battery: nil,
                    acDisposition: .superseded(0), batteryDisposition: .notRequired),
            journal(phase: .proofPublished, ac: nil, battery: nil,
                    acDisposition: .satisfied, batteryDisposition: .notRequired),
        ]
        for candidate in invalid {
            XCTAssertNil(LegacyRecoveryJournal.parse(candidate.payload), candidate.payload)
        }

        let superseded = valid[5].payload
        for token in ["superseded-0", "superseded-00", "superseded--1", "superseded-1441"] {
            XCTAssertNil(LegacyRecoveryJournal.parse(
                superseded.replacingOccurrences(of: "superseded-1440", with: token)
            ))
        }
        let wrongOwnership = valid[1].payload.replacingOccurrences(
            of: "owns_sleep_disabled=1",
            with: "owns_sleep_disabled=0"
        )
        XCTAssertNil(LegacyRecoveryJournal.parse(wrongOwnership))
    }

    func testAppliedStateParserRequiresCanonicalBytesWhilePreservingFourAndSixKeyLegacyShapes() throws {
        let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let four = [
            "session=\(session)",
            "changed_sleep_disabled=0",
            "changed_ac_sleep=0",
            "original_ac_sleep=unknown",
            "",
        ].joined(separator: "\n")
        let six = [
            "session=\(session)",
            "changed_sleep_disabled=0",
            "changed_ac_sleep=0",
            "original_ac_sleep=unknown",
            "changed_battery_sleep=0",
            "original_battery_sleep=unknown",
            "",
        ].joined(separator: "\n")
        let fourState = try XCTUnwrap(AppliedState.parse(four))
        let sixState = try XCTUnwrap(AppliedState.parse(six))
        XCTAssertEqual(fourState.storagePayload, four)
        XCTAssertEqual(sixState.storagePayload, six)
        XCTAssertFalse(sixState.changedBatterySleep)
        XCTAssertNil(sixState.originalBatterySleep)

        let schema12 = [
            "schema=2",
            "session=\(session)",
            "changed_sleep_disabled=0",
            "changed_ac_sleep=0",
            "original_ac_sleep=unknown",
            "pid=42",
            "start_sec=100",
            "start_usec=5",
            "asid=7",
            "euid=501",
            "boot=00000000-0000-4000-8000-000000000001",
            "lease_expiry_mono=999.0",
            "",
        ].joined(separator: "\n")
        let schema14 = schema12.replacingOccurrences(
            of: "original_ac_sleep=unknown\n",
            with: "original_ac_sleep=unknown\nchanged_battery_sleep=0\noriginal_battery_sleep=unknown\n"
        )
        let parsedSchema12 = try XCTUnwrap(AppliedState.parse(schema12))
        let parsedSchema14 = try XCTUnwrap(AppliedState.parse(schema14))
        XCTAssertEqual(parsedSchema12.storagePayload, schema12)
        XCTAssertEqual(parsedSchema14.storagePayload, schema14)
        XCTAssertFalse(parsedSchema12.isReconnectable)
        XCTAssertEqual(parsedSchema12.provenance, .legacy, "schema-2 is restore-only at every mode")

        let current = AppliedState(
            sessionID: try XCTUnwrap(UUID(uuidString: session)),
            changedSleepDisabled: true,
            changedACSleep: true,
            originalACSleep: 9,
            owner: .init(pid: 42, startSeconds: 100, startMicroseconds: 5,
                         asid: 7, euid: 501,
                         bootID: "00000000-0000-4000-8000-000000000001"),
            leaseExpiryMonotonic: 999.0,
            provenance: .current
        )
        XCTAssertTrue(current.storagePayload.hasPrefix("schema=3\n"))
        XCTAssertTrue(try XCTUnwrap(AppliedState.parse(current.storagePayload)).isReconnectable)

        let changed = AppliedState(
            sessionID: try XCTUnwrap(UUID(uuidString: session)),
            changedSleepDisabled: false,
            changedACSleep: true,
            originalACSleep: 9
        ).storagePayload
        let invalidLegacy = [
            String(four.dropLast()),
            four + "\n",
            four.replacingOccurrences(of: "changed_sleep_disabled=0\n", with: "\nchanged_sleep_disabled=0\n"),
            four.replacingOccurrences(of: "session=\(session)\nchanged_sleep_disabled=0",
                                      with: "changed_sleep_disabled=0\nsession=\(session)"),
            four.replacingOccurrences(of: session, with: session.uppercased()),
            four.replacingOccurrences(of: "changed_ac_sleep=0\n", with: "changed_ac_sleep=0\nextra=1\n"),
            changed.replacingOccurrences(of: "original_ac_sleep=9", with: "original_ac_sleep=09"),
        ]
        for raw in invalidLegacy { XCTAssertNil(AppliedState.parse(raw), raw.debugDescription) }

        let invalidSchema2 = [
            schema12.replacingOccurrences(of: "schema=2\nsession=\(session)",
                                          with: "session=\(session)\nschema=2"),
            schema12.replacingOccurrences(of: "pid=42", with: "pid=042"),
            schema12.replacingOccurrences(of: "lease_expiry_mono=999.0", with: "lease_expiry_mono=999"),
            schema12.replacingOccurrences(of: session, with: session.uppercased()),
            schema12.replacingOccurrences(of: "start_sec=100\n", with: "start_sec=100\n\n"),
        ]
        for raw in invalidSchema2 { XCTAssertNil(AppliedState.parse(raw), raw.debugDescription) }
    }

    func testFourAndSixKeyAppliedRecordsAtHistoricalModesRemainRestoreOnly() throws {
        for mode in [mode_t(0o600), mode_t(0o640), mode_t(0o644)] {
            for includesBattery in [false, true] {
                let fixture = try LegacyFixture(
                    disabled: true,
                    ac: 10,
                    battery: includesBattery ? 0 : 10
                )
                defer { fixture.dispose() }
                let session = UUID()
                let legacy = AppliedState(
                    sessionID: session,
                    changedSleepDisabled: true,
                    changedACSleep: false,
                    originalACSleep: nil,
                    changedBatterySleep: includesBattery,
                    originalBatterySleep: includesBattery ? 12 : nil
                )
                try fixture.installRegular(
                    name: RecoveryAuthorityStore.appliedBasename,
                    bytes: legacy.storagePayload,
                    mode: mode
                )

                XCTAssertEqual(fixture.store.provision(), .ready)
                guard case let .legacyRestoreOnly(migrated) = fixture.store.appliedRecord() else {
                    return XCTFail("mode \(String(mode, radix: 8)) became reconnect authority")
                }
                XCTAssertNil(migrated.owner)
                XCTAssertFalse(migrated.isProcessBound)
                XCTAssertEqual(
                    fixture.coordinator.recover(intent: .startup, allowReconnect: true),
                    .recoveryRequired("legacy-writers-not-quiesced")
                )
                XCTAssertEqual(fixture.power.setCalls, [])
                XCTAssertEqual(
                    fixture.coordinator.recover(
                        intent: .userRestore,
            allowReconnect: false
                    ),
                    .terminalIdle(session, "legacy-restore")
                )
                XCTAssertEqual(fixture.power.disabled, false)
                if includesBattery { XCTAssertEqual(fixture.power.battery, 12) }
            }
        }
    }

    func testPublicAndPrivateUnprovenSchema2AreDowngradedToRestoreOnly() throws {
        for mode in [mode_t(0o600), mode_t(0o644)] {
            let fixture = try LegacyFixture(disabled: true, ac: 0, battery: nil)
            defer { fixture.dispose() }
            let session = UUID()
            let state = AppliedState(
                sessionID: session,
                changedSleepDisabled: true,
                changedACSleep: true,
                originalACSleep: 9,
                owner: .init(
                    pid: 42,
                    startSeconds: 100,
                    startMicroseconds: 5,
                    asid: 7,
                    euid: UInt32(getuid()),
                    bootID: "00000000-0000-4000-8000-000000000001"
                ),
                leaseExpiryMonotonic: 999
            )
            try fixture.installRegular(
                name: RecoveryAuthorityStore.appliedBasename,
                bytes: state.storagePayload,
                mode: mode
            )

            XCTAssertEqual(fixture.store.provision(), .ready)
            guard case let .legacyRestoreOnly(migrated) = fixture.store.appliedRecord() else {
                return XCTFail("unproven schema 2 became reconnect authority")
            }
            XCTAssertNil(migrated.owner)
            XCTAssertNil(migrated.leaseExpiryMonotonic)
            XCTAssertEqual(
                fixture.coordinator.recover(
                    intent: .userRestore,
            allowReconnect: false
                ),
                .terminalIdle(session, "legacy-restore")
            )
            XCTAssertEqual(fixture.power.disabled, false)
            XCTAssertEqual(fixture.power.ac, 9)
        }
    }

    func testLegacyStatusMustHaveExactIdleOrTerminalLineage() throws {
        let activeSession = UUID()
        let active = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { active.dispose() }
        try active.installLegacyStatus(state: "active", session: activeSession)
        XCTAssertTrue(active.prepareMustFailWithoutSetter())
        XCTAssertNil(active.store.proof())

        let malformed = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { malformed.dispose() }
        try malformed.installRegular(name: "helper-status", bytes: "not-a-status\n", mode: 0o644)
        XCTAssertTrue(malformed.prepareMustFailWithoutSetter())
        XCTAssertNil(malformed.store.proof())

        let idle = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { idle.dispose() }
        try idle.installLegacyStatus(state: "inactive", session: nil)
        XCTAssertEqual(idle.provisionAndRecover(), .migratedIdle("legacy-migration"))
        XCTAssertNotEqual(idle.store.proof()?.kind, .pristine)
    }

    func testLegacyTerminalStatusMustMatchNewestTerminalLedgerExactly() throws {
        let terminal = UUID()
        let matching = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { matching.dispose() }
        try matching.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [terminal])
        try matching.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        try matching.installLegacyStatus(state: "terminal", session: terminal)
        XCTAssertEqual(matching.store.provision(), .ready)
        XCTAssertEqual(
            matching.store.proof(),
            RecoveryProof(kind: .terminal, sessionID: terminal, reason: "legacy-migration")
        )

        let mismatched = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { mismatched.dispose() }
        try mismatched.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [terminal])
        try mismatched.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        try mismatched.installLegacyStatus(state: "terminal", session: UUID())
        XCTAssertTrue(mismatched.prepareMustFailWithoutSetter())
        XCTAssertNil(mismatched.store.proof())
    }

    func testShippedV4TerminalOnlyLedgerPublishesEmptyReservationThenMigrates() throws {
        let terminal = UUID()
        let fixture = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { fixture.dispose() }
        try fixture.installRegular(name: "helper-version", bytes: "4\n", mode: 0o644)
        try fixture.installRegular(
            name: RecoveryAuthorityStore.terminalBasename,
            bytes: terminal.uuidString.lowercased() + "\n",
            mode: 0o644
        )
        try fixture.installLegacyStatus(state: "inactive", session: terminal)

        XCTAssertEqual(fixture.store.provision(), .ready)
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.terminalBasename), [terminal])
        XCTAssertEqual(fixture.store.privateLedger(RecoveryAuthorityStore.reservationBasename), [])
        XCTAssertEqual(
            fixture.store.proof(),
            RecoveryProof(kind: .terminal, sessionID: terminal, reason: "legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
    }

    func testTerminalOnlyLedgerStillRejectsWrongVersionOrInactiveLineage() throws {
        let terminal = UUID()
        for (version, session) in [(3, terminal), (4, UUID())] {
            let fixture = try LegacyFixture(disabled: false, ac: 10, battery: nil)
            defer { fixture.dispose() }
            try fixture.installRegular(name: "helper-version", bytes: "\(version)\n", mode: 0o644)
            try fixture.installRegular(
                name: RecoveryAuthorityStore.terminalBasename,
                bytes: terminal.uuidString.lowercased() + "\n",
                mode: 0o644
            )
            try fixture.installLegacyStatus(state: "inactive", session: session)

            XCTAssertTrue(fixture.prepareMustFailWithoutSetter())
            XCTAssertEqual(fixture.store.ledger(RecoveryAuthorityStore.reservationBasename), .absent)
            XCTAssertEqual(fixture.power.setCalls, [])
        }

        let missingLineage = try LegacyFixture(disabled: false, ac: 10, battery: nil)
        defer { missingLineage.dispose() }
        try missingLineage.installRegular(name: "helper-version", bytes: "4\n", mode: 0o644)
        try missingLineage.installRegular(
            name: RecoveryAuthorityStore.terminalBasename,
            bytes: "",
            mode: 0o644
        )

        XCTAssertTrue(missingLineage.prepareMustFailWithoutSetter())
        XCTAssertEqual(missingLineage.store.ledger(RecoveryAuthorityStore.reservationBasename), .absent)
        XCTAssertEqual(missingLineage.power.setCalls, [])
    }

    func testDurableJournalAndPristineProofResumeOnlyTheirOwnPartialEmptyLedgerPair() throws {
        let journaled = try LegacyFixture(disabled: false, ac: nil, battery: nil)
        defer { journaled.dispose() }
        try journaled.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try journaled.installJournal(.init(
            phase: .prepared,
            ownsSleepDisabled: false,
            acTarget: nil,
            batteryTarget: nil,
            acDisposition: .notRequired,
            batteryDisposition: .notRequired
        ))
        XCTAssertEqual(journaled.coordinator.provision(), .ready)
        XCTAssertEqual(journaled.store.prepareAuthorityAfterWriterQuiescence(), .ready)
        XCTAssertEqual(journaled.store.privateLedger(RecoveryAuthorityStore.terminalBasename), [])
        XCTAssertEqual(journaled.store.privateLedger(RecoveryAuthorityStore.reservationBasename), [])
        XCTAssertNil(journaled.store.proof())

        let bootstrap = try LegacyFixture(disabled: false, ac: nil, battery: nil)
        defer { bootstrap.dispose() }
        try bootstrap.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try bootstrap.installProof(.init(kind: .pristine, sessionID: nil, reason: "bootstrap"))
        XCTAssertEqual(bootstrap.coordinator.provision(), .ready)
        XCTAssertEqual(bootstrap.store.prepareAuthorityAfterWriterQuiescence(), .ready)
        XCTAssertEqual(bootstrap.store.privateLedger(RecoveryAuthorityStore.reservationBasename), [])
        XCTAssertEqual(bootstrap.store.proof()?.kind, .pristine)

        let unmarkedGap = try LegacyFixture(disabled: false, ac: nil, battery: nil)
        defer { unmarkedGap.dispose() }
        try unmarkedGap.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        XCTAssertTrue(unmarkedGap.prepareMustFailWithoutSetter())
        XCTAssertEqual(unmarkedGap.store.proof()?.kind, .recoveryRequired)
    }

    func testProofPublishedOrphanCleanupResumesWithoutAnySetter() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 8, battery: nil)
        defer { fixture.dispose() }
        try fixture.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try fixture.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        let journal = LegacyRecoveryJournal(
            phase: .proofPublished,
            ownsSleepDisabled: true,
            acTarget: 8,
            batteryTarget: nil,
            acDisposition: .restored,
            batteryDisposition: .notRequired
        )
        try fixture.installJournal(journal)
        try fixture.installProof(.init(kind: .migrated, sessionID: nil, reason: "legacy-migration"))
        try fixture.installLegacyTimer(
            RecoveryAuthorityStore.legacyACBasename,
            raw: "8\n",
            mode: 0o600
        )
        try fixture.quarantine(RecoveryAuthorityStore.legacyACBasename)
        try fixture.quarantine(RecoveryAuthorityStore.journalBasename)

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.store.journalRecord(), .absent)
        XCTAssertEqual(
            fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyACBasename),
            .absent
        )
    }

    func testCrashAfterProofBeforeJournalUpdateReplaysExactLineageWithoutReclassification() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 8, battery: nil)
        defer { fixture.dispose() }
        try fixture.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try fixture.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        let journal = LegacyRecoveryJournal(
            phase: .nativeSafe,
            ownsSleepDisabled: true,
            acTarget: 8,
            batteryTarget: nil,
            acDisposition: .restored,
            batteryDisposition: .notRequired
        )
        let proof = RecoveryProof(kind: .migrated, sessionID: nil, reason: journal.proofReason)
        try fixture.installJournal(journal)
        try fixture.installProof(proof)
        try fixture.installLegacyTimer(
            RecoveryAuthorityStore.legacyACBasename,
            raw: "8\n",
            mode: 0o600
        )
        let proofBytes = try fixture.read(RecoveryAuthorityStore.proofBasename)

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(try fixture.read(RecoveryAuthorityStore.proofBasename), proofBytes)
        XCTAssertEqual(fixture.store.journalRecord(), .absent)

        let reads = (fixture.power.acReads, fixture.power.batteryReads)
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .userRestore,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.power.acReads, reads.0 + 1)
        XCTAssertEqual(fixture.power.batteryReads, reads.1 + 1)

        let overwrite = try XCTUnwrap(fixture.store.withTransaction {
            fixture.store.markRecoveryRequired("must-not-reclassify", $0)
        })
        XCTAssertEqual(overwrite, .notPublished(.parser))
        XCTAssertEqual(try fixture.read(RecoveryAuthorityStore.proofBasename), proofBytes)
    }

    func testPublishedMigrationProofFailsClosedOnNativeDriftAndRemainsByteImmutable() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 9, battery: nil)
        defer { fixture.dispose() }
        try fixture.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try fixture.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        let journal = LegacyRecoveryJournal(
            phase: .nativeSafe,
            ownsSleepDisabled: true,
            acTarget: 8,
            batteryTarget: nil,
            acDisposition: .restored,
            batteryDisposition: .notRequired
        )
        try fixture.installJournal(journal)
        try fixture.installProof(.init(kind: .migrated, sessionID: nil, reason: journal.proofReason))
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 8)
        let proofBytes = try fixture.read(RecoveryAuthorityStore.proofBasename)

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .recoveryRequired("legacy-post-proof-native-drift")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(try fixture.read(RecoveryAuthorityStore.proofBasename), proofBytes)
        XCTAssertEqual(fixture.store.proof()?.kind, .migrated)
        XCTAssertEqual(fixture.store.journalRecord(), .valid(journal))
        XCTAssertEqual(
            fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyACBasename),
            .present
        )
    }

    func testPublishedMigrationPositiveTargetWithCurrentZeroIsDriftNotSupersession() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { fixture.dispose() }
        try fixture.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try fixture.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        let journal = LegacyRecoveryJournal(
            phase: .nativeSafe,
            ownsSleepDisabled: true,
            acTarget: 8,
            batteryTarget: nil,
            acDisposition: .restored,
            batteryDisposition: .notRequired
        )
        let proof = RecoveryProof(kind: .migrated, sessionID: nil, reason: journal.proofReason)
        try fixture.installJournal(journal)
        try fixture.installProof(proof)
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 8)

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        let outcome = fixture.coordinator.recover(
            intent: .install,
            allowReconnect: false
        )
        XCTAssertEqual(outcome, .recoveryRequired("legacy-post-proof-native-drift"))
        if case .migratedIdle = outcome { XCTFail("current zero was accepted as superseded") }
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(fixture.store.proof(), proof)
        XCTAssertEqual(fixture.store.journalRecord(), .valid(journal))
        XCTAssertEqual(
            fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyACBasename),
            .present
        )
    }

    func testPublishedMigrationProofRequiresExactJournalReasonAndPreservesBothArtifacts() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 9, battery: nil)
        defer { fixture.dispose() }
        try fixture.installPrivateLedger(RecoveryAuthorityStore.terminalBasename, entries: [])
        try fixture.installPrivateLedger(RecoveryAuthorityStore.reservationBasename, entries: [])
        let journal = LegacyRecoveryJournal(
            phase: .nativeSafe,
            ownsSleepDisabled: true,
            acTarget: 8,
            batteryTarget: nil,
            acDisposition: .superseded(9),
            batteryDisposition: .notRequired
        )
        let wrongProof = RecoveryProof(kind: .migrated, sessionID: nil, reason: "legacy-migration")
        try fixture.installJournal(journal)
        try fixture.installProof(wrongProof)
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 8)
        let proofBytes = try fixture.read(RecoveryAuthorityStore.proofBasename)

        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .recoveryRequired("legacy-proof-journal-mismatch")
        )
        XCTAssertEqual(fixture.power.setCalls, [])
        XCTAssertEqual(try fixture.read(RecoveryAuthorityStore.proofBasename), proofBytes)
        XCTAssertEqual(fixture.store.proof(), wrongProof)
        XCTAssertEqual(fixture.store.journalRecord(), .valid(journal))
    }

    func testPreMutationJournalAndSetterCrashReentryAreIdempotentAndNeverRearm() throws {
        let fixture = try LegacyFixture(disabled: true, ac: 0, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 8)
        XCTAssertEqual(fixture.coordinator.provision(), .ready)
        XCTAssertEqual(fixture.store.prepareAuthorityAfterWriterQuiescence(), .ready)
        guard case let .valid(journal) = fixture.store.journalRecord() else {
            return XCTFail("pre-mutation journal was not durable")
        }
        XCTAssertEqual(journal.phase, .prepared)
        XCTAssertEqual(fixture.power.setCalls, [])

        fixture.power.failAfterSleepSetter = true
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.disabled, false)
        fixture.power.failAfterSleepSetter = false
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls.filter { $0 == "sleep=0" }.count, 1)
        XCTAssertEqual(fixture.power.setCalls.filter { $0 == "ac=8" }.count, 1)
        XCTAssertFalse(fixture.power.setCalls.contains("sleep=1"))
        XCTAssertFalse(fixture.power.setCalls.contains("ac=0"))
    }

    func testCrashAfterTimerSetterIsRecoveredFromNativePostreadWithoutSecondSetter() throws {
        let fixture = try LegacyFixture(disabled: false, ac: 0, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 13)
        fixture.power.failAfterACSetter = true

        XCTAssertEqual(
            fixture.provisionAndRecover(),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.ac, 13)
        fixture.power.failAfterACSetter = false
        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .install,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls.filter { $0 == "ac=13" }.count, 1)
    }

    func testRepeatedRecoveryAfterMigrationIsObservationOnly() throws {
        let fixture = try LegacyFixture(disabled: true, ac: 0, battery: nil)
        defer { fixture.dispose() }
        try fixture.installLegacyTimer(RecoveryAuthorityStore.legacyACBasename, value: 7)
        XCTAssertEqual(fixture.provisionAndRecover(), .migratedIdle("legacy-migration"))
        let calls = fixture.power.setCalls

        XCTAssertEqual(
            fixture.coordinator.recover(
                intent: .userRestore,
            allowReconnect: false
            ),
            .migratedIdle("legacy-migration")
        )
        XCTAssertEqual(fixture.power.setCalls, calls)
        XCTAssertEqual(fixture.store.journalRecord(), .absent)
        XCTAssertEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.legacyACBasename), .absent)
    }

    func testUserDesiredLeaseAndHistoryNamesCannotAuthorizeRootMigration() throws {
        for name in ["desired-state", "activation-lease", "session-history.json"] {
            let fixture = try LegacyFixture(disabled: false, ac: 1, battery: 1)
            defer { fixture.dispose() }
            try fixture.installRegular(name: name, bytes: "untrusted", mode: 0o600)
            XCTAssertTrue(fixture.prepareMustFailWithoutSetter(), name)
            XCTAssertNil(fixture.store.proof(), name)
        }
    }

    func testUnownedGlobalSleepOverrideBlocksNoOpACOnlyAndSchema2Terminalization() throws {
        let boot = "00000000-0000-4000-8000-000000000001"
        let session = UUID()
        let owner = AppliedState.Owner(pid: 42, startSeconds: 100, startMicroseconds: 5,
                                        asid: 7, euid: UInt32(getuid()), bootID: boot)
        let states = [
            AppliedState(sessionID: session, changedSleepDisabled: false,
                         changedACSleep: false, originalACSleep: nil),
            AppliedState(sessionID: session, changedSleepDisabled: false,
                         changedACSleep: false, originalACSleep: nil,
                         changedBatterySleep: false, originalBatterySleep: nil),
            AppliedState(sessionID: session, changedSleepDisabled: false,
                         changedACSleep: true, originalACSleep: 10),
            AppliedState(sessionID: session, changedSleepDisabled: false,
                         changedACSleep: true, originalACSleep: 10,
                         owner: owner, leaseExpiryMonotonic: 999)
        ]
        for state in states {
            let fixture = try LegacyFixture(disabled: true, ac: state.changedACSleep ? 0 : 10, battery: nil)
            defer { fixture.dispose() }
            try fixture.installRegular(name: RecoveryAuthorityStore.appliedBasename,
                                       bytes: state.storagePayload, mode: 0o600)
            XCTAssertEqual(fixture.coordinator.provision(), .ready)
            XCTAssertEqual(
                fixture.coordinator.recover(intent: .userRestore, allowReconnect: false),
                .recoveryRequired("unowned-sleep-override-active")
            )
            XCTAssertEqual(fixture.power.setCalls, [], "unowned override must not be cleared")
            XCTAssertEqual(fixture.power.disabled, true)
            XCTAssertNotEqual(fixture.store.evidenceState(for: RecoveryAuthorityStore.appliedBasename), .absent)
            XCTAssertNotEqual(fixture.store.proof()?.kind, .terminal)
        }
    }
}

private final class LegacyStoreBox {
    var store: RecoveryAuthorityStore
    init(_ store: RecoveryAuthorityStore) { self.store = store }
}

private final class LegacyFixture {
    let sandbox: TestSandbox.Directory
    let power: LegacyPower
    let configuration: HelperServiceConfiguration
    let storeBox: LegacyStoreBox
    let coordinator: RecoveryCoordinator

    var store: RecoveryAuthorityStore { storeBox.store }

    init(disabled: Bool?, ac: Int?, battery: Int?) throws {
        sandbox = try TestSandbox.makeDirectory(label: "legacy-migration")
        guard chmod(sandbox.url.path, 0o755) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        power = LegacyPower(disabled: disabled, ac: ac, battery: battery)
        configuration = .init(
            expectedOwnerUID: getuid(),
            qualifiedBuild: "25F84",
            supportDirectory: sandbox.url.path,
            appliedStatePath: sandbox.url.appendingPathComponent(RecoveryAuthorityStore.appliedBasename).path,
            statusPath: sandbox.url.appendingPathComponent("helper-status").path,
            policyPath: sandbox.url.appendingPathComponent("policy").path,
            mode: .daemon
        )
        let directory = try XCTUnwrap(Self.directory(at: sandbox.url, operations: .system))
        let initial = RecoveryAuthorityStore(
            directory: directory,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid()
        )
        storeBox = LegacyStoreBox(initial)
        let box = storeBox
        coordinator = RecoveryCoordinator(
            configuration: configuration,
            power: power,
            bootIdentity: { "00000000-0000-4000-8000-000000000001" },
            storeFactory: { _ in box.store },
            quiescenceProbe: .fixtureQuiesced
        )
    }

    func dispose() { try? FileManager.default.removeItem(at: sandbox.url) }

    func provisionAndRecover() -> RecoveryAssessment {
        guard coordinator.provision() == .ready else { return .recoveryRequired("fixture-lock") }
        return coordinator.recover(
            intent: .install,
            allowReconnect: false
        )
    }

    func prepareMustFailWithoutSetter() -> Bool {
        guard coordinator.provision() == .ready else { return false }
        let outcome = coordinator.recover(
            intent: .install,
            allowReconnect: false
        )
        guard case .recoveryRequired = outcome else { return false }
        return power.setCalls.isEmpty
    }

    func installLegacyHelper() throws {
        try installRegular(name: "lidswitch-helper", bytes: "#!/bin/zsh\nexit 0\n", mode: 0o755)
    }

    func installLegacyStatus(state: String, session: UUID?) throws {
        let payload = [
            "state=\(state)",
            "reason=legacy-fixture",
            "session=\(session?.uuidString.lowercased() ?? "none")",
            "updated=1",
            "",
        ].joined(separator: "\n")
        try installRegular(name: "helper-status", bytes: payload, mode: 0o644)
    }

    func installPrivateLedger(_ basename: String, entries: [UUID]) throws {
        let payload = entries.isEmpty
            ? ""
            : entries.map { $0.uuidString.lowercased() }.joined(separator: "\n") + "\n"
        try installRegular(name: basename, bytes: payload, mode: 0o600)
    }

    func installJournal(_ journal: LegacyRecoveryJournal) throws {
        try installRegular(
            name: RecoveryAuthorityStore.journalBasename,
            bytes: journal.payload,
            mode: 0o600
        )
    }

    func installProof(_ proof: RecoveryProof) throws {
        try installRegular(
            name: RecoveryAuthorityStore.proofBasename,
            bytes: proof.payload,
            mode: 0o600
        )
    }

    func quarantine(_ basename: String) throws {
        let destination = try XCTUnwrap(VerifiedRootStateDirectory.quarantineBasename(for: basename))
        guard Darwin.renameat(
            AT_FDCWD,
            sandbox.url.appendingPathComponent(basename).path,
            AT_FDCWD,
            sandbox.url.appendingPathComponent(destination).path
        ) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func installLegacyTimer(_ basename: String, value: Int) throws {
        try installLegacyTimer(basename, raw: "\(value)\n", mode: 0o644)
    }

    func installLegacyTimer(_ basename: String, raw: String, mode: mode_t = 0o644) throws {
        try installRegular(name: basename, bytes: raw, mode: mode)
    }

    func installRegular(name: String, bytes: String, mode: mode_t) throws {
        let path = sandbox.url.appendingPathComponent(name).path
        guard FileManager.default.createFile(atPath: path, contents: Data(bytes.utf8)),
              chmod(path, mode) == 0
        else { throw CocoaError(.fileWriteUnknown) }
    }

    func installSymlinkTimer() throws {
        _ = try installHistoricalTarget()
        guard symlink(
            "Current/target",
            sandbox.url.appendingPathComponent(RecoveryAuthorityStore.legacyACBasename).path
        ) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func installHardlinkedTimer() throws {
        let target = try installHistoricalTarget()
        guard link(
            target.path,
            sandbox.url.appendingPathComponent(RecoveryAuthorityStore.legacyACBasename).path
        ) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func installTransactionStage(transaction: UUID) throws {
        let stage = sandbox.url.appendingPathComponent(".administrator-\(transaction.uuidString.lowercased())")
        try FileManager.default.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(stage.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func installTransactionReceipt(transaction: UUID) throws {
        let receipt = AdministratorTransactionReceipt.running(transactionID: transaction, operation: .install)
        try installRegular(
            name: "administrator-transaction-\(transaction.uuidString.lowercased()).receipt",
            bytes: receipt.payload,
            mode: 0o644
        )
    }

    private func installHistoricalTarget() throws -> URL {
        let current = sandbox.url.appendingPathComponent("Current", isDirectory: true)
        try FileManager.default.createDirectory(
            at: current,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        guard chmod(current.path, 0o755) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let target = current.appendingPathComponent("target")
        guard FileManager.default.createFile(atPath: target.path, contents: Data("7\n".utf8)),
              chmod(target.path, 0o644) == 0
        else { throw CocoaError(.fileWriteUnknown) }
        return target
    }

    func replaceStore(fileOperations: RecoveryAuthorityFileOperations) throws {
        let directory = try XCTUnwrap(Self.directory(at: sandbox.url, operations: .system))
        storeBox.store = RecoveryAuthorityStore(
            directory: directory,
            expectedOwnerUID: getuid(),
            expectedGroupID: getgid(),
            fileOperations: fileOperations
        )
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: sandbox.url.appendingPathComponent(name), encoding: .utf8)
    }

    private static func directory(
        at url: URL,
        operations: VerifiedRootStateDirectory.Operations
    ) -> VerifiedRootStateDirectory? {
        guard let descriptor = try? TestSandbox.openManagedDirectory(at: url) else { return nil }
        defer { close(descriptor) }
        return VerifiedRootStateDirectory(
            heldDirectoryDescriptor: descriptor,
            expectations: .init(ownerUID: getuid(), groupID: getgid(), mode: 0o755),
            operations: operations
        )
    }
}

private final class LegacyPower: HelperPowerSystem {
    var disabled: Bool?
    var ac: Int?
    var battery: Int?
    var setCalls: [String] = []
    var acReads = 0
    var batteryReads = 0
    var failAfterSleepSetter = false
    var failAfterACSetter = false
    var scriptedACReads: [Int?] = []

    init(disabled: Bool?, ac: Int?, battery: Int?) {
        self.disabled = disabled
        self.ac = ac
        self.battery = battery
    }

    func powerSource() -> HelperPowerSource { .ac }
    func sleepDisabled() -> Bool? { disabled }
    func acSleepMinutes() -> Int? {
        acReads += 1
        if !scriptedACReads.isEmpty {
            let value = scriptedACReads.removeFirst()
            ac = value
            return value
        }
        return ac
    }
    func batterySleepMinutes() -> Int? { batteryReads += 1; return battery }

    func setSleepDisabled(_ enabled: Bool) throws {
        setCalls.append("sleep=\(enabled ? 1 : 0)")
        disabled = enabled
        if failAfterSleepSetter { throw CocoaError(.fileWriteUnknown) }
    }

    func setACSleepMinutes(_ minutes: Int) throws {
        setCalls.append("ac=\(minutes)")
        ac = minutes
        if failAfterACSetter { throw CocoaError(.fileWriteUnknown) }
    }

    func setBatterySleepMinutes(_ minutes: Int) throws {
        setCalls.append("battery=\(minutes)")
        battery = minutes
    }
}
