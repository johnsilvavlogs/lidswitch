import CryptoKit
import Darwin
import Foundation
import LidSwitchCore

/// Builds one frozen helper/enrollment and one bounded administrator
/// transaction for install, restore, and uninstall. The root wrapper stages and
/// verifies bytes, but only the helper one-shot can interpret or mutate recovery
/// authority and power state.
enum SecureHelperInstaller {
    private static let maximumHelperBytes = 16 * 1_024 * 1_024

    // Darwin rejects O_NOFOLLOW and O_NOFOLLOW_ANY when they are combined.
    // O_NOFOLLOW_ANY is the stronger contract: it rejects a symlink in any
    // pathname component, including the leaf, so adding O_NOFOLLOW is both
    // redundant and an EINVAL failure on the live installer path.
    static let immutableDirectoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC

    struct FrozenEnrollment {
        let transfer: FrozenHelperTransfer
        let policy: EnrollmentPolicy
    }

    /// Receipt for the descriptor-bound private stage. The administrator
    /// script carries only this bounded capability metadata; root reopens the
    /// path with `O_NOFOLLOW_ANY` and requires the exact inode, metadata,
    /// length, and digest before the staged bytes can become executable.
    struct FrozenHelperTransfer: Equatable {
        let sourcePath: String
        let sourceDevice: UInt64
        let sourceInode: UInt64
        let sourceOwnerUID: UInt32
        let sourceOwnerGID: UInt32
        let sourceMode: UInt32
        let sourceLinks: UInt64
        let sha256: Data
        let size: UInt64
        let identifier: String
        let cdhash: Data

        var isSelfConsistent: Bool {
            sourcePath.hasPrefix("/")
                && !sourcePath.utf8.contains(0)
                && sourcePath.utf8.count < Int(PATH_MAX)
                && URL(fileURLWithPath: sourcePath).lastPathComponent == "LidSwitchHelper"
                && sourceDevice > 0 && sourceInode > 0
                && sourceMode & UInt32(S_IFMT) == UInt32(S_IFREG)
                && sourceMode & 0o7777 == 0o700
                && sourceLinks == 1
                && sha256.count == SHA256.Digest.byteCount
                && size > 0 && size <= UInt64(maximumHelperBytes)
                && cdhash.count == 20 && !identifier.isEmpty
        }
    }

    protocol FrozenEnrollmentAdapter {
        func freeze() throws -> FrozenEnrollment
    }

    private struct ProductionFrozenEnrollmentAdapter: FrozenEnrollmentAdapter {
        func freeze() throws -> FrozenEnrollment { try SecureHelperInstaller.freezeEnrollment() }
    }

    /// Internal transaction seam: the runner is structurally unreachable when
    /// the freezer reports a denial.  XCTest fixtures use this without touching
    /// a bundle, descriptor, authorization dialog, or root state.
    static func authorizeThenRun<Result>(
        freeze: () throws -> FrozenEnrollment,
        run: (FrozenEnrollment) throws -> Result
    ) throws -> Result {
        try run(freeze())
    }

    static func perform(_ operation: AdministratorOperation) throws -> AdministratorOperationResult {
        try perform(operation, using: ProductionFrozenEnrollmentAdapter())
    }

    static func perform(
        _ operation: AdministratorOperation,
        using adapter: some FrozenEnrollmentAdapter
    ) throws -> AdministratorOperationResult {
        try authorizeThenRun(freeze: adapter.freeze) { enrollment in
        let transactionID = UUID()
        let receiptPath = AppPaths.administratorReceiptPath(transactionID: transactionID)
        let script = transactionScript(
            enrollment: enrollment,
            transactionID: transactionID,
            receiptPath: receiptPath,
            operation: operation
        )
        let prompt: String
        switch operation {
        case .install:
            prompt = "LidSwitch needs administrator permission to install its authenticated crash-safe helper. Protection will remain off."
        case .uninstall:
            prompt = "LidSwitch needs administrator permission to restore system sleep before removing helper files."
        case .userRestore:
            prompt = "LidSwitch needs administrator permission to restore system sleep with the verified helper."
        }
        return AdministratorTransactionRunner.run(
            script: script,
            prompt: prompt,
            transactionID: transactionID,
            operation: operation,
            receiptPath: receiptPath
        )
        }
    }

