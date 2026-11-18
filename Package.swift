// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FullscreenMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MenuBarProbe"),
        .testTarget(name: "MenuBarProbeTests", dependencies: ["MenuBarProbe"]),
    ]
)
