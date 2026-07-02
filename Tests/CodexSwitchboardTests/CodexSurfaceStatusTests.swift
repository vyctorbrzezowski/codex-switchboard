import XCTest
@testable import CodexSwitchboard

final class CodexSurfaceStatusTests: XCTestCase {
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
}
