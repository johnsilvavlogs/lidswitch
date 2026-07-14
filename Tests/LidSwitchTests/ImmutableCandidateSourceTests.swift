import CryptoKit
import Foundation
import XCTest
@testable import LidSwitch
import LidSwitchCore

final class ImmutableCandidateSourceTests: XCTestCase {
    private let digest = Data(repeating: 0x11, count: 32)
    private let cdhash = Data(repeating: 0x22, count: 20)

    private func anchor(
        channel: String = ReleaseIdentity.channel,
        helperDigest: Data? = nil,
        helperSize: UInt64 = 42,
        helperCDHash: Data? = nil,
        resourceName: String = ReleaseHelperTrustAnchor.releaseIdentityResourceName,
        version: String = ReleaseIdentity.appVersion,
        resourceDigest: Data? = nil
    ) -> ReleaseHelperTrustAnchor.Value {
        .init(
            channel: channel,
            helperSHA256: helperDigest ?? digest,
            helperSize: helperSize,
            helperIdentifier: AppPaths.helperLabel,
            helperCDHash: helperCDHash ?? cdhash,
            releaseIdentityResourceName: resourceName,
            releaseIdentityVersion: version,
            releaseIdentitySHA256: resourceDigest ?? digest
        )
    }

    private func candidate() -> ReleaseHelperTrustAnchor.Candidate {
        .init(
            channel: ReleaseIdentity.channel,
            helperIdentifier: AppPaths.helperLabel,
            helperCDHash: cdhash,
            helperSHA256: digest,
            helperSize: 42,
            releaseIdentityResourceName: ReleaseHelperTrustAnchor.releaseIdentityResourceName,
            releaseIdentityVersion: ReleaseIdentity.appVersion,
            releaseIdentitySHA256: digest
        )
    }

    func testGeneratedReleaseAnchorAcceptsExactHelperAndIdentityResource() {
        XCTAssertTrue(ReleaseHelperTrustAnchor.matches(candidate(), generated: anchor()))
    }

    func testNormalBuildAnchorCategoricallyFailsClosed() {
        XCTAssertFalse(ReleaseHelperTrustAnchor.matches(
            helperIdentifier: AppPaths.helperLabel,
            helperCDHash: cdhash,
            helperSHA256: digest,
            helperSize: 42,
            releaseIdentitySHA256: digest
        ))
        XCTAssertFalse(ReleaseHelperTrustAnchor.matches(candidate(), generated: nil))
    }

    func testMalformedGeneratedAnchorsDenyBeforeEnrollment() {
        let zeros32 = Data(repeating: 0, count: 32)
        let zeros20 = Data(repeating: 0, count: 20)
        let malformed = [
            anchor(channel: "debug"),
            anchor(helperDigest: zeros32),
            anchor(helperSize: 0),
            anchor(helperCDHash: zeros20),
            anchor(resourceName: "Other.json"),
            anchor(version: "0"),
            anchor(resourceDigest: zeros32),
        ]
        for value in malformed {
            XCTAssertFalse(ReleaseHelperTrustAnchor.matches(candidate(), generated: value))
        }
    }

    func testReleaseIdentityDigestAndHelperFieldsMustAllMatch() {
        var changedDigest = candidate()
        changedDigest = .init(channel: changedDigest.channel, helperIdentifier: changedDigest.helperIdentifier,
                              helperCDHash: changedDigest.helperCDHash, helperSHA256: changedDigest.helperSHA256,
                              helperSize: changedDigest.helperSize, releaseIdentityResourceName: changedDigest.releaseIdentityResourceName,
                              releaseIdentityVersion: changedDigest.releaseIdentityVersion,
                              releaseIdentitySHA256: Data(repeating: 0x33, count: 32))
        XCTAssertFalse(ReleaseHelperTrustAnchor.matches(changedDigest, generated: anchor()))
        XCTAssertFalse(ReleaseHelperTrustAnchor.matches(
            .init(channel: ReleaseIdentity.channel, helperIdentifier: AppPaths.helperLabel, helperCDHash: cdhash,
                  helperSHA256: digest, helperSize: 43,
                  releaseIdentityResourceName: ReleaseHelperTrustAnchor.releaseIdentityResourceName,
                  releaseIdentityVersion: ReleaseIdentity.appVersion, releaseIdentitySHA256: digest),
            generated: anchor()
        ))
    }

