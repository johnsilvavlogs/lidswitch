/// Power sources the authenticated owner selected for one helper generation.
/// A generation must select at least one source; its policy cannot change on renewal.
public struct SessionPowerPolicy: RawRepresentable, Equatable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard (1...3).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init?(pluggedIn: Bool, onBattery: Bool) {
        self.init(rawValue: (pluggedIn ? 1 : 0) | (onBattery ? 2 : 0))
    }

    public var pluggedIn: Bool { rawValue & 1 != 0 }
    public var onBattery: Bool { rawValue & 2 != 0 }

    public static let pluggedInOnly = SessionPowerPolicy(rawValue: 1)!
    public static let batteryOnly = SessionPowerPolicy(rawValue: 2)!
    public static let all = SessionPowerPolicy(rawValue: 3)!
}
