import XCTest

final class CodexSwitchboardCLITests: XCTestCase {
    func testPackageDeclaresLocalCLIExecutable() throws {
        let package = try String(contentsOf: packageURL(), encoding: .utf8)
        XCTAssertTrue(package.contains(#".library(name: "CodexSwitchboardCore""#))
        XCTAssertTrue(package.contains(#".target(name: "CodexSwitchboardCore""#))
        XCTAssertTrue(package.contains(#".executable(name: "codex-switchboard""#))
        XCTAssertTrue(package.contains(#".executableTarget("#))
        XCTAssertTrue(package.contains(#"name: "CodexSwitchboardCLI""#))
        XCTAssertTrue(package.contains(#"dependencies: ["CodexSwitchboardCore"]"#))
    }

    func testSwitchRequiresExplicitStopConsumersFlag() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"guard stopConsumers else"#))
        XCTAssertTrue(source.contains(#"--stop-consumers"#))
        XCTAssertTrue(source.contains(#"consumers_running"#))
    }

    func testCLIRefusesUnsupportedAuthStoreModes() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"supportsFileSwitching"#))
        XCTAssertTrue(source.contains(#"unsupported_auth_store_mode"#))
        XCTAssertTrue(source.contains("keyring, auto, and ephemeral modes are detected but not mutated"))
    }

    func testCLIOutputDoesNotEncodeTokenFields() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertFalse(source.contains(#"case idToken"#))
        XCTAssertFalse(source.contains(#"case accessToken"#))
        XCTAssertFalse(source.contains(#"case refreshToken"#))
        XCTAssertFalse(source.contains(#""id_token":"#))
        XCTAssertFalse(source.contains(#""access_token":"#))
        XCTAssertFalse(source.contains(#""refresh_token":"#))
    }

    private func cliSourceURL() -> URL {
        repoRoot().appendingPathComponent("Sources/CodexSwitchboardCore/CodexSwitchboardCommand.swift")
    }

    private func packageURL() -> URL {
        repoRoot().appendingPathComponent("Package.swift")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
