import Darwin
import Foundation
import LidSwitchCore

/// Test-only deterministic read controls. Production passes `nil`, so open,
/// stat, ownership, link, and metadata checks always use the real syscall
/// path; controls can influence only descriptor reads and the final metadata
/// race boundary.
struct BoundedHelperComparatorControls: @unchecked Sendable {
    enum Operand: Equatable, Sendable { case installed, bundled }
    enum ReadPhase: Equatable, Sendable { case body, endOfFile }
    enum ReadDirective: Sendable { case system, interrupted, endOfFile }

    let readDirective: @Sendable (Operand, ReadPhase) -> ReadDirective
    let beforeFinalMetadata: @Sendable () -> Void

    init(
        readDirective: @escaping @Sendable (Operand, ReadPhase) -> ReadDirective = { _, _ in .system },
        beforeFinalMetadata: @escaping @Sendable () -> Void = {}
    ) {
        self.readDirective = readDirective
        self.beforeFinalMetadata = beforeFinalMetadata
    }
}

/// Compares the installed helper without following links or allocating either
/// binary wholesale. The final metadata pass rejects replacement/truncation
/// races, so a match always describes the two descriptors that were validated.
enum BoundedHelperComparator {
    private static let chunkSize = 64 * 1_024

    static func matches(
        installed: String,
        bundled: String,
        maximumBytes: Int,
        expectedInstalledOwner: uid_t = 0,
        controls: BoundedHelperComparatorControls? = nil
    ) -> Bool {
        guard maximumBytes > 0,
              let left = openRegular(installed, allowedOwners: [expectedInstalledOwner], maximumBytes: maximumBytes)
        else { return false }
        defer { close(left.descriptor) }
        // A distributed app may live in a root-owned /Applications directory
        // or in the launching user's Applications directory.
        guard let right = openRegular(bundled, allowedOwners: [getuid(), 0], maximumBytes: maximumBytes) else { return false }
        defer { close(right.descriptor) }
        guard left.initial.st_size == right.initial.st_size else { return false }

        var leftBuffer = [UInt8](repeating: 0, count: chunkSize)
        var rightBuffer = [UInt8](repeating: 0, count: chunkSize)
        var remaining = Int(left.initial.st_size)
        while remaining > 0 {
            let wanted = min(remaining, chunkSize)
            guard readExactly(left.descriptor, into: &leftBuffer, count: wanted, operand: .installed, controls: controls),
                  readExactly(right.descriptor, into: &rightBuffer, count: wanted, operand: .bundled, controls: controls),
                  leftBuffer.prefix(wanted).elementsEqual(rightBuffer.prefix(wanted))
            else { return false }
            remaining -= wanted
        }
        controls?.beforeFinalMetadata()
        guard readEOF(left.descriptor, operand: .installed, controls: controls),
              readEOF(right.descriptor, operand: .bundled, controls: controls),
              unchanged(left.initial, current: left.descriptor),
              unchanged(right.initial, current: right.descriptor),
              pathStillNames(installed, metadata: left.initial),
              pathStillNames(bundled, metadata: right.initial)
        else { return false }
        BenchmarkProbe.record("file_read", count: 2)
        BenchmarkProbe.record("helper_byte_comparison")
        return true
    }

    /// Compatibility seam for existing callers while tests migrate to the
    /// narrower controls object. It still cannot inject any metadata syscall.
    static func matches(
        installed: String,
        bundled: String,
        maximumBytes: Int,
        expectedInstalledOwner: uid_t = 0,
        beforeFinalMetadata: @escaping @Sendable () -> Void
    ) -> Bool {
        matches(
            installed: installed,
            bundled: bundled,
            maximumBytes: maximumBytes,
            expectedInstalledOwner: expectedInstalledOwner,
            controls: BoundedHelperComparatorControls(beforeFinalMetadata: beforeFinalMetadata)
        )
    }

    private static func openRegular(_ path: String, allowedOwners: [uid_t], maximumBytes: Int) -> (descriptor: Int32, initial: stat)? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              regularMetadataIsSafe(
                mode: metadata.st_mode,
                ownerUID: metadata.st_uid,
                linkCount: metadata.st_nlink,
                size: metadata.st_size,
                allowedOwners: allowedOwners,
                maximumBytes: maximumBytes
              )
        else { close(descriptor); return nil }
        return (descriptor, metadata)
    }

    static func regularMetadataIsSafe(
        mode: mode_t,
        ownerUID: uid_t,
        linkCount: nlink_t,
        size: off_t,
        allowedOwners: [uid_t],
        maximumBytes: Int
    ) -> Bool {
        (mode & S_IFMT) == S_IFREG
            && allowedOwners.contains(ownerUID)
            && linkCount == 1
            && mode & (S_IWGRP | S_IWOTH) == 0
            && size > 0
            && size <= off_t(maximumBytes)
    }

    private static func readExactly(
        _ descriptor: Int32,
        into buffer: inout [UInt8],
        count: Int,
        operand: BoundedHelperComparatorControls.Operand,
        controls: BoundedHelperComparatorControls?
    ) -> Bool {
        var offset = 0
        while offset < count {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                controlledRead(
                    descriptor,
                    destination: raw.baseAddress!.advanced(by: offset),
                    count: count - offset,
                    operand: operand,
                    phase: .body,
                    controls: controls
                )
            }
            if readCount > 0 { offset += readCount; continue }
            if readCount < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    private static func readEOF(
        _ descriptor: Int32,
        operand: BoundedHelperComparatorControls.Operand,
        controls: BoundedHelperComparatorControls?
    ) -> Bool {
        var trailing: UInt8 = 0
        while true {
            let count = controlledRead(
                descriptor,
                destination: &trailing,
                count: 1,
                operand: operand,
                phase: .endOfFile,
                controls: controls
            )
            if count == 0 { return true }
            if count < 0, errno == EINTR { continue }
            return false
        }
    }

    private static func controlledRead(
        _ descriptor: Int32,
        destination: UnsafeMutableRawPointer,
        count: Int,
        operand: BoundedHelperComparatorControls.Operand,
        phase: BoundedHelperComparatorControls.ReadPhase,
        controls: BoundedHelperComparatorControls?
    ) -> Int {
        switch controls?.readDirective(operand, phase) ?? .system {
        case .system:
            return Darwin.read(descriptor, destination, count)
        case .interrupted:
            errno = EINTR
            return -1
        case .endOfFile:
            return 0
        }
    }

    private static func pathStillNames(_ path: String, metadata: stat) -> Bool {
        var current = stat()
        return lstat(path, &current) == 0
            && (current.st_mode & S_IFMT) == S_IFREG
            && current.st_dev == metadata.st_dev
            && current.st_ino == metadata.st_ino
            && current.st_size == metadata.st_size
            && current.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec
            && current.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec
    }

    private static func unchanged(_ initial: stat, current descriptor: Int32) -> Bool {
        var final = stat()
        return fstat(descriptor, &final) == 0
            && initial.st_dev == final.st_dev && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size && initial.st_mode == final.st_mode
            && initial.st_uid == final.st_uid && initial.st_nlink == final.st_nlink
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }
}
