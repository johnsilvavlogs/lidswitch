// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LidSwitch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LidSwitch", targets: ["LidSwitch"])
    ],
    targets: [
        .executableTarget(
            name: "LidSwitch",
            path: "Sources/LidSwitch"
        ),
        .testTarget(
            name: "LidSwitchTests",
            dependencies: ["LidSwitch"],
            path: "Tests/LidSwitchTests"
        )
    ]
)
