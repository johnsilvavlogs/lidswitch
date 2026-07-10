import Darwin
import Foundation

struct HelperConfiguration: Equatable {
    let leasePath: String
    let expectedOwnerUID: uid_t
    let qualifiedBuild: String
    let supportDirectory: String
    let appliedStatePath: String
    let statusPath: String

    static func parse(arguments: [String]) -> HelperConfiguration? {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                return nil
            }
            let key = arguments[index]
            guard values[key] == nil else {
                return nil
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard let leasePath = values["--lease-path"],
              let ownerRaw = values["--owner-uid"],
              let ownerUID = uid_t(ownerRaw),
              let qualifiedBuild = values["--qualified-build"],
              let supportDirectory = values["--support-directory"],
              let appliedStatePath = values["--applied-state"],
              let statusPath = values["--status-path"]
        else {
            return nil
        }

        return HelperConfiguration(
            leasePath: leasePath,
            expectedOwnerUID: ownerUID,
            qualifiedBuild: qualifiedBuild,
            supportDirectory: supportDirectory,
            appliedStatePath: appliedStatePath,
            statusPath: statusPath
        )
    }
}
