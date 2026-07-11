import Foundation
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

    func testPolicyEncodesHourlySwitchLimitUsingPublicJSONKey() throws {
        let data = try JSONEncoder().encode(AutoSwapPolicy(maxSwitchesPerHour: 7))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["max_switches_per_hour"] as? Int, 7)
    }

    func testStableIdentityRequiresWorkspaceForMatchingSubjects() {
        let missingWorkspace = CodexAuthIdentity(
            subject: "user-1",
            accountID: "",
            email: "user@example.com"
        )
        let sameMissingWorkspace = CodexAuthIdentity(
            subject: "user-1",
            accountID: "",
            email: "user@example.com"
        )
        let workspaceA = CodexAuthIdentity(
            subject: "user-1",
            accountID: "workspace-a",
            email: "user@example.com"
        )
        let workspaceB = CodexAuthIdentity(
            subject: "user-1",
            accountID: "workspace-b",
            email: "user@example.com"
        )

        XCTAssertFalse(missingWorkspace.matches(sameMissingWorkspace))
        XCTAssertFalse(workspaceA.matches(workspaceB))
        XCTAssertTrue(workspaceA.matches(workspaceA))
    }

    func testDesktopIgnoresCLIOnlyCredentialStoreSetting() {
        let config = """
        cli_auth_credentials_store = "keyring"
        """

        XCTAssertEqual(CodexCredentialStoreMode.resolve(config: config, surface: .desktop), "file")
        XCTAssertEqual(CodexCredentialStoreMode.resolve(config: config, surface: .cli), "keyring")
    }

    func testSharedAuthStoreExpandsConsumerKinds() {
        XCTAssertEqual(
            AutoSwapSurfaceTopology.consumerKinds(for: .cli, sharedWith: .desktop),
            [.cli, .desktop]
        )
        XCTAssertEqual(
            AutoSwapSurfaceTopology.consumerKinds(for: .cli, sharedWith: nil),
            [.cli]
        )
    }

    func testAuditStorePreservesConcurrentRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutoSwapAuditStore(url: root.appendingPathComponent("events.json"), maxEvents: 50)
        let errorLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                try store.record(AutoSwapAuditEvent(
                    surface: .cli,
                    decision: .switched,
                    reason: .thresholdReached,
                    fromProfileKey: "from",
                    toProfileKey: "to-\(index)"
                ))
            } catch {
                errorLock.lock()
                errors.append(error)
                errorLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(Set(store.load().compactMap(\.toProfileKey)), Set((0..<20).map { "to-\($0)" }))
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
