// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The candidate builder writes the measured private anchor source into the
// LidSwitch target immediately before a release-candidate build.  Ordinary
// builds never receive this define and therefore cannot reference that source.
let isReleaseCandidate = ProcessInfo.processInfo.environment["LIDSWITCH_RELEASE_CANDIDATE"] == "1"
let lidSwitchSwiftSettings: [SwiftSetting] = isReleaseCandidate
    ? [.define("LIDSWITCH_RELEASE_CANDIDATE")]
    : []

let package = Package(
    name: "LidSwitch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LidSwitch", targets: ["LidSwitch"]),
        .executable(name: "LidSwitchHelper", targets: ["LidSwitchHelper"])
    ],
    targets: [
        .target(
            name: "LidSwitchCore",
            path: "Sources/LidSwitchCore"
        ),
        .target(
            name: "LidSwitchXPCBridge",
            path: "Sources/LidSwitchXPCBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fblocks"])
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "LidSwitch",
            dependencies: ["LidSwitchCore", "LidSwitchXPCBridge"],
            path: "Sources/LidSwitch",
            resources: [.copy("../../Resources/LidSwitchReleaseIdentity.json")],
            swiftSettings: lidSwitchSwiftSettings
        ),
        .executableTarget(
            name: "LidSwitchHelper",
            dependencies: ["LidSwitchCore", "LidSwitchXPCBridge"],
            path: "Sources/LidSwitchHelper",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "LidSwitchTests",
            dependencies: ["LidSwitch", "LidSwitchCore", "LidSwitchHelper"],
            path: "Tests/LidSwitchTests"
        )
    ]
)
