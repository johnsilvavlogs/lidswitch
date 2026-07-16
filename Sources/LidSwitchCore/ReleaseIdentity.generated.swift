import Foundation

// Generated from release/identity.json by scripts/render-release-identity.mjs.
// Do not edit this tracked mirror; the renderer's --check mode rejects drift.
public enum ReleaseIdentity {
    public static let appVersion = "0.2.12"
    public static let appBuild = "5"
    public static let helperVersion = "5"
    public static let xpcProtocolVersion: UInt32 = 2
    public static let enrollmentPolicyProtocolVersion: UInt32 = 1
    public static let releaseTag = "v0.2.12"
    public static let appBundleIdentifier = "com.johnsilva.LidSwitch"
    public static let helperLabel = "com.johnsilva.lidswitch.helper"
    public static let machService = "com.johnsilva.lidswitch.helper.control"
    public static let qualifiedSystemBuild = "25F84"
    public static let channel = "manual-ad-hoc"
    public static let rootSupportDirectory = "/Library/Application Support/LidSwitch"
    public static let rootHelperPath = "/Library/Application Support/LidSwitch/Current/LidSwitchHelper"
    public static let rootAppliedStatePath = "/Library/Application Support/LidSwitch/applied-state"
    public static let rootStatusPath = "/Library/Application Support/LidSwitch/helper-status"
    public static let rootEnrollmentPolicyPath = "/Library/Application Support/LidSwitch/Current/enrollment-policy"

    public static func programArguments(ownerUID: UInt32, executable: String = rootHelperPath) -> [String] {
        [
            executable,
            "--owner-uid", String(ownerUID),
            "--qualified-build", qualifiedSystemBuild,
            "--support-directory", rootSupportDirectory,
            "--applied-state", rootAppliedStatePath,
            "--status-path", rootStatusPath,
            "--policy-path", rootEnrollmentPolicyPath,
        ]
    }
}
