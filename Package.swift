// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitchboard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CodexSwitchboard", path: "Sources/CodexSwitchboard"),
        .testTarget(name: "CodexSwitchboardTests", dependencies: ["CodexSwitchboard"])
    ]
)
