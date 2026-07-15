import Foundation

// Private release-candidate input template. The candidate builder replaces
// every __LIDSWITCH_*__ token from final measured artifacts, writes the result
// to Sources/LidSwitch/GeneratedReleaseHelperTrustAnchor.generated.swift, and
// sets LIDSWITCH_RELEASE_CANDIDATE=1 for that one build only.
//
// Bytes are canonical base64 without whitespace. No app CDHash is permitted:
// the app's final signature must never authenticate a value embedded in itself.
#if LIDSWITCH_RELEASE_CANDIDATE
enum GeneratedReleaseHelperTrustAnchor {
    static let value = ReleaseHelperTrustAnchor.Value(
        channel: "manual-ad-hoc",
        helperSHA256: Data(base64Encoded: "__LIDSWITCH_HELPER_SHA256_BASE64__")!,
        helperSize: __LIDSWITCH_HELPER_SIZE__,
        helperIdentifier: "__LIDSWITCH_HELPER_IDENTIFIER__",
        helperCDHash: Data(base64Encoded: "__LIDSWITCH_HELPER_CDHASH_BASE64__")!,
        releaseIdentityResourceName: "LidSwitchReleaseIdentity.json",
        releaseIdentityVersion: "0.2.10",
        releaseIdentitySHA256: Data(base64Encoded: "__LIDSWITCH_RELEASE_IDENTITY_SHA256_BASE64__")!
    )
}
#endif
