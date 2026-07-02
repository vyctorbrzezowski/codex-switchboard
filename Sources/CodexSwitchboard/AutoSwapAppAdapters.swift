import CodexSwitchboardCore
import Foundation

enum AutoSwapAppStores {
    static var policyStore: AutoSwapPolicyStore {
        AutoSwapPolicyStore(url: AppStorage.rootURL.appendingPathComponent("auto-swap-policy.json"))
    }

    static var auditStore: AutoSwapAuditStore {
        AutoSwapAuditStore(url: AppStorage.rootURL.appendingPathComponent("auto-swap-events.json"))
    }
}

extension CodexSurfaceKind {
    var autoSwapKind: AutoSwapSurfaceKind {
        switch self {
        case .desktop: return .desktop
        case .cli: return .cli
        }
    }
}

extension CodexSurfaceStatus {
    var autoSwapSurface: AutoSwapSurface {
        AutoSwapSurface(
            kind: kind.autoSwapKind,
            detected: detected,
            supportsFileSwitching: authStoreMode == "file",
            activeProfileKey: activeProfileKey,
            authStoreMode: authStoreMode
        )
    }
}

extension Account {
    func autoSwapAccount(needsRelogin: Bool) -> AutoSwapAccount? {
        guard let profileKey else { return nil }
        return AutoSwapAccount(
            profileKey: profileKey,
            sessionFreePercent: sessionFree,
            weeklyFreePercent: weeklyFree,
            usableForCodex: isUsableForCodex && !needsRelogin,
            needsRelogin: needsRelogin,
            isFreePlan: isFreePlan,
            score: min(sessionFree, weeklyFree)
        )
    }
}
