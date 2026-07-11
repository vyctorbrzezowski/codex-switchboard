import Darwin
import Foundation

public enum AutoSwapSurfaceKind: String, Codable, CaseIterable, Hashable {
    case desktop
    case cli
}

public struct CodexAuthIdentity: Equatable {
    public let subject: String
    public let accountID: String
    public let email: String

    public init(subject: String, accountID: String, email: String) {
        self.subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func matches(_ other: CodexAuthIdentity) -> Bool {
        if !subject.isEmpty, !other.subject.isEmpty {
            return subject == other.subject
                && !accountID.isEmpty
                && !other.accountID.isEmpty
                && accountID == other.accountID
        }
        if !accountID.isEmpty, !other.accountID.isEmpty {
            return accountID == other.accountID
        }
        if !email.isEmpty, email == other.email {
            return accountIDsCompatible(accountID, other.accountID)
        }
        return false
    }

    private func accountIDsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs.isEmpty || rhs.isEmpty || lhs == rhs
    }
}

public enum CodexCredentialStoreMode {
    public static func resolve(config: String?, surface: AutoSwapSurfaceKind) -> String {
        guard let config else { return "file" }
        let keys = surface == .cli
            ? ["cli_auth_credentials_store", "auth_credentials_store_mode", "auth_credentials_store"]
            : ["auth_credentials_store_mode", "auth_credentials_store"]

        for rawLine in config.split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard keys.contains(key) else { continue }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        return "file"
    }
}

public enum AutoSwapSurfaceTopology {
    public static func consumerKinds(
        for surface: AutoSwapSurfaceKind,
        sharedWith: AutoSwapSurfaceKind?
    ) -> Set<AutoSwapSurfaceKind> {
        var kinds: Set<AutoSwapSurfaceKind> = [surface]
        if let sharedWith {
            kinds.insert(sharedWith)
        }
        return kinds
    }
}

public enum AutoSwapDecisionKind: String, Codable {
    case noAction = "no_action"
    case wouldSwitch = "would_switch"
    case switched
    case blocked
    case error
}

public enum AutoSwapDecisionReason: String, Codable {
    case activeAccountMissing = "active_account_missing"
    case activeQuotaAboveThreshold = "active_quota_above_threshold"
    case consumersRunning = "consumers_running"
    case cooldownActive = "cooldown_active"
    case noCandidate = "no_candidate"
    case surfaceDisabled = "surface_disabled"
    case surfaceNotDetected = "surface_not_detected"
    case switchLimitReached = "switch_limit_reached"
    case switched = "switched"
    case thresholdReached = "threshold_reached"
    case unsupportedAuthStore = "unsupported_auth_store"
}

public struct AutoSwapPolicy: Codable, Equatable {
    public var enabledSurfaces: Set<AutoSwapSurfaceKind>
    public var triggerSessionFreePercent: Double
    public var triggerWeeklyFreePercent: Double
    public var targetMinSessionFreePercent: Double
    public var paidOnly: Bool
    public var requireUsableForCodex: Bool
    public var cooldownSeconds: TimeInterval
    public var maxSwitchesPerHour: Int

    enum CodingKeys: String, CodingKey {
        case enabledSurfaces = "enabled_surfaces"
        case triggerSessionFreePercent = "trigger_session_free_percent"
        case triggerWeeklyFreePercent = "trigger_weekly_free_percent"
        case targetMinSessionFreePercent = "target_min_session_free_percent"
        case paidOnly = "paid_only"
        case requireUsableForCodex = "require_usable_for_codex"
        case cooldownSeconds = "cooldown_seconds"
        case maxSwitchesPerHour = "max_switches_per_hour"
    }

    public init(
        enabledSurfaces: Set<AutoSwapSurfaceKind> = [],
        triggerSessionFreePercent: Double = 5,
        triggerWeeklyFreePercent: Double = 5,
        targetMinSessionFreePercent: Double = 30,
        paidOnly: Bool = true,
        requireUsableForCodex: Bool = true,
        cooldownSeconds: TimeInterval = 300,
        maxSwitchesPerHour: Int = 3
    ) {
        self.enabledSurfaces = enabledSurfaces
        self.triggerSessionFreePercent = triggerSessionFreePercent
        self.triggerWeeklyFreePercent = triggerWeeklyFreePercent
        self.targetMinSessionFreePercent = targetMinSessionFreePercent
        self.paidOnly = paidOnly
        self.requireUsableForCodex = requireUsableForCodex
        self.cooldownSeconds = cooldownSeconds
        self.maxSwitchesPerHour = max(1, maxSwitchesPerHour)
    }

    public func isEnabled(for surface: AutoSwapSurfaceKind) -> Bool {
        enabledSurfaces.contains(surface)
    }

    public mutating func setEnabled(_ isEnabled: Bool, for surface: AutoSwapSurfaceKind) {
        if isEnabled {
            enabledSurfaces.insert(surface)
        } else {
            enabledSurfaces.remove(surface)
        }
    }
}