    func testRootCopyAuthorityRejectsDigestSizeAndCodeIdentityMismatches() {
        let identity = CodeIdentity(identifier: AppPaths.helperLabel, cdhash: cdhash, teamIdentifier: nil)
        XCTAssertTrue(SecureHelperInstaller.rootCopyContractIsExact(
            sourceDigest: digest, sourceSize: 42, copiedDigest: digest, copiedSize: 42,
            sourceIdentity: identity, copiedIdentity: identity
        ))
        XCTAssertFalse(SecureHelperInstaller.rootCopyContractIsExact(
            sourceDigest: digest, sourceSize: 42, copiedDigest: Data(repeating: 0x44, count: 32), copiedSize: 42,
            sourceIdentity: identity, copiedIdentity: identity
        ))
        XCTAssertFalse(SecureHelperInstaller.rootCopyContractIsExact(
            sourceDigest: digest, sourceSize: 42, copiedDigest: digest, copiedSize: 41,
            sourceIdentity: identity, copiedIdentity: identity
        ))
        XCTAssertFalse(SecureHelperInstaller.rootCopyContractIsExact(
            sourceDigest: digest, sourceSize: 42, copiedDigest: digest, copiedSize: 42,
            sourceIdentity: identity,
            copiedIdentity: CodeIdentity(identifier: AppPaths.helperLabel, cdhash: Data(repeating: 0x45, count: 20), teamIdentifier: nil)
        ))
    }

    func testFrozenTransferReceiptRejectsPayloadDigestSizeAndIdentityDrift() {
        let transfer = SecureHelperInstaller.FrozenHelperTransfer(
            payload: Data([1, 2, 3]),
            sha256: Data(SHA256.hash(data: Data([1, 2, 3]))),
            size: 3,
            identifier: AppPaths.helperLabel,
            cdhash: cdhash
        )
        XCTAssertTrue(transfer.isSelfConsistent)
        XCTAssertFalse(SecureHelperInstaller.FrozenHelperTransfer(
            payload: transfer.payload, sha256: digest, size: transfer.size,
            identifier: transfer.identifier, cdhash: transfer.cdhash
        ).isSelfConsistent)
        XCTAssertFalse(SecureHelperInstaller.FrozenHelperTransfer(
            payload: transfer.payload, sha256: transfer.sha256, size: 2,
            identifier: transfer.identifier, cdhash: transfer.cdhash
        ).isSelfConsistent)
        XCTAssertFalse(SecureHelperInstaller.FrozenHelperTransfer(
            payload: transfer.payload, sha256: transfer.sha256, size: transfer.size,
            identifier: "", cdhash: transfer.cdhash
        ).isSelfConsistent)
    }

    func testAdministratorTransactionRunnerIsUnreachableOnFreezeDenial() {
        struct DenyingAdapter: SecureHelperInstaller.FrozenEnrollmentAdapter {
            func freeze() throws -> SecureHelperInstaller.FrozenEnrollment {
                throw NSError(domain: "ImmutableCandidate", code: 1)
            }
        }
        var runnerInvoked = false
        XCTAssertThrowsError(try SecureHelperInstaller.authorizeThenRun(
            freeze: { throw NSError(domain: "ImmutableCandidate", code: 2) },
            run: { _ in runnerInvoked = true }
        ))
        XCTAssertFalse(runnerInvoked)
        XCTAssertThrowsError(try SecureHelperInstaller.perform(.install, using: DenyingAdapter()))
    }

}
