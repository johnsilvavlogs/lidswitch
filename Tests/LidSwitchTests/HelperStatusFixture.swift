import Foundation
@testable import LidSwitchCore
@testable import LidSwitchHelper

/// Test-only bridge for legacy tests that used to write the public status
/// bytes directly. It always constructs a strict projection task and invokes
/// the production task writer; it creates no helper authority, lease, or
/// session state.
enum HelperStatusFixture {
    static func write(state: String, reason: String, sessionID: UUID?, path: String) -> Bool {
        let now = UInt64(max(1, MonotonicClock.seconds() * 1_000_000_000))
        guard let task = StatusProjectionTask(generation: 1, state: state, reason: reason,
                                              sessionID: sessionID, deadlineNanoseconds: now &+ 60_000_000_000)
        else { return false }
        let url = URL(fileURLWithPath: path)
        if let descriptor = try? TestSandbox.openManagedDirectory(at: url.deletingLastPathComponent()) {
            defer { Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(), metadata.st_gid == getgid()
            else { return false }
            let mode = mode_t(metadata.st_mode & 0o7777)
            guard mode == 0o700 || mode == 0o755 else { return false }
            return HelperStatusStore.write(
                task: task,
                heldDirectoryDescriptor: descriptor,
                expectations: .init(ownerUID: metadata.st_uid, groupID: metadata.st_gid, mode: mode)
            )
        }
        return HelperStatusStore.write(task: task, path: path)
    }
}
