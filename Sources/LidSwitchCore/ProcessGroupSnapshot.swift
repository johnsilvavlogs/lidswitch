import Darwin

/// Stable process-group enumeration shared by both bounded process runners.
/// `proc_listpgrppids` returns a PID *count*, while its buffer-size argument is
/// measured in bytes. Keeping that conversion in one place prevents a fast
/// child from being stranded as a zombie because count and byte units were
/// compared directly.
package enum ProcessGroupSnapshot {
    private static let maximumPIDCapacity: Int32 = 262_144

    package enum Read: Equatable, Sendable {
        case capacity(Int32)
        case members([pid_t], count: Int32)
        case failure
    }

    /// Tests use scripted closures; the system value is the sole Darwin
    /// binding and is safe to share. Scripted adapters stay single-threaded.
    package struct Adapter: @unchecked Sendable {
        package let probe: (pid_t) -> Read
        package let read: (pid_t, Int32) -> Read

        package init(
            probe: @escaping (pid_t) -> Read,
            read: @escaping (pid_t, Int32) -> Read
        ) {
            self.probe = probe
            self.read = read
        }

        package static let system = Adapter(
            probe: { group in
                errno = 0
                let count = proc_listpgrppids(group, nil, 0)
                return count < 0 || (count == 0 && errno != 0) ? .failure : .capacity(count)
            },
            read: { group, capacity in
                let slotBytes = Int32(MemoryLayout<pid_t>.size)
                guard capacity > 0, capacity <= Int32.max / slotBytes else { return .failure }
                var members = [pid_t](repeating: 0, count: Int(capacity))
                errno = 0
                let count = members.withUnsafeMutableBufferPointer {
                    proc_listpgrppids(group, $0.baseAddress, capacity * slotBytes)
                }
                return count < 0 || (count == 0 && errno != 0)
                    ? .failure
                    : .members(members, count: count)
            }
        )
    }

    package static func stableMembers(
        _ group: pid_t,
        adapter: Adapter = .system
    ) -> [pid_t]? {
        for _ in 0..<3 {
            guard case let .capacity(hint) = adapter.probe(group),
                  hint >= 0, hint < maximumPIDCapacity
            else { return nil }
            let capacity = max(1, hint + 1)

            func exact(_ read: Read) -> [pid_t]? {
                guard case let .members(storage, count) = read,
                      count >= 0, count < capacity, count <= Int32(storage.count)
                else { return nil }
                let listed = Array(storage.prefix(Int(count)))
                guard listed.allSatisfy({ $0 > 0 }), Set(listed).count == listed.count else {
                    return nil
                }
                return listed.sorted()
            }

            guard let first = exact(adapter.read(group, capacity)),
                  let second = exact(adapter.read(group, capacity))
            else { continue }
            if first == second { return first }
        }
        return nil
    }
}
