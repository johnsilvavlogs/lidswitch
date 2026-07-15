import Foundation
import XCTest
@testable import LidSwitch
import LidSwitchCore

final class ReleaseIdentitySourceTests: XCTestCase {
    func testGeneratedLaunchDaemonContractRendersTheCommittedTemplateByteForByte() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let template = try String(
            contentsOf: root.appendingPathComponent("release/LidSwitchLaunchDaemon.plist.template"),
            encoding: .utf8
        )
        let expected = template.replacingOccurrences(of: "__LIDSWITCH_OWNER_UID__", with: "501")

        XCTAssertEqual(LaunchDaemonContract.render(ownerUID: 501), expected)
        XCTAssertEqual(LaunchDaemonContract.programArgumentCount, 13)
        XCTAssertEqual(LaunchDaemonContract.provisionArgumentCount, 15)
        XCTAssertEqual(LaunchDaemonContract.recoveryArgumentCount, 17)
        XCTAssertEqual(LaunchDaemonContract.programArguments(ownerUID: 501).count, 13)
        XCTAssertEqual(
            LaunchDaemonContract.provisionArguments(ownerUID: 501, executable: "/staged/helper").count,
            15
        )
        XCTAssertEqual(
            LaunchDaemonContract.recoveryArguments(
                ownerUID: 501,
                executable: "/staged/helper",
                intent: .install
            ).count,
            17
        )
        XCTAssertEqual(
            Array(LaunchDaemonContract.provisionArguments(
                ownerUID: 501,
                executable: "/staged/helper"
            ).dropFirst()),
            Array(LaunchDaemonContract.programArguments(ownerUID: 501).dropFirst())
                + ["--mode", "provision-root-state-lock"]
        )
        XCTAssertEqual(ReleaseIdentity.xpcProtocolVersion, 2)
        XCTAssertEqual(ReleaseIdentity.enrollmentPolicyProtocolVersion, 1)
    }
}
