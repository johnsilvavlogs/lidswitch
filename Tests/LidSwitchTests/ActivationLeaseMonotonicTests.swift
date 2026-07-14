import Foundation
import XCTest
@testable import LidSwitchCore

final class ActivationLeaseMonotonicTests: XCTestCase {
    func testBackwardWallClockJumpDoesNotInvalidateCurrentBootMonotonicLease() {
        let bootID = "00000000-0000-0000-0000-000000000001"
        let lease = ActivationLease(
            sessionID: UUID(),
            bootID: bootID,
            expiresAt: Date(timeIntervalSince1970: 1_030),
            issuedMonotonic: 100,
            expiresMonotonic: 130,
            ownerUID: 501,
            systemBuild: "fixture-build"
        )

        XCTAssertNil(
            lease.validationFailure(
                now: Date(timeIntervalSince1970: 900),
                nowMonotonic: 108,
                currentBootID: bootID,
                expectedOwnerUID: 501,
                currentSystemBuild: "fixture-build"
            )
        )
    }

    func testForwardWallClockJumpDoesNotOverrideExpiredMonotonicLease() {
        let bootID = "00000000-0000-0000-0000-000000000001"
        let lease = ActivationLease(
            sessionID: UUID(),
            bootID: bootID,
            expiresAt: Date(timeIntervalSince1970: 1_030),
            issuedMonotonic: 100,
            expiresMonotonic: 130,
            ownerUID: 501,
            systemBuild: "fixture-build"
        )

        XCTAssertEqual(
            lease.validationFailure(
                now: Date(timeIntervalSince1970: 9_000),
                nowMonotonic: 131,
                currentBootID: bootID,
                expectedOwnerUID: 501,
                currentSystemBuild: "fixture-build"
            ),
            .expired
        )
    }
}
