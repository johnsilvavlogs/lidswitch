import Foundation
import LidSwitchCore
import XCTest
@testable import LidSwitch

private final class BatteryHeartbeatBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

private final class BatteryHeartbeatFixture {
    let clock: BatteryHeartbeatBox<TimeInterval>
    let power: BatteryHeartbeatBox<SessionHeartbeatObservation.Power>
    let acknowledgements: BatteryHeartbeatBox<Int>
    let renewals: BatteryHeartbeatBox<Int>
    let restores: BatteryHeartbeatBox<Int>
    let ended: BatteryHeartbeatBox<[String]>
    let diagnostics: SessionDiagnosticStore
    let coordinator: SessionHeartbeatCoordinator
    let sessionID = UUID()

    init(policy: SessionPowerPolicy = .pluggedInOnly, power initialPower: SessionHeartbeatObservation.Power) throws {
        let root = try TestSandbox.makeDirectory(label: "battery-heartbeat").url
        let diagnostics = SessionDiagnosticStore(file: root.appendingPathComponent("history.json"))
        let clock = BatteryHeartbeatBox<TimeInterval>(0)
        let power = BatteryHeartbeatBox(initialPower)
        let acknowledgements = BatteryHeartbeatBox(0)
        let renewals = BatteryHeartbeatBox(0)
        let restores = BatteryHeartbeatBox(0)
        let ended = BatteryHeartbeatBox([String]())
        self.diagnostics = diagnostics
        self.clock = clock
        self.power = power
        self.acknowledgements = acknowledgements
        self.renewals = renewals
        self.restores = restores
        self.ended = ended
        let epoch = Date(timeIntervalSince1970: 1_000)
        coordinator = SessionHeartbeatCoordinator(
            observationInterval: 3_600,
            renewalInterval: 8,
            powerPolicy: policy,
            now: { epoch.addingTimeInterval(clock.read()) },
            monotonicNow: { clock.read() },
            observe: { sessionID in
                SessionHeartbeatObservation(
                    power: power.read(),
                    authority: .verified,
                    helperStatus: HelperStatusRecord(
                        state: "active", reason: "verified", sessionID: sessionID,
                        updatedAt: epoch.addingTimeInterval(clock.read())
                    )
                )
            },
            renew: { _, _, commitGuard in
                guard commitGuard() else { throw Failure.commitRejected }
                renewals.mutate { $0 += 1 }
                return .renewed(expiryMonotonic: clock.read() + 30)
            },
            revoke: { restores.mutate { $0 += 1 } },
            diagnostics: diagnostics,
            onAcknowledged: { _ in acknowledgements.mutate { $0 += 1 } },
            onEnded: { _, reason in ended.mutate { $0.append(reason) } }
        )
        coordinator.start(sessionID: sessionID, initialLeaseExpiresMonotonic: 30)
    }

    func tick(_ time: TimeInterval) {
        clock.set(time)
        coordinator.evaluateForTesting()
    }

    deinit { coordinator.stop(reason: "test-complete") }

    private enum Failure: Error { case commitRejected }
}

final class BatteryHeartbeatTests: XCTestCase {
    func testAllAcknowledgesAndRenewsOnBattery() throws {
        let fixture = try BatteryHeartbeatFixture(policy: .all, power: .battery)
        fixture.tick(0)
        fixture.tick(8)
        fixture.tick(16)

        XCTAssertEqual(fixture.acknowledgements.read(), 1)
        XCTAssertEqual(fixture.renewals.read(), 2)
        XCTAssertEqual(fixture.restores.read(), 0)
        XCTAssertTrue(fixture.ended.read().isEmpty)
        XCTAssertTrue(fixture.diagnostics.entries().contains { $0.event == "acknowledged" })
    }

    func testAllKeepsSameGenerationAcrossACToBattery() throws {
        let fixture = try BatteryHeartbeatFixture(policy: .all, power: .ac)
        fixture.tick(0)
        fixture.tick(8)
        fixture.power.set(.battery)
        fixture.tick(16)
        fixture.tick(40) // Beyond the original deadline, within the renewed lease.

        XCTAssertEqual(fixture.acknowledgements.read(), 1)
        XCTAssertEqual(fixture.renewals.read(), 3)
        XCTAssertEqual(fixture.restores.read(), 0)
        XCTAssertTrue(fixture.ended.read().isEmpty)
    }

    func testBatteryOnlyRestoresImmediatelyWhenACIsObserved() throws {
        let fixture = try BatteryHeartbeatFixture(policy: .batteryOnly, power: .battery)
        fixture.tick(0)
        fixture.power.set(.ac)
        fixture.tick(1)
        fixture.tick(8)

        XCTAssertEqual(fixture.renewals.read(), 0)
        XCTAssertEqual(fixture.restores.read(), 1)
        XCTAssertEqual(fixture.ended.read(), ["power-source-excluded"])
    }

    func testUnknownPowerWithholdsRenewalUntilExistingHardExpiry() throws {
        let fixture = try BatteryHeartbeatFixture(policy: .all, power: .battery)
        fixture.tick(0)
        fixture.power.set(.unknown)
        fixture.tick(8)
        fixture.tick(29)
        XCTAssertEqual(fixture.renewals.read(), 0)
        XCTAssertTrue(fixture.ended.read().isEmpty)
        fixture.tick(30)

        XCTAssertEqual(fixture.restores.read(), 0, "The helper owns hard-expiry restoration")
        XCTAssertEqual(fixture.ended.read(), ["lease-expired-before-renewal"])
    }

    func testDefaultACOnlyRestoresOnBatteryBeforeAcknowledgement() throws {
        let fixture = try BatteryHeartbeatFixture(power: .battery)
        fixture.tick(0)
        fixture.tick(8)

        XCTAssertEqual(fixture.acknowledgements.read(), 0)
        XCTAssertEqual(fixture.renewals.read(), 0)
        XCTAssertEqual(fixture.restores.read(), 1)
        XCTAssertEqual(fixture.ended.read(), ["power-disconnected"])
    }
}
