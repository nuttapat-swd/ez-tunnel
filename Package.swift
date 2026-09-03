// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EZTunnel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EZTunnelCore", targets: ["EZTunnelCore"]),
        .executable(name: "EZTunnel", targets: ["EZTunnel"]),
    ],
    targets: [
        .target(name: "EZTunnelCore"),
        .executableTarget(name: "EZTunnel", dependencies: ["EZTunnelCore"]),
        .testTarget(name: "EZTunnelCoreTests", dependencies: ["EZTunnelCore"]),
    ]
)
