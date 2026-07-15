import Foundation

public enum EnrollmentProfile: String, Sendable {
    case manualExact = "manual-exact"
    case developerIDExact = "developer-id-exact"
}

public struct EnrollmentPolicy: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let protocolVersion = ReleaseIdentity.enrollmentPolicyProtocolVersion
    public static let maximumBytes = 4_096

    public let ownerUID: UInt32
    public let profile: EnrollmentProfile
    public let appIdentifier: String
    public let appCDHash: Data
    public let helperIdentifier: String
    public let helperCDHash: Data
    public let helperSHA256: Data
    public let helperSize: UInt64
    public let qualifiedBuild: String
    public let teamIdentifier: String?

    public init(
        ownerUID: UInt32,
        profile: EnrollmentProfile,
        appIdentifier: String,
        appCDHash: Data,
        helperIdentifier: String,
        helperCDHash: Data,
        helperSHA256: Data,
        helperSize: UInt64,
        qualifiedBuild: String,
        teamIdentifier: String?
    ) {
        self.ownerUID = ownerUID
        self.profile = profile
        self.appIdentifier = appIdentifier
        self.appCDHash = appCDHash
        self.helperIdentifier = helperIdentifier
        self.helperCDHash = helperCDHash
        self.helperSHA256 = helperSHA256
        self.helperSize = helperSize
        self.qualifiedBuild = qualifiedBuild
        self.teamIdentifier = teamIdentifier
    }

    public var storagePayload: String {
        var lines = [
            "schema=\(Self.schemaVersion)",
            "protocol=\(Self.protocolVersion)",
            "owner_uid=\(ownerUID)",
            "profile=\(profile.rawValue)",
            "app_identifier=\(appIdentifier)",
            "app_cdhash=\(appCDHash.hexEncoded)",
            "helper_identifier=\(helperIdentifier)",
            "helper_cdhash=\(helperCDHash.hexEncoded)",
            "helper_sha256=\(helperSHA256.hexEncoded)",
            "helper_size=\(helperSize)",
            "qualified_build=\(qualifiedBuild)",
        ]
        if let teamIdentifier { lines.append("team_identifier=\(teamIdentifier)") }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ raw: String) -> EnrollmentPolicy? {
        guard raw.utf8.count <= maximumBytes, raw.hasSuffix("\n"), !raw.hasSuffix("\n\n"), !raw.contains("\r") else { return nil }
        var values: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0]), value = String(pair[1])
            guard !key.isEmpty, !value.isEmpty, values.updateValue(value, forKey: key) == nil else { return nil }
        }
        let baseKeys: Set<String> = ["schema", "protocol", "owner_uid", "profile", "app_identifier", "app_cdhash", "helper_identifier", "helper_cdhash", "helper_sha256", "helper_size", "qualified_build"]
        let keys = Set(values.keys)
        guard keys == baseKeys || keys == baseKeys.union(["team_identifier"]),
              values["schema"] == String(schemaVersion),
              values["protocol"] == String(protocolVersion),
              let owner = values["owner_uid"].flatMap({ UInt32($0) }),
              let profile = values["profile"].flatMap({ EnrollmentProfile(rawValue: $0) }),
              let appIdentifier = values["app_identifier"], isIdentifier(appIdentifier),
              let appCDHash = values["app_cdhash"].flatMap({ Data(strictHex: $0) }), appCDHash.count == 20,
              let helperIdentifier = values["helper_identifier"], isIdentifier(helperIdentifier),
              let helperCDHash = values["helper_cdhash"].flatMap({ Data(strictHex: $0) }), helperCDHash.count == 20,
              let helperSHA = values["helper_sha256"].flatMap({ Data(strictHex: $0) }), helperSHA.count == 32,
              let helperSize = values["helper_size"].flatMap({ UInt64($0) }), helperSize > 0, helperSize <= 16 * 1_024 * 1_024,
              let build = values["qualified_build"], build.utf8.count <= 64
        else { return nil }
        let team = values["team_identifier"]
        if profile == .manualExact, team != nil { return nil }
        if profile == .developerIDExact, !isTeamIdentifier(team) { return nil }
        return EnrollmentPolicy(ownerUID: owner, profile: profile, appIdentifier: appIdentifier, appCDHash: appCDHash,
                                helperIdentifier: helperIdentifier, helperCDHash: helperCDHash, helperSHA256: helperSHA,
                                helperSize: helperSize, qualifiedBuild: build, teamIdentifier: team)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    private static func isTeamIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    }
}

public extension Data {
    init?(strictHex: String) {
        guard strictHex.count.isMultiple(of: 2), strictHex.count <= 128,
              strictHex.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(strictHex.count / 2)
        var index = strictHex.startIndex
        while index < strictHex.endIndex {
            let next = strictHex.index(index, offsetBy: 2)
            guard let byte = UInt8(strictHex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self = Data(bytes)
    }

    var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }
}