public struct AutoSwapAccount: Equatable {
    public let profileKey: String
    public let sessionFreePercent: Double
    public let weeklyFreePercent: Double
    public let usableForCodex: Bool
    public let needsRelogin: Bool
    public let isFreePlan: Bool
    public let score: Double

    public init(
        profileKey: String,
        sessionFreePercent: Double,
        weeklyFreePercent: Double,
        usableForCodex: Bool,
        needsRelogin: Bool,
        isFreePlan: Bool,
        score: Double
    ) {
        self.profileKey = profileKey
        self.sessionFreePercent = sessionFreePercent
        self.weeklyFreePercent = weeklyFreePercent
        self.usableForCodex = usableForCodex
        self.needsRelogin = needsRelogin
        self.isFreePlan = isFreePlan
        self.score = score
    }
}

public struct AutoSwapSurface: Equatable {
    public let kind: AutoSwapSurfaceKind
    public let detected: Bool
    public let supportsFileSwitching: Bool
    public let activeProfileKey: String?
    public let authStoreMode: String

    public init(
        kind: AutoSwapSurfaceKind,
        detected: Bool,
        supportsFileSwitching: Bool,
        activeProfileKey: String?,
        authStoreMode: String
    ) {
        self.kind = kind
        self.detected = detected
        self.supportsFileSwitching = supportsFileSwitching
        self.activeProfileKey = activeProfileKey
        self.authStoreMode = authStoreMode
    }
}

public struct AutoSwapDecision: Codable, Equatable {
    public let generatedAt: Date
    public let surface: AutoSwapSurfaceKind
    public let decision: AutoSwapDecisionKind
    public let reason: AutoSwapDecisionReason
    public let activeProfileKey: String?
    public let candidateProfileKey: String?
    public let triggerSessionFreePercent: Double
    public let triggerWeeklyFreePercent: Double
    public let targetMinSessionFreePercent: Double

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case surface
        case decision
        case reason
        case activeProfileKey = "active_profile_key"
        case candidateProfileKey = "candidate_profile_key"
        case triggerSessionFreePercent = "trigger_session_free_percent"
        case triggerWeeklyFreePercent = "trigger_weekly_free_percent"
        case targetMinSessionFreePercent = "target_min_session_free_percent"
    }

    public init(
        generatedAt: Date = Date(),
        surface: AutoSwapSurfaceKind,
        decision: AutoSwapDecisionKind,
        reason: AutoSwapDecisionReason,
        activeProfileKey: String?,
        candidateProfileKey: String?,
        triggerSessionFreePercent: Double,
        triggerWeeklyFreePercent: Double,
        targetMinSessionFreePercent: Double
    ) {
        self.generatedAt = generatedAt
        self.surface = surface
        self.decision = decision
        self.reason = reason
        self.activeProfileKey = activeProfileKey
        self.candidateProfileKey = candidateProfileKey
        self.triggerSessionFreePercent = triggerSessionFreePercent
        self.triggerWeeklyFreePercent = triggerWeeklyFreePercent
        self.targetMinSessionFreePercent = targetMinSessionFreePercent
    }
}

public struct AutoSwapAuditEvent: Codable, Equatable {
    public let generatedAt: Date
    public let surface: AutoSwapSurfaceKind
    public let decision: AutoSwapDecisionKind
    public let reason: AutoSwapDecisionReason
    public let fromProfileKey: String?
    public let toProfileKey: String?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case surface
        case decision
        case reason
        case fromProfileKey = "from_profile_key"
        case toProfileKey = "to_profile_key"
    }

    public init(
        generatedAt: Date = Date(),
        surface: AutoSwapSurfaceKind,
        decision: AutoSwapDecisionKind,
        reason: AutoSwapDecisionReason,
        fromProfileKey: String?,
        toProfileKey: String?
    ) {
        self.generatedAt = generatedAt
        self.surface = surface
        self.decision = decision
        self.reason = reason
        self.fromProfileKey = fromProfileKey
        self.toProfileKey = toProfileKey
    }
}