    static func diagnosticScript(for operation: AdministratorOperation) -> String {
        let zero20 = Data(repeating: 0, count: 20)
        let helperSHA256 = Data(SHA256.hash(data: Data([0])))
        let policy = EnrollmentPolicy(
            ownerUID: UInt32(getuid()),
            profile: .manualExact,
            appIdentifier: AppPaths.bundleIdentifier,
            appCDHash: zero20,
            helperIdentifier: AppPaths.helperLabel,
            helperCDHash: zero20,
            helperSHA256: helperSHA256,
            helperSize: 1,
            qualifiedBuild: ReleaseIdentity.qualifiedSystemBuild,
            teamIdentifier: nil
        )
        let transactionID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        return transactionScript(
            enrollment: .init(
                transfer: .init(sourcePath: "/private/tmp/lidswitch-diagnostic/LidSwitchHelper",
                                sourceDevice: 1, sourceInode: 1,
                                sourceOwnerUID: UInt32(getuid()), sourceOwnerGID: UInt32(getgid()),
                                sourceMode: UInt32(S_IFREG | 0o700), sourceLinks: 1,
                                sha256: helperSHA256, size: 1,
                                identifier: AppPaths.helperLabel, cdhash: zero20),
                policy: policy
            ),
            transactionID: transactionID,
            receiptPath: AppPaths.administratorReceiptPath(transactionID: transactionID),
            operation: operation
        )
    }

    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let group: gid_t
        let mode: mode_t
        let links: nlink_t
        let size: off_t

        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino
            owner = value.st_uid; group = value.st_gid; mode = value.st_mode
            links = value.st_nlink; size = value.st_size
        }

        var isRegular: Bool { (mode & S_IFMT) == S_IFREG }
        var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
        var permissions: mode_t { mode & 0o7777 }

        func hasSameDirectoryCapabilityIdentity(as other: Snapshot) -> Bool {
            isDirectory && other.isDirectory
                && device == other.device && inode == other.inode
                && owner == other.owner && group == other.group
                && mode == other.mode
            // Directory st_nlink and st_size are APFS inventory bookkeeping,
            // not capability identity. Exact descriptor-relative inventory is
            // checked separately, so the installer accepts only its own one
            // staged helper leaf without trusting either mutable counter.
        }
    }

    private struct HeldArtifact {
        let parentDescriptor: Int32
        let descriptor: Int32
        let parentPath: String
        let leaf: String
        let initial: Snapshot
        let ownsParent: Bool
    }

    private struct PrivateStage {
        let parentDescriptor: Int32
        let descriptor: Int32
        let parentPath: String
        let name: String
        let initial: Snapshot

        var url: URL { URL(fileURLWithPath: parentPath, isDirectory: true).appendingPathComponent(name, isDirectory: true) }
    }

    private static func freezeEnrollment() throws -> FrozenEnrollment {
        let expectedUID = getuid()
        let expectedGID = getgid()
        let appDescriptor = try openDirectory(Bundle.main.bundleURL.path, expectedUID: expectedUID, expectedGID: expectedGID)
        var appClosed = false
        defer { if !appClosed { precondition(close(appDescriptor) == 0, "app descriptor close failed") } }
        guard let runningApp = CodeIdentity.current(),
              let onDiskApp = CodeIdentity.staticCode(at: Bundle.main.bundleURL.path),
              manualAdHocIdentity(runningApp, expectedIdentifier: AppPaths.bundleIdentifier),
              manualAdHocIdentity(onDiskApp, expectedIdentifier: AppPaths.bundleIdentifier),
              runningApp == onDiskApp,
              reassertDirectory(appDescriptor)
        else { throw HelperControlError.rejected("running-on-disk-app-identity-mismatch") }

        guard let releaseURL = Bundle.main.url(forResource: "LidSwitchReleaseIdentity", withExtension: "json"),
              releaseURL.lastPathComponent == ReleaseHelperTrustAnchor.releaseIdentityResourceName
        else { throw HelperControlError.rejected("release-identity-resource-missing") }
        let release = try openBundleArtifact(releaseURL, expectedMode: 0o644, expectedUID: expectedUID, expectedGID: expectedGID)
        var releaseClosed = false
        defer { if !releaseClosed { closeArtifactBestEffort(release) } }
        let releaseBytes = try readExactly(release)
        let releaseStable = reassert(release)
        releaseClosed = true
        guard releaseStable, closeArtifact(release),
              let anchor = ReleaseHelperTrustAnchor.value,
              releaseIdentityPayloadMatches(releaseBytes, anchor: anchor)
        else { throw HelperControlError.rejected("release-identity-resource-mismatch") }
        let releaseDigest = Data(SHA256.hash(data: releaseBytes))

        let bundled = try openBundleArtifact(AppPaths.bundledHelperFile, expectedMode: 0o755, expectedUID: expectedUID, expectedGID: expectedGID)
        var bundledClosed = false
        defer { if !bundledClosed { closeArtifactBestEffort(bundled) } }
        let helperBytes = try readExactly(bundled)
        let bundledStable = reassert(bundled)
        bundledClosed = true
        guard closeArtifact(bundled), bundledStable else {
            throw HelperControlError.rejected("bundled-helper-descriptor-unstable")
        }
        let helperDigest = Data(SHA256.hash(data: helperBytes))

        let stage = try createPrivateStage(expectedUID: expectedUID, expectedGID: expectedGID)
        var stageClosed = false
        defer { if !stageClosed { closeStageBestEffort(stage) } }
        let stagedName = "LidSwitchHelper"
        let stagedURL = stage.url.appendingPathComponent(stagedName, isDirectory: false)
        try writeStage(stage, leaf: stagedName, bytes: helperBytes)
        let staged = try reopenStageArtifact(stage, leaf: stagedName, expectedUID: expectedUID, expectedGID: expectedGID)
        var stagedClosed = false
        defer { if !stagedClosed { closeArtifactBestEffort(staged) } }
        let stagedBytes = try readExactly(staged)
        let stagedStableBeforeIdentity = reassert(staged) && reassertStage(stage, expectedLeaf: stagedName)
        stagedClosed = true
        guard closeArtifact(staged), stagedStableBeforeIdentity,
              stagedBytes == helperBytes,
              Data(SHA256.hash(data: stagedBytes)) == helperDigest,
              UInt64(stagedBytes.count) == UInt64(helperBytes.count)
        else { throw HelperControlError.rejected("staged-helper-digest-mismatch") }

        // Security's static-code API is pathname based.  It is therefore only
        // applied to the private staged copy, bracketed by held-directory inode
        // reassertions; the bundled pathname is never reopened for code identity.
        guard reassertStage(stage, expectedLeaf: stagedName),
              let stagedIdentity = CodeIdentity.staticCode(at: stagedURL.path),
              manualAdHocIdentity(stagedIdentity, expectedIdentifier: AppPaths.helperLabel),
              reassertStage(stage, expectedLeaf: stagedName)
        else { throw HelperControlError.rejected("staged-helper-code-identity-mismatch") }

        let anchorMatches = ReleaseHelperTrustAnchor.matches(
            helperIdentifier: stagedIdentity.identifier,
            helperCDHash: stagedIdentity.cdhash,
            helperSHA256: helperDigest,
            helperSize: UInt64(helperBytes.count),
            releaseIdentitySHA256: releaseDigest
        )
        let rootCopyContract = rootCopyContractIsExact(
            sourceDigest: helperDigest,
            sourceSize: UInt64(helperBytes.count),
            copiedDigest: helperDigest,
            copiedSize: UInt64(stagedBytes.count),
            sourceIdentity: stagedIdentity,
            copiedIdentity: stagedIdentity
        )
        stageClosed = true
        guard reassertDirectory(appDescriptor), anchorMatches, bundledStable,
              stagedStableBeforeIdentity, reassertStage(stage, expectedLeaf: stagedName),
              manualAdHocIdentity(stagedIdentity, expectedIdentifier: AppPaths.helperLabel),
              rootCopyContract, closeStage(stage)
        else {
            throw HelperControlError.rejected("immutable-candidate-freeze-denied")
        }

        let policy = EnrollmentPolicy(
            ownerUID: UInt32(expectedUID), profile: .manualExact,
            appIdentifier: runningApp.identifier, appCDHash: runningApp.cdhash,
            helperIdentifier: stagedIdentity.identifier, helperCDHash: stagedIdentity.cdhash,
            helperSHA256: helperDigest, helperSize: UInt64(helperBytes.count),
            qualifiedBuild: SystemBuild.current() ?? "unqualified", teamIdentifier: nil
        )
        guard EnrollmentPolicy.parse(policy.storagePayload) == policy else {
            throw HelperControlError.rejected("policy-self-check")
        }
        appClosed = true
        guard reassertDirectory(appDescriptor), close(appDescriptor) == 0 else {
            throw HelperControlError.rejected("app-descriptor-close-or-race")
        }
        let transfer = FrozenHelperTransfer(
            sourcePath: stagedURL.path,
            sourceDevice: UInt64(truncatingIfNeeded: staged.initial.device),
            sourceInode: UInt64(truncatingIfNeeded: staged.initial.inode),
            sourceOwnerUID: UInt32(staged.initial.owner),
            sourceOwnerGID: UInt32(staged.initial.group),
            sourceMode: UInt32(staged.initial.mode),
            sourceLinks: UInt64(staged.initial.links),
            sha256: helperDigest, size: UInt64(helperBytes.count),
            identifier: stagedIdentity.identifier, cdhash: stagedIdentity.cdhash
        )
        guard transfer.isSelfConsistent,
              transfer.sourceOwnerUID == policy.ownerUID,
              transfer.sha256 == policy.helperSHA256,
              transfer.size == policy.helperSize,
              transfer.identifier == policy.helperIdentifier,
              transfer.cdhash == policy.helperCDHash
        else { throw HelperControlError.rejected("frozen-transfer-receipt-mismatch") }
        return .init(transfer: transfer, policy: policy)
    }

    private static func manualAdHocIdentity(_ identity: CodeIdentity, expectedIdentifier: String) -> Bool {
        identity.identifier == expectedIdentifier && identity.cdhash.count == 20 && identity.teamIdentifier == nil
    }

    private static func releaseIdentityPayloadMatches(_ bytes: Data, anchor: ReleaseHelperTrustAnchor.Value) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              let values = object as? [String: Any],
              values["appVersion"] as? String == anchor.releaseIdentityVersion,
              values["channel"] as? String == anchor.channel,
              values["appBundleIdentifier"] as? String == AppPaths.bundleIdentifier,
              values["helperLabel"] as? String == AppPaths.helperLabel
        else { return false }
        return true
    }

    /// The root script uses the same rule after copying from the untrusted user
    /// stage into a new root-owned directory.  This callable seam lets fixtures
    /// prove a root-copy mismatch is a denial without administrator execution.
    static func rootCopyContractIsExact(
        sourceDigest: Data, sourceSize: UInt64, copiedDigest: Data, copiedSize: UInt64,
        sourceIdentity: CodeIdentity?, copiedIdentity: CodeIdentity?
    ) -> Bool {
        guard let sourceIdentity, let copiedIdentity else { return false }
        return sourceDigest.count == SHA256.Digest.byteCount && copiedDigest.count == SHA256.Digest.byteCount
            && sourceDigest == copiedDigest && sourceSize > 0 && sourceSize == copiedSize
            && sourceIdentity == copiedIdentity && manualAdHocIdentity(copiedIdentity, expectedIdentifier: AppPaths.helperLabel)
    }

    private static func openDirectory(_ path: String, expectedUID: uid_t, expectedGID: gid_t) throws -> Int32 {
        let descriptor = open(path, immutableDirectoryOpenFlags)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw HelperControlError.rejected("app-fstat-failed") }
        let snapshot = Snapshot(value)
        guard snapshot.isDirectory, snapshot.owner == expectedUID, snapshot.group == expectedGID,
              snapshot.permissions & 0o022 == 0
        else { throw HelperControlError.rejected("unsafe-app-directory") }
        return descriptor
    }

    private static func reassertDirectory(_ descriptor: Int32) -> Bool {
        var value = stat()
        return fstat(descriptor, &value) == 0 && Snapshot(value).isDirectory
    }

    private static func openBundleArtifact(_ url: URL, expectedMode: mode_t, expectedUID: uid_t, expectedGID: gid_t) throws -> HeldArtifact {
        let leaf = url.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { throw HelperControlError.rejected("unsafe-bundle-leaf") }
        let parentPath = url.deletingLastPathComponent().path
        let parent = open(parentPath, immutableDirectoryOpenFlags)
        guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var before = stat()
        guard fstatat(parent, leaf, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw HelperControlError.rejected("bundle-leaf-lstat-failed") }
        let descriptor = openat(parent, leaf, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw HelperControlError.rejected("bundle-leaf-fstat-failed") }
        let snapshot = Snapshot(opened)
        guard Snapshot(before) == snapshot, snapshot.isRegular, snapshot.owner == expectedUID,
              snapshot.group == expectedGID, snapshot.permissions == expectedMode,
              snapshot.links == 1, snapshot.size > 0, snapshot.size <= off_t(maximumHelperBytes)
        else { throw HelperControlError.rejected("unsafe-bundle-artifact") }
        return HeldArtifact(parentDescriptor: parent, descriptor: descriptor, parentPath: parentPath, leaf: leaf, initial: snapshot, ownsParent: true)
    }

    private static func readExactly(_ artifact: HeldArtifact) throws -> Data {
        var result = Data(); result.reserveCapacity(Int(artifact.initial.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while result.count < Int(artifact.initial.size) {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(artifact.descriptor, $0.baseAddress, min($0.count, Int(artifact.initial.size) - result.count)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw HelperControlError.rejected("artifact-short-read") }
            result.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        let eof = Darwin.read(artifact.descriptor, &extra, 1)
        guard eof == 0, result.count == Int(artifact.initial.size) else { throw HelperControlError.rejected("artifact-eof-or-growth") }
        return result
    }

    private static func reassert(_ artifact: HeldArtifact) -> Bool {
        var descriptorStat = stat(); var nameStat = stat()
        return fstat(artifact.descriptor, &descriptorStat) == 0
            && fstatat(artifact.parentDescriptor, artifact.leaf, &nameStat, AT_SYMLINK_NOFOLLOW) == 0
            && Snapshot(descriptorStat) == artifact.initial && Snapshot(nameStat) == artifact.initial
    }

    @discardableResult private static func closeArtifact(_ artifact: HeldArtifact) -> Bool {
        let artifactClosed = close(artifact.descriptor) == 0
        let parentClosed = !artifact.ownsParent || close(artifact.parentDescriptor) == 0
        return artifactClosed && parentClosed
    }
    private static func closeArtifactBestEffort(_ artifact: HeldArtifact) {
        precondition(close(artifact.descriptor) == 0, "artifact descriptor close failed")
        if artifact.ownsParent { precondition(close(artifact.parentDescriptor) == 0, "artifact parent close failed") }
    }

    private static func createPrivateStage(expectedUID: uid_t, expectedGID: gid_t) throws -> PrivateStage {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let home = try openDirectory(homePath, expectedUID: expectedUID, expectedGID: expectedGID)
        defer { precondition(close(home) == 0, "home descriptor close failed") }
        let parentName = ".lidswitch-frozen"
        if mkdirat(home, parentName, 0o700) != 0 && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let parent = openat(home, parentName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw HelperControlError.rejected("stage-parent-open-failed") }
        var parentStat = stat()
        guard fstat(parent, &parentStat) == 0 else { throw HelperControlError.rejected("stage-parent-fstat-failed") }
        let checkedParent = Snapshot(parentStat)
        guard checkedParent.isDirectory, checkedParent.owner == expectedUID, checkedParent.group == expectedGID,
              checkedParent.permissions == 0o700
        else { throw HelperControlError.rejected("unsafe-stage-parent") }
        let name = UUID().uuidString.lowercased()
        guard mkdirat(parent, name, 0o700) == 0 else { throw HelperControlError.rejected("stage-create-failed") }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HelperControlError.rejected("stage-open-failed") }
        var stageStat = stat(); var stageNameStat = stat()
        guard fstat(descriptor, &stageStat) == 0,
              fstatat(parent, name, &stageNameStat, AT_SYMLINK_NOFOLLOW) == 0
        else { throw HelperControlError.rejected("stage-fstat-failed") }
        let snapshot = Snapshot(stageStat)
        guard snapshot == Snapshot(stageNameStat), snapshot.isDirectory, snapshot.owner == expectedUID,
              snapshot.group == expectedGID, snapshot.permissions == 0o700
        else { throw HelperControlError.rejected("unsafe-stage-directory") }
        return PrivateStage(parentDescriptor: parent, descriptor: descriptor, parentPath: URL(fileURLWithPath: homePath, isDirectory: true).appendingPathComponent(parentName, isDirectory: true).path, name: name, initial: snapshot)
    }

    private static func reassertStage(_ stage: PrivateStage, expectedLeaf: String?) -> Bool {
        var descriptorStat = stat(); var nameStat = stat()
        guard fstat(stage.descriptor, &descriptorStat) == 0,
              fstatat(stage.parentDescriptor, stage.name, &nameStat, AT_SYMLINK_NOFOLLOW) == 0
        else { return false }
        return Snapshot(descriptorStat).hasSameDirectoryCapabilityIdentity(as: stage.initial)
            && Snapshot(nameStat).hasSameDirectoryCapabilityIdentity(as: stage.initial)
            && directoryInventoryMatches(stage.descriptor, expectedLeaf: expectedLeaf)
    }

    static func directoryCapabilityIdentityMatches(_ before: stat, _ after: stat) -> Bool {
        Snapshot(after).hasSameDirectoryCapabilityIdentity(as: Snapshot(before))
    }

    static func directoryInventoryMatches(_ descriptor: Int32, expectedLeaf: String?) -> Bool {
        let inventory = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard inventory >= 0, let stream = fdopendir(inventory) else {
            if inventory >= 0 { _ = close(inventory) }
            return false
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        errno = 0
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let length = Int(entry.d_namlen)
            guard length > 0, length <= Int(NAME_MAX) else { return false }
            var storage = entry.d_name
            let name: String? = withUnsafeBytes(of: &storage) { raw in
                guard length <= raw.count else { return nil }
                return String(bytes: raw.prefix(length), encoding: .utf8)
            }
            guard let name else { return false }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
            names.append(name)
            guard names.count <= 1 else { return false }
        }
        guard errno == 0 else { return false }
        return names == (expectedLeaf.map { [$0] } ?? [])
    }

    private static func writeStage(_ stage: PrivateStage, leaf: String, bytes: Data) throws {
        guard reassertStage(stage, expectedLeaf: nil) else { throw HelperControlError.rejected("stage-parent-raced") }
        let descriptor = openat(stage.descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o700)
        guard descriptor >= 0 else { throw HelperControlError.rejected("stage-file-create-failed") }
        var outputCloseAttempted = false
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw HelperControlError.rejected("stage-short-write") }
                    offset += count
                }
            }
            let outputSynced = fsync(descriptor) == 0 && fcntl(descriptor, F_FULLFSYNC) == 0
            let outputClosed = close(descriptor) == 0
            outputCloseAttempted = true
            guard outputSynced, outputClosed,
                  fsync(stage.descriptor) == 0, reassertStage(stage, expectedLeaf: leaf)
            else { throw HelperControlError.rejected("stage-sync-or-close-failed") }
        } catch {
            if !outputCloseAttempted { precondition(close(descriptor) == 0, "stage descriptor close failed") }
            throw error
        }
    }

    private static func reopenStageArtifact(_ stage: PrivateStage, leaf: String, expectedUID: uid_t, expectedGID: gid_t) throws -> HeldArtifact {
        guard reassertStage(stage, expectedLeaf: leaf) else { throw HelperControlError.rejected("stage-name-raced") }
        var before = stat()
        guard fstatat(stage.descriptor, leaf, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw HelperControlError.rejected("stage-file-lstat-failed") }
        let descriptor = openat(stage.descriptor, leaf, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HelperControlError.rejected("stage-file-open-failed") }
        var opened = stat(); guard fstat(descriptor, &opened) == 0 else { throw HelperControlError.rejected("stage-file-fstat-failed") }
        let snapshot = Snapshot(opened)
        guard Snapshot(before) == snapshot, snapshot.isRegular, snapshot.owner == expectedUID, snapshot.group == expectedGID,
              snapshot.permissions == 0o700, snapshot.links == 1, snapshot.size > 0, snapshot.size <= off_t(maximumHelperBytes)
        else { throw HelperControlError.rejected("unsafe-stage-file") }
        return HeldArtifact(parentDescriptor: stage.descriptor, descriptor: descriptor, parentPath: stage.url.path, leaf: leaf, initial: snapshot, ownsParent: false)
    }

    @discardableResult private static func closeStage(_ stage: PrivateStage) -> Bool {
        let stageClosed = close(stage.descriptor) == 0
        let parentClosed = close(stage.parentDescriptor) == 0
        return stageClosed && parentClosed
    }
    private static func closeStageBestEffort(_ stage: PrivateStage) {
        precondition(close(stage.descriptor) == 0, "stage descriptor close failed")
        precondition(close(stage.parentDescriptor) == 0, "stage parent close failed")
    }

    private static func transactionScript(
        enrollment: FrozenEnrollment,
        transactionID: UUID,
        receiptPath: String,
        operation: AdministratorOperation
    ) -> String {
        let transaction = transactionID.uuidString.lowercased()
        // The stage must never be an authority-root child: strict recovery
        // inventory correctly rejects unknown private children there.  A
        // sibling on the same filesystem permits an atomic final rename while
        // keeping the only authority-root transaction artifact as the receipt.
        let stageParent = URL(fileURLWithPath: AppPaths.rootSupportDirectory)
            .deletingLastPathComponent().path
        let stage = stageParent + "/.LidSwitch-administrator-" + transaction
        let stagedCurrent = stage + "/Current"
        let stagedHelper = stagedCurrent + "/LidSwitchHelper"
        let running = AdministratorTransactionReceipt.running(
            transactionID: transactionID,
            operation: operation
        ).payload.trimmingCharacters(in: .newlines)
        let expectedProvision = HelperOneShotResult.provisionReady.payload
            .trimmingCharacters(in: .newlines)
        let policyBase64 = Data(enrollment.policy.storagePayload.utf8).base64EncodedString()
        let policySHA256 = Data(SHA256.hash(data: Data(enrollment.policy.storagePayload.utf8))).hexEncoded
        let plistBase64 = Data(PrivilegedHelperManager.diagnosticLaunchDaemonPlist().utf8).base64EncodedString()
        precondition(enrollment.transfer.isSelfConsistent
            && enrollment.transfer.sourceOwnerUID == enrollment.policy.ownerUID
            && enrollment.transfer.sha256 == enrollment.policy.helperSHA256
            && enrollment.transfer.size == enrollment.policy.helperSize
            && enrollment.transfer.identifier == enrollment.policy.helperIdentifier
            && enrollment.transfer.cdhash == enrollment.policy.helperCDHash,
            "frozen helper transfer must match the enrollment receipt")
        let provisionCommand = commandLine(
            LaunchDaemonContract.provisionArguments(
                ownerUID: enrollment.policy.ownerUID,
                executable: stagedHelper
            )
        )
        let intent: RecoveryIntent
        switch operation {
        case .install: intent = .install
        case .uninstall: intent = .uninstall
        case .userRestore: intent = .userRestore
        }
        let recoveryCommand = commandLine(
            LaunchDaemonContract.recoveryArguments(
                ownerUID: enrollment.policy.ownerUID,
                executable: stagedHelper,
                intent: intent
            )
        )

        return """
        set -euo pipefail
        umask 077
        root=\(q(AppPaths.rootSupportDirectory))
        stage_parent=\(q(stageParent))
        current=\(q(AppPaths.rootCurrentDirectory))
        previous=\(q(AppPaths.rootPreviousDirectory))
        plist=\(q(AppPaths.launchDaemonPath))
        status_path=\(q(AppPaths.rootHelperStatusPath))
        helper_source=\(q(enrollment.transfer.sourcePath))
        receipt=\(q(receiptPath))
        stage=\(q(stage))
        stage_current=\(q(stagedCurrent))
        helper=\(q(stagedHelper))
        legacy_target=\(q("gui/\(enrollment.policy.ownerUID)/com.johnsilva.LidSwitch.login"))
        current_target=\(q("system/\(AppPaths.helperLabel)"))
        administrator_lock=/private/var/run/com.johnsilva.lidswitch.administrator.lock
        transaction=\(q(transaction))
        operation=\(q(operation.rawValue))
        completed=0
        booted_out=0
        recovery_safe=0
        old_current_rotated=0
        new_current_published=0
        plist_published=0
        had_current=0
        had_plist=0
        failure_reason=transaction-failed

        root_is_valid() {
          [ ! -L "$root" ] && [ -d "$root" ] || return 1
          [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$root")" = "0:0:755" ]
        }

        stage_is_verified() {
          [ ! -L "$stage" ] && [ -d "$stage" ] || return 1
          [ "$(/usr/bin/stat -f '%u:%g:%Lp:%d' "$stage")" = "0:0:700:$(/usr/bin/stat -f '%d' "$root")" ]
        }

        cleanup_verified_stage() {
          stage_is_verified || return 1
          /bin/rm -rf "$stage"
        }

        validate_root() {
          if [ -e "$root" ] || [ -L "$root" ]; then
            root_is_valid || return 65
          else
            /bin/mkdir -m 0755 "$root"
            /usr/sbin/chown root:wheel "$root"
            root_is_valid || return 65
          fi
        }

        publish_receipt() {
          mode="$1"
          payload="$2"
          LIDSWITCH_RECEIPT_PAYLOAD="$payload" /usr/bin/perl -MFcntl=:DEFAULT,:mode -MIO::Handle -e '
            use strict; use warnings;
            my ($root, $receipt, $mode) = @ARGV;
            my $payload = $ENV{"LIDSWITCH_RECEIPT_PAYLOAD"};
            die "receipt-payload" unless defined($payload) && length($payload) > 0 && length($payload) < 1024 && index($payload, "\\0") < 0;
            $payload .= "\\n";
            my @root = lstat($root); die "receipt-root" unless @root && S_ISDIR($root[2]) && $root[4] == 0 && $root[5] == 0 && ($root[2] & 0777) == 0755;
            my @old = lstat($receipt);
            if ($mode eq "create") { die "receipt-exists" if @old; }
            elsif ($mode eq "update") { die "receipt-old" unless @old && S_ISREG($old[2]) && $old[3] == 1 && $old[4] == 0 && $old[5] == 0 && ($old[2] & 0777) == 0644 && $old[7] > 0 && $old[7] <= 1024; }
            else { die "receipt-mode"; }
            my $temp = $receipt . ".tmp." . $$;
            my $renamed = 0;
            END { unlink($temp) if defined($temp) && !$renamed && -e $temp; }
            sysopen(my $out, $temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or die "receipt-create";
            my $offset = 0;
            while ($offset < length($payload)) { my $wrote = syswrite($out, $payload, length($payload) - $offset, $offset); die "receipt-write" unless defined($wrote) && $wrote > 0; $offset += $wrote; }
            chown(0, 0, $temp) == 1 or die "receipt-owner";
            chmod(0644, $temp) == 1 or die "receipt-mode";
            $out->sync or die "receipt-fsync";
            fcntl($out, 51, 0) or die "receipt-fullfsync";
            close($out) or die "receipt-close";
            rename($temp, $receipt) or die "receipt-rename";
            $renamed = 1;
            sysopen(my $final, $receipt, O_RDONLY | O_NOFOLLOW) or die "receipt-reopen";
            my @final = stat($final); die "receipt-final" unless @final && S_ISREG($final[2]) && $final[3] == 1 && $final[4] == 0 && $final[5] == 0 && ($final[2] & 0777) == 0644 && $final[7] == length($payload);
            my $actual = ""; while (length($actual) < length($payload)) { my $read = sysread($final, my $chunk, length($payload) - length($actual)); die "receipt-read" unless defined($read) && $read > 0; $actual .= $chunk; }
            die "receipt-bytes" unless $actual eq $payload && sysread($final, my $extra, 1) == 0;
            $final->sync or die "receipt-final-fsync";
            close($final) or die "receipt-final-close";
            sysopen(my $directory, $root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or die "receipt-directory";
            $directory->sync or die "receipt-directory-fsync";
            close($directory) or die "receipt-directory-close";
          ' "$root" "$receipt" "$mode"
        }

        publish_failure() {
          outcome="$1"
          reason="$2"
          payload="schema=1
        transaction=$transaction
        operation=$operation
        state=terminal
        outcome=$outcome
        session=none
        reason=$reason"
          publish_receipt update "$payload"
        }

        restart_prior() {
          [ "$had_plist" = 1 ] || return 0
          /bin/launchctl enable system/\(AppPaths.helperLabel) >/dev/null 2>&1 || true
          /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || return 1
          /bin/launchctl print system/\(AppPaths.helperLabel) >/dev/null 2>&1
        }

        finish() {
          code=$?
          trap - EXIT
          set +e
          if [ "$completed" != 1 ]; then
            outcome=operation-failed
            rollback_ok=1
            if [ "$new_current_published" = 1 ]; then
              /bin/rm -rf "$current" || rollback_ok=0
            fi
            if [ "$old_current_rotated" = 1 ] && [ -d "$previous" ]; then
              /bin/mv "$previous" "$current" || rollback_ok=0
            fi
            if [ "$plist_published" = 1 ]; then
              if [ "$had_plist" = 1 ] && [ -f "$stage/previous.plist" ]; then
                /bin/cp -p "$stage/previous.plist" "$plist" || rollback_ok=0
              else
                /bin/rm -f "$plist" || rollback_ok=0
              fi
            fi
            if [ "$new_current_published" = 1 ] || [ "$old_current_rotated" = 1 ] || [ "$plist_published" = 1 ]; then
              /bin/sync || rollback_ok=0
            fi
            if [ "$rollback_ok" != 1 ]; then
              outcome=installed-but-stopped
              failure_reason=prior-installation-rollback-failed
            elif [ "$booted_out" = 1 ] && [ "$recovery_safe" != 1 ]; then
              # Never rearm the prior daemon after an unproved recovery. The
              # durable terminal receipt tells the app the installation is
              # intentionally stopped and needs repair.
              outcome=installed-but-stopped
              failure_reason=recovery-completion-unproven
            elif [ "$booted_out" = 1 ] && ! restart_prior; then
              outcome=installed-but-stopped
              failure_reason=prior-daemon-restart-failed
            fi
            publish_failure "$outcome" "$failure_reason" >/dev/null 2>&1 || true
          fi
          cleanup_verified_stage || rollback_ok=0
          exit "$code"
        }

        # One held file description serializes install, uninstall, and restore
        # across every app instance. lockf's descriptor form leaves no stale
        # ownership token after a crash; the persistent root-only inode keeps
        # lock ordering stable across transactions.
        exec 9>"$administrator_lock"
        /usr/sbin/chown root:wheel "$administrator_lock"
        /bin/chmod 0600 "$administrator_lock"
        [ "$(/usr/bin/stat -f '%u:%g:%Lp:%l' "$administrator_lock")" = "0:0:600:1" ] || exit 78
        if ! /usr/bin/lockf -s -t 0 9; then
          # A unique diagnostic receipt is safe when the product root already
          # exists and is exact. The transaction still performs no product
          # mutation if the root is absent or indeterminate.
          if root_is_valid; then
            publish_receipt create \(q(running))
            publish_failure operation-failed administrator-operation-already-running
          fi
          exit 75
        fi
        validate_root
        publish_receipt create \(q(running))
        trap finish EXIT

        failure_reason=stage-verification-failed
        [ ! -L "$stage_parent" ] && [ -d "$stage_parent" ] || exit 65
        # macOS owns this one canonical ancestor as root:admin. Keep the
        # exception exact and aligned with VerifiedRootStateDirectory's
        # production chain; the product root itself remains root:wheel.
        [ "$(/usr/bin/stat -f '%u:%g:%Lp:%d' "$stage_parent")" = "0:80:755:$(/usr/bin/stat -f '%d' "$root")" ] || exit 65
        # `mkdir` is exclusive: an existing or substituted stage is never
        # recursively removed, inspected as ours, or reused.
        /bin/mkdir -m 0700 "$stage" || exit 65
        /usr/sbin/chown root:wheel "$stage"
        stage_is_verified || exit 65
        /bin/mkdir -m 0700 "$stage_current"
        /usr/sbin/chown root:wheel "$stage" "$stage_current"
        stage_is_verified || exit 65
        # The user-owned source is only a location hint. O_NOFOLLOW_ANY rejects
        # every symlink component, and the held file must retain the exact
        # frozen inode, ownership, mode, link count, size, bytes, and digest.
        # Only the new root-owned O_EXCL copy is code-verified or executed.
        /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -e '
          use strict; use warnings;
          my ($source, $destination, $expected_dev, $expected_ino, $expected_uid,
              $expected_gid, $expected_mode, $expected_links, $expected_size,
              $expected_sha256) = @ARGV;
          for ($expected_dev, $expected_ino, $expected_uid, $expected_gid,
               $expected_mode, $expected_links, $expected_size) {
            die "transfer-metadata" unless defined($_) && /\\A[0-9]+\\z/;
          }
          die "transfer-size" unless $expected_size > 0 && $expected_size <= 16777216;
          die "transfer-digest" unless defined($expected_sha256) && $expected_sha256 =~ /\\A[0-9a-f]{64}\\z/;
          my $o_nofollow_any = 0x20000000;
          my $o_cloexec = 0x01000000;
          sysopen(my $input, $source, O_RDONLY | $o_nofollow_any | $o_cloexec) or die "transfer-open";
          my @before = stat($input);
          die "transfer-identity" unless @before && S_ISREG($before[2])
            && $before[0] == $expected_dev && $before[1] == $expected_ino
            && $before[2] == $expected_mode && $before[3] == $expected_links
            && $before[4] == $expected_uid && $before[5] == $expected_gid
            && $before[7] == $expected_size;
          sysopen(my $output, $destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | $o_cloexec, 0700) or die "stage-open";
          my $digest = Digest::SHA->new(256);
          my $total = 0;
          while ($total < $expected_size) {
            my $read = sysread($input, my $chunk, $expected_size - $total > 131072 ? 131072 : $expected_size - $total);
            if (!defined($read)) { next if $!{EINTR}; die "transfer-read"; }
            die "transfer-short" unless $read > 0;
            $digest->add($chunk);
            my $offset = 0;
            while ($offset < $read) {
              my $wrote = syswrite($output, $chunk, $read - $offset, $offset);
              if (!defined($wrote)) { next if $!{EINTR}; die "stage-write"; }
              die "stage-write" unless $wrote > 0;
              $offset += $wrote;
            }
            $total += $read;
          }
          while (1) {
            my $extra = sysread($input, my $byte, 1);
            if (!defined($extra)) { next if $!{EINTR}; die "transfer-eof"; }
            die "transfer-growth" unless $extra == 0;
            last;
          }
          my @after = stat($input);
          die "transfer-raced" unless @after
            && join(":", @after[0,1,2,3,4,5,7]) eq join(":", @before[0,1,2,3,4,5,7]);
          die "stage-short" unless $total == $expected_size;
          die "transfer-digest" unless $digest->hexdigest eq $expected_sha256;
          $output->sync or die "stage-fsync"; fcntl($output, 51, 0) or die "stage-fullfsync";
          close($input) or die "transfer-close";
          close($output) or die "stage-close";
        ' "$helper_source" "$helper" \(enrollment.transfer.sourceDevice) \(enrollment.transfer.sourceInode) \(enrollment.transfer.sourceOwnerUID) \(enrollment.transfer.sourceOwnerGID) \(enrollment.transfer.sourceMode) \(enrollment.transfer.sourceLinks) \(enrollment.policy.helperSize) \(enrollment.policy.helperSHA256.hexEncoded)
        [ ! -L "$helper" ] && [ -f "$helper" ] || exit 65
        [ "$(/usr/bin/stat -f '%HT:%u:%g:%Lp:%l:%z' "$helper")" = "Regular File:0:0:700:1:\(enrollment.policy.helperSize)" ] || exit 65
        [ "$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')" = "\(enrollment.policy.helperSHA256.hexEncoded)" ] || exit 65
        /usr/bin/codesign --verify --strict --verbose=2 "$helper" >/dev/null 2>&1
        identity="$(/usr/bin/codesign -dvvv "$helper" 2>&1)"
        [ "$(/usr/bin/printf '%s\\n' "$identity" | /usr/bin/awk -F= '$1=="Identifier"{print $2}')" = "\(enrollment.policy.helperIdentifier)" ] || exit 65
        [ "$(/usr/bin/printf '%s\\n' "$identity" | /usr/bin/awk -F= '$1=="CDHash"{print tolower($2)}')" = "\(enrollment.policy.helperCDHash.hexEncoded)" ] || exit 65
        /usr/sbin/chown root:wheel "$helper"
        /bin/chmod 0755 "$helper"
        /bin/echo \(q(policyBase64)) | /usr/bin/base64 --decode > "$stage_current/enrollment-policy"
        /usr/bin/printf '%s\\n' \(q(AppPaths.helperVersion)) > "$stage_current/helper-version"
        /bin/echo \(q(plistBase64)) | /usr/bin/base64 --decode > "$stage/helper.plist"
        /usr/sbin/chown -R root:wheel "$stage_current" "$stage/helper.plist"
        /bin/chmod 0755 "$stage_current"
        /bin/chmod 0644 "$stage_current/enrollment-policy" "$stage_current/helper-version" "$stage/helper.plist"
        [ "$(/usr/bin/shasum -a 256 "$stage_current/enrollment-policy" | /usr/bin/awk '{print $1}')" = "\(policySHA256)" ] || exit 65
        /usr/bin/plutil -lint "$stage/helper.plist" >/dev/null
        /bin/sync

        if [ -e "$current" ] || [ -L "$current" ]; then
          [ ! -L "$current" ] && [ -d "$current" ] || exit 65
          [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$current")" = "0:0:755" ] || exit 65
          had_current=1
        fi
        if [ -e "$previous" ] || [ -L "$previous" ]; then
          [ ! -L "$previous" ] && [ -d "$previous" ] || exit 65
          [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$previous")" = "0:0:755" ] || exit 65
        fi
        if [ -e "$plist" ] || [ -L "$plist" ]; then
          [ ! -L "$plist" ] && [ -f "$plist" ] || exit 65
          [ "$(/usr/bin/stat -f '%u:%g:%Lp:%l' "$plist")" = "0:0:644:1" ] || exit 65
          /bin/cp -p "$plist" "$stage/previous.plist"
          had_plist=1
        fi

        failure_reason=daemon-bootout-failed
        /bin/launchctl disable "$current_target" >/dev/null 2>&1 || true
        /bin/launchctl bootout "$current_target" >/dev/null 2>&1 || true
        /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
        /bin/launchctl disable "$legacy_target" >/dev/null 2>&1 || true
        /bin/launchctl bootout "$legacy_target" >/dev/null 2>&1 || true
        if /bin/launchctl print "$current_target" >/dev/null 2>&1 ||
           /bin/launchctl print "$legacy_target" >/dev/null 2>&1; then
          exit 78
        fi
        booted_out=1

        failure_reason=provision-failed
        provision_output="$(\(provisionCommand))"
        [ "$?" = 0 ] || exit 78
        [ "$provision_output" = \(q(expectedProvision)) ] || exit 78

        failure_reason=recovery-failed
        set +e
        recovery_payload="$(LIDSWITCH_RESULT_FORMAT=administrator-receipt-v1 LIDSWITCH_ADMIN_TRANSACTION=\(q(transaction)) LIDSWITCH_ADMIN_OPERATION=\(q(operation.rawValue)) \(recoveryCommand))"
        recovery_code=$?
        set -e
        [ "${#recovery_payload}" -gt 0 ] && [ "${#recovery_payload}" -lt 1024 ] || exit 78
        case "$recovery_code" in
          0) recovery_safe=1 ;;
          75)
            publish_receipt update "$recovery_payload"
            completed=1
            exit 75
            ;;
          *) exit 78 ;;
        esac

        failure_reason=post-recovery-publication-failed
        \(postRecoveryScript(operation: operation))

        publish_receipt update "$recovery_payload"
        completed=1
        exit 0
        """
    }

    private static func postRecoveryScript(operation: AdministratorOperation) -> String {
        switch operation {
        case .install:
            return """
            /bin/rm -rf "$previous"
            if [ "$had_current" = 1 ]; then
              /bin/mv "$current" "$previous"
              old_current_rotated=1
            fi
            /bin/mv "$stage_current" "$current"
            new_current_published=1
            /bin/mv "$stage/helper.plist" "$plist"
            plist_published=1
            /usr/sbin/chown root:wheel "$plist"
            /bin/chmod 0644 "$plist"
            /bin/sync
            failure_reason=bootstrap-failed
            /bin/launchctl enable system/\(AppPaths.helperLabel)
            /bin/launchctl bootstrap system "$plist"
            /bin/launchctl print system/\(AppPaths.helperLabel) >/dev/null
            /bin/rm -f \(q(AppPaths.legacyV4RootHelperPath)) \(q(AppPaths.legacyRootHelperPath)) \(q(AppPaths.legacyV4RootHelperVersionPath))
            """
        case .uninstall:
            return """
            failure_reason=uninstall-removal-failed
            # The recovery one-shot has already proved native safe idle. Its
            # public status projection is diagnostic, not retained recovery
            # authority, and leaving it behind makes the app correctly report
            # dynamic installation residue. Remove only this public leaf;
            # private ledgers, proof, locks, and administrator receipts remain
            # intact for audit and future fail-closed recovery.
            /bin/rm -f "$status_path" "$plist" \(q(AppPaths.legacyV4RootHelperPath)) \(q(AppPaths.legacyRootHelperPath)) \(q(AppPaths.legacyV4RootHelperVersionPath))
            /bin/rm -rf "$current" "$previous"
            /bin/sync
            """
        case .userRestore:
            return """
            failure_reason=daemon-restart-failed
            if [ "$had_plist" = 1 ]; then
              /bin/launchctl enable system/\(AppPaths.helperLabel) >/dev/null 2>&1 || true
              /bin/launchctl bootstrap system "$plist"
              /bin/launchctl print system/\(AppPaths.helperLabel) >/dev/null
            fi
            """
        }
    }

    private static func commandLine(_ arguments: [String]) -> String {
        arguments.map(q).joined(separator: " ")
    }

    private static func q(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum AdministratorTransactionRunner {
    private static let reconciliationSeconds: TimeInterval = 5

    static func run(
        script: String,
        prompt: String,
        transactionID: UUID,
        operation: AdministratorOperation,
        receiptPath: String
    ) -> AdministratorOperationResult {
        let command = PrivilegedHelperManager.administratorCommand(script)
        let appleScript = PrivilegedHelperManager.administratorAppleScript(
            command: command,
            prompt: prompt
        )
        guard PrivilegedHelperManager.administratorAppleScriptFitsSafeArgumentBudget(appleScript) else {
            return .notStarted(
                operation: operation,
                reason: "administrator-command-exceeds-safe-argument-budget"
            )
        }
        let process = Shell.run(.privilegedAppleScript(appleScript))
        let deadline = MonotonicClock.seconds() + reconciliationSeconds
        var observation = readReceipt(
            path: receiptPath,
            transactionID: transactionID,
            operation: operation
        )
        var retryDelay: useconds_t = 25_000
        while observation.shouldRetry, !process.outcome.provesNoChildStarted,
              MonotonicClock.seconds() < deadline {
            usleep(retryDelay)
            observation = readReceipt(
                path: receiptPath,
                transactionID: transactionID,
                operation: operation
            )
            retryDelay = min(retryDelay * 2, 250_000)
        }

        return classify(
            observation: observation,
            processOutcome: process.outcome,
            processExitCode: process.exitCode,
            transactionID: transactionID,
            operation: operation
        )
    }

    static func classify(
        observation: ReceiptObservation,
        processOutcome: ProcessOutcome,
        processExitCode: Int32,
        transactionID: UUID,
        operation: AdministratorOperation
    ) -> AdministratorOperationResult {
        switch observation {
        case let .terminal(receipt):
            switch receipt.outcome {
            case .safeIdle: return .safeIdle(receipt)
            case .recoveryRequired: return .recoveryRequired(receipt)
            case .operationFailed:
                if receipt.reason == "administrator-operation-already-running" {
                    return .notStarted(operation: operation, reason: receipt.reason)
                }
                return .failed(receipt)
            case .installedButStopped: return .installedButStopped(receipt)
            case .pending:
                return .completionIndeterminate(
                    transactionID: transactionID,
                    operation: operation,
                    reason: "terminal-pending-invalid"
                )
            }
        case .absent where processOutcome.provesNoChildStarted:
            return .notStarted(
                operation: operation,
                reason: processOutcome == .rejected
                    ? "administrator-launch-rejected"
                    : "administrator-launch-failed"
            )
        case .absent where processOutcome == .completed && processExitCode != 0:
            // The generated root wrapper publishes `running` before bootout or
            // authority mutation. A completed authorization failure with no
            // receipt therefore proves this transaction did not start.
            return .notStarted(
                operation: operation,
                reason: "administrator-authorization-not-completed"
            )
        case .running, .absent, .invalid:
            return .completionIndeterminate(
                transactionID: transactionID,
                operation: operation,
                reason: processOutcome == .timedOut
                    ? "administrator-wait-timed-out"
                    : "terminal-receipt-unavailable"
            )
        }
    }

    enum ReceiptObservation {
        case absent
        case running
        case terminal(AdministratorTransactionReceipt)
        case invalid

        var shouldRetry: Bool {
            switch self {
            case .terminal: false
            case .absent, .running, .invalid: true
            }
        }
    }

    static func observation(
        raw: String?,
        transactionID: UUID,
        operation: AdministratorOperation
    ) -> ReceiptObservation {
        guard let raw else { return .absent }
        guard let receipt = AdministratorTransactionReceipt.parse(raw),
              receipt.transactionID == transactionID,
              receipt.operation == operation
        else { return .invalid }
        return receipt.state == .running ? .running : .terminal(receipt)
    }

    private static func readReceipt(
        path: String,
        transactionID: UUID,
        operation: AdministratorOperation
    ) -> ReceiptObservation {
        let policy = BoundedFileReadPolicy(
            maximumBytes: AdministratorTransactionReceipt.maximumBytes,
            expectedOwnerUID: 0,
            requireSingleLink: true,
            rejectGroupOrWorldWritable: true,
            requireNonEmpty: true,
            safeParentDepth: 1,
            ancestorPolicy: .fullAbsolute
        )
        switch BoundedFileReader.readUTF8(path: path, policy: policy) {
        case .failure(.missing):
            return .absent
        case .failure:
            return .invalid
        case let .success(raw):
            guard let receipt = AdministratorTransactionReceipt.parse(raw),
                  receipt.transactionID == transactionID,
                  receipt.operation == operation
            else { return .invalid }
            return receipt.state == .running ? .running : .terminal(receipt)
        }
    }
}
