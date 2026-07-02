import XCTest
@testable import CodexSwitchboardCore

final class AutoSwapDecisionTests: XCTestCase {
    func testChoosesPaidUsableCandidateWhenActiveAccountHitsTrigger() {
        let policy = AutoSwapPolicy(enabledSurfaces: [.cli])
        let decision = AutoSwapDecisionEngine.evaluate(
            policy: policy,
            surface: surface(kind: .cli, activeProfileKey: "active"),
            accounts: [
                account("active", session: 5, weekly: 80, score: 20),
                account("free", session: 99, weekly: 99, isFree: true, score: 99),
                account("paid-low-session", session: 29, weekly: 90, score: 80),
                account("paid-ready", session: 31, weekly: 90, score: 75)
            ],
            history: []
        )

        XCTAssertEqual(decision.decision, .wouldSwitch)
        XCTAssertEqual(decision.candidateProfileKey, "paid-ready")
        XCTAssertEqual(decision.reason, .thresholdReached)
    }

    func testDoesNothingWhenSurfaceIsDisabled() {
        let decision = AutoSwapDecisionEngine.evaluate(
            policy: AutoSwapPolicy(enabledSurfaces: []),
            surface: surface(kind: .desktop, activeProfileKey: "active"),
            accounts: [account("active", session: 1, weekly: 1)],
            history: []
        )

        XCTAssertEqual(decision.decision, .noAction)
        XCTAssertEqual(decision.reason, .surfaceDisabled)
        XCTAssertNil(decision.candidateProfileKey)
    }

    func testCooldownBlocksRepeatedSwitches() {
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = AutoSwapPolicy(enabledSurfaces: [.desktop], cooldownSeconds: 300)
        let recent = AutoSwapAuditEvent(
            generatedAt: now.addingTimeInterval(-120),
            surface: .desktop,
            decision: .switched,
            reason: .thresholdReached,
            fromProfileKey: "old",
            toProfileKey: "new"
        )

        let decision = AutoSwapDecisionEngine.evaluate(
            policy: policy,
            surface: surface(kind: .desktop, activeProfileKey: "active"),
            accounts: [
                account("active", session: 1, weekly: 80),
                account("candidate", session: 80, weekly: 80)
            ],
            history: [recent],
            now: now
        )

        XCTAssertEqual(decision.decision, .blocked)
        XCTAssertEqual(decision.reason, .cooldownActive)
        XCTAssertNil(decision.candidateProfileKey)
    }

    private func surface(kind: AutoSwapSurfaceKind, activeProfileKey: String?) -> AutoSwapSurface {
        AutoSwapSurface(
            kind: kind,
            detected: true,
            supportsFileSwitching: true,
            activeProfileKey: activeProfileKey,
            authStoreMode: "file"
        )
    }

    private func account(
        _ profileKey: String,
        session: Double,
        weekly: Double,
        isFree: Bool = false,
        score: Double = 50
    ) -> AutoSwapAccount {
        AutoSwapAccount(
            profileKey: profileKey,
            sessionFreePercent: session,
            weeklyFreePercent: weekly,
            usableForCodex: true,
            needsRelogin: false,
            isFreePlan: isFree,
            score: score
        )
    }
}
