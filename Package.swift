// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitchboard",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexSwitchboardCore", targets: ["CodexSwitchboardCore"]),
        .executable(name: "CodexSwitchboard", targets: ["CodexSwitchboard"]),
        .executable(name: "codex-switchboard", targets: ["CodexSwitchboardCLI"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexSwitchboard",
            dependencies: ["CodexSwitchboardCore"],
            path: "Sources/CodexSwitchboard"
        ),
        .target(name: "CodexSwitchboardCore", path: "Sources/CodexSwitchboardCore"),
        .executableTarget(
            name: "CodexSwitchboardCLI",
            dependencies: ["CodexSwitchboardCore"],
            path: "Sources/CodexSwitchboardCLI"
        ),
        .testTarget(name: "CodexSwitchboardTests", dependencies: ["CodexSwitchboard", "CodexSwitchboardCore"])
    ]
)
