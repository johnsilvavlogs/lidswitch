import Darwin
import Foundation
import LidSwitchCore

#if DEBUG

enum SecureLeaseReader {
    static let maximumBytes: off_t = 4_096

    static func load(path: String, expectedOwnerUID: uid_t) -> Result<ActivationLease, LeaseValidationFailure> {
        let policy = BoundedFileReadPolicy(
            maximumBytes: Int(maximumBytes), expectedOwnerUID: expectedOwnerUID,
            requireSingleLink: true, rejectGroupOrWorldWritable: true,
            requireNonEmpty: true, safeParentDepth: 2
        )
        let result = BoundedFileReader.readUTF8(path: path, policy: policy)
        guard case let .success(raw) = result else {
            switch result {
            case .failure(.missing), .failure(.invalidUTF8): return .failure(.malformed)
            default: return .failure(.unsafeFile)
            }
        }
        guard let lease = ActivationLease.parse(raw) else { return .failure(.malformed) }
        BenchmarkProbe.record("file_read")
        BenchmarkProbe.record("decoded_bytes", count: raw.utf8.count)
        return .success(lease)
    }
}
#endif
