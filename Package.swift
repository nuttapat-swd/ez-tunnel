// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EZTunnel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EZTunnelCore", targets: ["EZTunnelCore"]),
        .library(name: "EZTunnelAppSupport", targets: ["EZTunnelAppSupport"]),
        .executable(name: "EZTunnel", targets: ["EZTunnel"]),
    ],
    targets: [
        .target(name: "EZTunnelCore"),
        .target(name: "EZTunnelAppSupport", dependencies: ["EZTunnelCore"]),
        .executableTarget(
            name: "EZTunnel",
            dependencies: ["EZTunnelCore", "EZTunnelAppSupport"]
        ),
        .executableTarget(
            name: "EZTunnelAskPass",
            dependencies: ["EZTunnelCore", "EZTunnelAppSupport"]
        ),
        .testTarget(
            name: "EZTunnelCoreTests",
            dependencies: ["EZTunnelCore", "EZTunnelAppSupport"]
        ),
    ]
)
