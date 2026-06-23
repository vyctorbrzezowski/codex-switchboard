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
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token expired"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token invalidated"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Refresh failed - re-login required"))
        XCTAssertFalse(UsageService.isExpiredOrRevokedAuthError("Workspace deactivated"))
    }

    func testRecoverableAuthErrorIsNotARowSwitchAffordance() {
        XCTAssertTrue(UsageService.isRecoverableAuthError("Token expired"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token revoked"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token invalidated"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("HTTP 403"))
    }

    func testFreePlanSessionZeroUsesDedicatedResetState() {
        let account = Account(
            id: "free@example.com|acc-free",
            profileKey: "free@example.com",
            email: "free@example.com",
            workspace: "free",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 86_400,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isFreeWaitingForReset)
        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertEqual(account.freePlanResetSeconds, 86_400)
    }

    func testFreeResetFormatterIncludesReturnContext() {
        let text = ResetFormatter.formatFreeReturn(seconds: 60)

        XCTAssertNotEqual(text, ResetFormatter.timeOnly(seconds: 60))
        XCTAssertTrue(text.contains(" "))
    }

    @MainActor
    func testAccountDisplayAliasIsPresentationOnly() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.alias = "  Lab Member 01  "

        XCTAssertEqual(account.displayAlias, "Lab Member 01")
        XCTAssertEqual(account.displayName, "Lab Member 01")
        XCTAssertEqual(account.email, "person@example.com")
        XCTAssertEqual(account.accountID, "acc")
    }

    @MainActor
    func testAccountSearchMatchesAliasAndEmail() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.alias = "Lab Member 01"

        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "member 01"))
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "person@example"))
        XCTAssertFalse(UsageViewModel.matchesSearch(account, searchText: "unrelated"))
    }

    @MainActor
    func testWaitingForResetSortsPaidBeforeFreeThenSoonestReset() {
        let freeSoon = makeAccount(
            id: "free-soon@example.com|acc",
            email: "free-soon@example.com",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 60
        )
        let plusLater = makeAccount(
            id: "plus-later@example.com|acc",
            email: "plus-later@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 600
        )
        let plusSoon = makeAccount(
            id: "plus-soon@example.com|acc",
            email: "plus-soon@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 120
        )

        let sorted = UsageViewModel.sortedExhaustedAccounts([freeSoon, plusLater, plusSoon])

        XCTAssertEqual(sorted.map(\.email), [
            "plus-soon@example.com",
            "plus-later@example.com",
            "free-soon@example.com"
        ])
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

    private func makeAccount(
        id: String,
        email: String,
        plan: String,
        sessionFree: Double,
        weeklyFree: Double,
        sessionResetSeconds: Double,
        weeklyResetSeconds: Double = 0
    ) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: plan,
            plan: plan,
            sessionFree: sessionFree,
            weeklyFree: weeklyFree,
            sessionResetSeconds: sessionResetSeconds,
            weeklyResetSeconds: weeklyResetSeconds,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )
    }
}