public enum AutoSwapDecisionEngine {
    public static func evaluate(
        policy: AutoSwapPolicy,
        surface: AutoSwapSurface,
        accounts: [AutoSwapAccount],
        history: [AutoSwapAuditEvent],
        now: Date = Date()
    ) -> AutoSwapDecision {
        func decision(
            _ kind: AutoSwapDecisionKind,
            _ reason: AutoSwapDecisionReason,
            candidate: String? = nil
        ) -> AutoSwapDecision {
            AutoSwapDecision(
                generatedAt: now,
                surface: surface.kind,
                decision: kind,
                reason: reason,
                activeProfileKey: surface.activeProfileKey,
                candidateProfileKey: candidate,
                triggerSessionFreePercent: policy.triggerSessionFreePercent,
                triggerWeeklyFreePercent: policy.triggerWeeklyFreePercent,
                targetMinSessionFreePercent: policy.targetMinSessionFreePercent
            )
        }

        guard policy.isEnabled(for: surface.kind) else {
            return decision(.noAction, .surfaceDisabled)
        }
        guard surface.detected else {
            return decision(.blocked, .surfaceNotDetected)
        }
        guard surface.supportsFileSwitching else {
            return decision(.blocked, .unsupportedAuthStore)
        }
        guard let activeProfileKey = surface.activeProfileKey,
              let active = accounts.first(where: { $0.profileKey == activeProfileKey }) else {
            return decision(.blocked, .activeAccountMissing)
        }

        let reachedSessionThreshold = active.sessionFreePercent <= policy.triggerSessionFreePercent
        let reachedWeeklyThreshold = active.weeklyFreePercent <= policy.triggerWeeklyFreePercent
        guard reachedSessionThreshold || reachedWeeklyThreshold else {
            return decision(.noAction, .activeQuotaAboveThreshold)
        }
        guard !isCoolingDown(policy: policy, surface: surface.kind, history: history, now: now) else {
            return decision(.blocked, .cooldownActive)
        }
        guard !exceededSwitchLimit(policy: policy, surface: surface.kind, history: history, now: now) else {
            return decision(.blocked, .switchLimitReached)
        }
        guard let candidate = bestCandidate(
            for: activeProfileKey,
            accounts: accounts,
            policy: policy
        ) else {
            return decision(.blocked, .noCandidate)
        }

        return decision(.wouldSwitch, .thresholdReached, candidate: candidate.profileKey)
    }

    private static func isCoolingDown(
        policy: AutoSwapPolicy,
        surface: AutoSwapSurfaceKind,
        history: [AutoSwapAuditEvent],
        now: Date
    ) -> Bool {
        guard policy.cooldownSeconds > 0,
              let lastSwitch = history
                .filter({ $0.surface == surface && $0.decision == .switched })
                .max(by: { $0.generatedAt < $1.generatedAt }) else {
            return false
        }
        return now.timeIntervalSince(lastSwitch.generatedAt) < policy.cooldownSeconds
    }

    private static func exceededSwitchLimit(
        policy: AutoSwapPolicy,
        surface: AutoSwapSurfaceKind,
        history: [AutoSwapAuditEvent],
        now: Date
    ) -> Bool {
        let windowStart = now.addingTimeInterval(-3600)
        let recentSwitches = history.filter {
            $0.surface == surface
                && $0.decision == .switched
                && $0.generatedAt >= windowStart
        }
        return recentSwitches.count >= policy.maxSwitchesPerHour
    }

    private static func bestCandidate(
        for activeProfileKey: String,
        accounts: [AutoSwapAccount],
        policy: AutoSwapPolicy
    ) -> AutoSwapAccount? {
        accounts
            .filter { $0.profileKey != activeProfileKey }
            .filter { !policy.paidOnly || !$0.isFreePlan }
            .filter { !policy.requireUsableForCodex || $0.usableForCodex }
            .filter { !$0.needsRelogin }
            .filter { $0.sessionFreePercent >= policy.targetMinSessionFreePercent }
            .filter { $0.weeklyFreePercent > policy.triggerWeeklyFreePercent }
            .sorted(by: compareCandidates)
            .first
    }

    private static func compareCandidates(_ lhs: AutoSwapAccount, _ rhs: AutoSwapAccount) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.sessionFreePercent != rhs.sessionFreePercent {
            return lhs.sessionFreePercent > rhs.sessionFreePercent
        }
        if lhs.weeklyFreePercent != rhs.weeklyFreePercent {
            return lhs.weeklyFreePercent > rhs.weeklyFreePercent
        }
        return lhs.profileKey < rhs.profileKey
    }
}

public final class AutoSwapPolicyStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> AutoSwapPolicy {
        guard let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(AutoSwapPolicy.self, from: data) else {
            return AutoSwapPolicy()
        }
        return policy
    }

    public func save(_ policy: AutoSwapPolicy) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(policy), permissions: 0o600)
    }

    private func write(_ data: Data, permissions: Int) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

public final class AutoSwapAuditStore {
    private struct Payload: Codable {
        var events: [AutoSwapAuditEvent]
    }

    private let url: URL
    private let maxEvents: Int
    private let processLock = NSLock()

    public init(url: URL, maxEvents: Int = 100) {
        self.url = url
        self.maxEvents = max(1, maxEvents)
    }

    public func load() -> [AutoSwapAuditEvent] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder().decode(Payload.self, from: data) else {
            return []
        }
        return payload.events
    }

    public func record(_ event: AutoSwapAuditEvent) throws {
        try withExclusiveLock {
            var events = load()
            events.append(event)
            if events.count > maxEvents {
                events = Array(events.suffix(maxEvents))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try write(encoder.encode(Payload(events: events)), permissions: 0o600)
        }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func write(_ data: Data, permissions: Int) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}
