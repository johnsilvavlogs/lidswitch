import Foundation
import LidSwitchXPCBridge
import XCTest
@testable import LidSwitch

final class HelperRestoreGuidanceTests: XCTestCase {
    func testHelperErrorsHavePlainDescriptionsAndOnlyDefiniteFailuresRequireRepair() {
        let authentication = Int32(LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE.rawValue)
        for error in [
            HelperControlError.unavailable, .transport(authentication), .malformedReply,
            .rejected("containment-extinction-unproven"),
        ] {
            XCTAssertTrue(error.requiresInlineRepair)
            XCTAssertFalse(error.localizedDescription.contains("HelperControlError"))
            XCTAssertFalse(error.localizedDescription.contains("error 2"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        for error in [
            HelperControlError.indeterminateTransport(60), .indeterminateTransport(57),
            .transport(12), .rejected("native-state-indeterminate"), .rejected("containment-pending"),
        ] {
            XCTAssertFalse(error.requiresInlineRepair)
            XCTAssertFalse(error.localizedDescription.contains("HelperControlError"))
        }
        XCTAssertEqual(
            HelperRestoreGuidance.failureDetail(NSError(domain: "PrivateImplementation", code: 123)),
            "The helper could not finish restoring sleep."
        )
    }

}
