import XCTest
@testable import CodexSwitchboard

final class CodexSurfaceStatusTests: XCTestCase {
    func testDesktopAppLocatorSkipsOldNativeChatGPTApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chatGPT = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let codex = root.appendingPathComponent("Codex.app", isDirectory: true)
        try writeAppBundle(at: chatGPT, bundleIdentifier: "com.openai.chat")
        try writeAppBundle(at: codex, bundleIdentifier: "com.openai.codex")

        let installed = CodexDesktopApp.installedURL(candidateURLs: [chatGPT, codex])

        XCTAssertEqual(installed, codex)
    }

    func testDesktopAppLocatorPrefersUnifiedChatGPTApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chatGPT = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let codex = root.appendingPathComponent("Codex.app", isDirectory: true)
        try writeAppBundle(at: chatGPT, bundleIdentifier: "com.openai.codex")
        try writeAppBundle(at: codex, bundleIdentifier: "com.openai.codex")

        let installed = CodexDesktopApp.installedURL(candidateURLs: [chatGPT, codex])

        XCTAssertEqual(installed, chatGPT)
    }

    func testSharedCodexHomeAnnotatesBothSurfaces() {
        let desktop = CodexSurfaceStatus(
            kind: .desktop,
            detected: true,
            running: true,
            codexHomePath: "/Users/test/.codex",
            authStoreMode: "file",
            activeProfileKey: "openai-codex:team:user@example.com",
            activeEmail: "user@example.com",
            activeAccountID: "account-1",
            sharedWith: nil
        )
        let cli = CodexSurfaceStatus(
            kind: .cli,
            detected: true,
            running: false,
            codexHomePath: "/Users/test/.codex",
            authStoreMode: "file",
            activeProfileKey: "openai-codex:team:user@example.com",
            activeEmail: "user@example.com",
            activeAccountID: "account-1",
            sharedWith: nil
        )

        let statuses = CodexSurfaceService.annotatingSharedStores([desktop, cli])

        XCTAssertEqual(statuses.first { $0.kind == .desktop }?.sharedWith, .cli)
        XCTAssertEqual(statuses.first { $0.kind == .cli }?.sharedWith, .desktop)
    }

    func testSharedCLISurfaceTreatsRunningDesktopAsConsumer() {
        let desktop = surface(kind: .desktop, running: true, sharedWith: .cli)
        let cli = surface(kind: .cli, running: false, sharedWith: .desktop)

        XCTAssertTrue(cli.hasRunningConsumer(in: [desktop, cli]))
        XCTAssertTrue(desktop.hasRunningConsumer(in: [desktop, cli]))
    }

    func testIsolatedCLISurfaceDoesNotInheritDesktopConsumer() {
        let desktop = surface(kind: .desktop, running: true, sharedWith: nil)
        let cli = surface(kind: .cli, running: false, sharedWith: nil)

        XCTAssertFalse(cli.hasRunningConsumer(in: [desktop, cli]))
    }

    private func surface(
        kind: CodexSurfaceKind,
        running: Bool,
        sharedWith: CodexSurfaceKind?
    ) -> CodexSurfaceStatus {
        CodexSurfaceStatus(
            kind: kind,
            detected: true,
            running: running,
            codexHomePath: sharedWith == nil ? "/tmp/\(kind.rawValue)" : "/tmp/shared",
            authStoreMode: "file",
            activeProfileKey: "active",
            activeEmail: "user@example.com",
            activeAccountID: "workspace",
            sharedWith: sharedWith
        )
    }

    private func writeAppBundle(at url: URL, bundleIdentifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
