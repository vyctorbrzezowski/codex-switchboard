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

    func testUnifiedChatGPTUsesBundleValidatedProcessClassification() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"isCodexDesktopProcessCommand($0.lowercased())"#))
        XCTAssertTrue(source.contains(#"if isCodexDesktopProcessCommand(lowercasedCommand)"#))
        XCTAssertTrue(source.contains(#"/Applications/ChatGPT.app"#))
        XCTAssertTrue(source.contains(#"info["CFBundleIdentifier"] as? String == "com.openai.codex""#))
        XCTAssertFalse(source.contains(#"line.contains("/applications/chatgpt.app/contents/")"#))
    }

    func testCLIRefusesUnsupportedAuthStoreModes() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"supportsFileSwitching"#))
        XCTAssertTrue(source.contains(#"unsupported_auth_store_mode"#))
        XCTAssertTrue(source.contains("keyring, auto, and ephemeral modes are detected but not mutated"))
        XCTAssertTrue(source.contains(#"cli_auth_credentials_store"#))
    }

    func testCLIDeclaresAutoSwapCommands() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"autoswap status --json"#))
        XCTAssertTrue(source.contains(#"autoswap enable --surface cli|desktop|both --json"#))
        XCTAssertTrue(source.contains(#"autoswap run-once --surface cli|desktop|both --json"#))
        XCTAssertTrue(source.contains(#"--dry-run"#))
        XCTAssertTrue(source.contains(#"max_switches_per_hour"#))
        XCTAssertFalse(source.contains(#"allowStopConsumers"#))
        XCTAssertFalse(source.contains(#"let switches: [SwitchPayload]"#))
        XCTAssertFalse(source.contains(#"uniqueSurfaces"#))
        XCTAssertTrue(source.contains(#"AutoSwapSwitchPayload"#))
    }

    func testAppAutoSwapBlocksRunningSurfaces() throws {
        let source = try String(contentsOf: usageViewModelSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"status.running"#))
        XCTAssertTrue(source.contains(#"reason: .consumersRunning"#))
    }

    func testAppAutoSwapRanksOnlyCapturedUsableAccounts() throws {
        let viewModel = try String(contentsOf: usageViewModelSourceURL(), encoding: .utf8)
        let adapter = try String(contentsOf: autoSwapAppAdapterSourceURL(), encoding: .utf8)
        XCTAssertTrue(viewModel.contains(#"autoSwapAccount(needsRelogin: needsRelogin($0))"#))
        XCTAssertTrue(adapter.contains(#"usableForCodex: isUsableForCodex && !needsRelogin"#))
        XCTAssertTrue(adapter.contains(#"needsRelogin: needsRelogin"#))
    }

    func testCLIUsesStableAuthIdentityForActiveProfileMatching() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"matchesStableIdentity"#))
        XCTAssertTrue(source.contains(#"subject:"#))
        XCTAssertTrue(source.contains(#"accountIDsCompatible"#))
    }

    func testCLIConsumerChecksAreSurfaceScoped() throws {
        let source = try String(contentsOf: cliSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#"consumerProcesses(for surfaces"#))
        XCTAssertTrue(source.contains(#"consumerTargetKinds"#))
        XCTAssertTrue(source.contains(#"surface.sharedAuthStore"#))
        XCTAssertTrue(source.contains(#"isCodexConsumerCommand(command.lowercased(), for: targetKinds)"#))
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

    private func usageViewModelSourceURL() -> URL {
        repoRoot().appendingPathComponent("Sources/CodexSwitchboard/UsageViewModel.swift")
    }

    private func autoSwapAppAdapterSourceURL() -> URL {
        repoRoot().appendingPathComponent("Sources/CodexSwitchboard/AutoSwapAppAdapters.swift")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
