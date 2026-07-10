// swift-tools-version: 6.0
import PackageDescription

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
        .executableTarget(
            name: "LidSwitch",
            dependencies: ["LidSwitchCore"],
            path: "Sources/LidSwitch"
        ),
        .executableTarget(
            name: "LidSwitchHelper",
            dependencies: ["LidSwitchCore"],
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
