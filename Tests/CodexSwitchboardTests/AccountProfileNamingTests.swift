import XCTest
@testable import CodexSwitchboard

final class AccountProfileNamingTests: XCTestCase {
    func testSanitizedProfileNameAllowsCodexEmailCharacters() throws {
        let result = try AccountProfileNaming.sanitizedProfileName(" User.Name+codex@example.com ")

        XCTAssertEqual(result, "user.name+codex@example.com")
    }

    func testSanitizedProfileNameRejectsPathLikeValues() {
        XCTAssertThrowsError(try AccountProfileNaming.sanitizedProfileName("../auth"))
        XCTAssertThrowsError(try AccountProfileNaming.sanitizedProfileName(""))
    }

    func testSanitizedKeySegmentBuildsStableWorkspaceSlug() {
        XCTAssertEqual(AccountProfileNaming.sanitizedKeySegment("Team Workspace"), "team-workspace")
        XCTAssertEqual(AccountProfileNaming.sanitizedKeySegment("Acme_PRO"), "acme_pro")
        XCTAssertNil(AccountProfileNaming.sanitizedKeySegment("?"))
        XCTAssertNil(AccountProfileNaming.sanitizedKeySegment("unknown"))
    }
}
