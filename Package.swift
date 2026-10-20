// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniVNC",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "VNCCore"),
        .executableTarget(name: "MiniVNC", dependencies: ["VNCCore"]),
        .testTarget(name: "VNCCoreTests", dependencies: ["VNCCore"]),
    ]
)
