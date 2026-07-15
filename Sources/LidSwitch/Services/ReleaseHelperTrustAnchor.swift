import CryptoKit
import Foundation
import LidSwitchCore

/// Release installation is opt-in at compile time and binds both the helper and
/// the immutable release-identity resource.  The generated value deliberately
/// contains no app CDHash: embedding the final app signature here would make
/// the app's own signature part of the value it is attempting to authenticate.
enum ReleaseHelperTrustAnchor {
    static let releaseIdentityResourceName = "LidSwitchReleaseIdentity.json"

    struct Value: Equatable {
        let channel: String
        let helperSHA256: Data
        let helperSize: UInt64
        let helperIdentifier: String
        let helperCDHash: Data
        let releaseIdentityResourceName: String
        let releaseIdentityVersion: String
        let releaseIdentitySHA256: Data
    }

    struct Candidate: Equatable {
        let channel: String
        let helperIdentifier: String
        let helperCDHash: Data
        let helperSHA256: Data
        let helperSize: UInt64
        let releaseIdentityResourceName: String
        let releaseIdentityVersion: String
        let releaseIdentitySHA256: Data
    }

    #if LIDSWITCH_RELEASE_CANDIDATE
    private static let generated: Value? = GeneratedReleaseHelperTrustAnchor.value
    #else
    private static let generated: Value? = nil
    #endif

    static var value: Value? { validated(generated) }

    static func matches(
        helperIdentifier: String,
        helperCDHash: Data,
        helperSHA256: Data,
        helperSize: UInt64,
        releaseIdentitySHA256: Data
    ) -> Bool {
        matches(
            Candidate(
                channel: ReleaseIdentity.channel,
                helperIdentifier: helperIdentifier,
                helperCDHash: helperCDHash,
                helperSHA256: helperSHA256,
                helperSize: helperSize,
                releaseIdentityResourceName: releaseIdentityResourceName,
                releaseIdentityVersion: ReleaseIdentity.appVersion,
                releaseIdentitySHA256: releaseIdentitySHA256
            ),
            generated: value
        )
    }

    /// Internal fixture seam.  Production always supplies `value`; tests can
    /// exercise the same strict comparison against a synthetic generated value
    /// without making a normal build install-capable.
    static func matches(_ candidate: Candidate, generated: Value?) -> Bool {
        guard let anchor = validated(generated) else { return false }
        return anchor.channel == candidate.channel
            && anchor.helperIdentifier == candidate.helperIdentifier
            && anchor.helperSize == candidate.helperSize
            && anchor.releaseIdentityResourceName == candidate.releaseIdentityResourceName
            && anchor.releaseIdentityVersion == candidate.releaseIdentityVersion
            && constantTimeEqual(anchor.helperCDHash, candidate.helperCDHash)
            && constantTimeEqual(anchor.helperSHA256, candidate.helperSHA256)
            && constantTimeEqual(anchor.releaseIdentitySHA256, candidate.releaseIdentitySHA256)
    }

    private static func validated(_ candidate: Value?) -> Value? {
        guard let candidate,
              candidate.channel == ReleaseIdentity.channel,
              candidate.helperSHA256.count == SHA256.Digest.byteCount,
              candidate.helperSHA256 != Data(repeating: 0, count: SHA256.Digest.byteCount),
              candidate.helperSize > 0,
              !candidate.helperIdentifier.isEmpty,
              candidate.helperCDHash.count == 20,
              candidate.helperCDHash != Data(repeating: 0, count: 20),
              candidate.releaseIdentityResourceName == releaseIdentityResourceName,
              candidate.releaseIdentityVersion == ReleaseIdentity.appVersion,
              candidate.releaseIdentitySHA256.count == SHA256.Digest.byteCount,
              candidate.releaseIdentitySHA256 != Data(repeating: 0, count: SHA256.Digest.byteCount)
        else { return nil }
        return candidate
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return left.withUnsafeBytes { (lhs: UnsafeRawBufferPointer) in right.withUnsafeBytes { (rhs: UnsafeRawBufferPointer) in
            var difference: UInt8 = 0
            for index in 0..<left.count { difference |= lhs[index] ^ rhs[index] }
            return difference == 0
        }}
    }
}
