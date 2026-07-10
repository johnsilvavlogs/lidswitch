import Darwin
import Foundation

enum HelperStatusStore {
    static func write(
        state: String,
        reason: String,
        sessionID: UUID?,
        path: String,
        evidence: [String: String] = [:]
    ) {
        let boundedEvidence = evidence
            .filter {
                $0.key.range(of: "^[a-z_]{1,48}$", options: .regularExpression) != nil
                    && !["state", "reason", "session", "updated"].contains($0.key)
            }
            .sorted { $0.key < $1.key }
            .prefix(8)
            .map { "\($0.key)=\($0.value.prefix(96))" }
        let payload = ([
            "state=\(state)",
            "reason=\(reason)",
            "session=\(sessionID?.uuidString.lowercased() ?? "none")",
            "updated=\(Int(Date().timeIntervalSince1970))",
        ] + boundedEvidence + [
            "",
        ]).joined(separator: "\n")
        let temp = path + ".tmp.\(UUID().uuidString)"
        let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(payload.utf8)
        let wroteAll = bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return buffer.isEmpty }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                if result > 0 {
                    written += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
        if wroteAll, fsync(descriptor) == 0, rename(temp, path) == 0 {
            return
        }
        unlink(temp)
    }
}
