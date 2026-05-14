import XCTest
@testable import CodexSwitchboard

final class AccountListVisibilityTests: XCTestCase {
    @MainActor
    func testErroredAccountsStayVisible() {
        let healthy = makeAccount(id: "ok@example.com|acc-ok", email: "ok@example.com", hasError: false)
        let errored = makeAccount(id: "bad@example.com|acc-bad", email: "bad@example.com", hasError: true)

        let visible = UsageViewModel.visibleAccounts(from: [healthy, errored])

        XCTAssertEqual(visible.map(\.id), [healthy.id, errored.id])
        XCTAssertEqual(UsageViewModel.errorCount(in: visible), 1)
    }

    func testDedupIDFallsBackToProfileKeyWhenAccountIDIsMissing() {
        let first = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:team:same@example.com"
        )
        let second = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:plus:same@example.com"
        )

        XCTAssertNotEqual(first, second)
    }

    func testExpiredOrRevokedAuthError() {
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Expired or revoked"))
        XCTAssertFalse(UsageService.isExpiredOrRevokedAuthError("Workspace deactivated"))
    }

    private func makeAccount(id: String, email: String, hasError: Bool) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: hasError ? "?" : "team",
            plan: hasError ? "?" : "team",
            sessionFree: hasError ? 0 : 80,
            weeklyFree: hasError ? 0 : 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: hasError,
            errorMessage: hasError ? "Codex usage unavailable" : nil
        )
    }
}
