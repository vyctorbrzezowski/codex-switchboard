import Darwin
import Foundation

public enum CodexSwitchboardCommand {
    public static func run(arguments: [String]) -> Int32 {
        do {
            let runner = CommandRunner(arguments: arguments)
            let result = try runner.run()
            Output.write(result.payload, json: result.json)
            return result.exitCode
        } catch let error as CLIError {
            Output.writeError(error, json: error.jsonPreferred)
            return error.exitCode
        } catch {
            Output.writeError(.failure(message: error.localizedDescription, jsonPreferred: true), json: true)
            return 1
        }
    }
}

private struct CommandResult {
    let payload: EncodablePayload
    let json: Bool
    let exitCode: Int32
}

private final class CommandRunner {
    private let arguments: [String]
    private let paths: SwitchboardPaths
    private let surfaceService: CLISurfaceService
    private let accountStore: CLIAccountStore
    private let switchService: CLISwitchService
    private let autoSwapPolicyStore: AutoSwapPolicyStore
    private let autoSwapAuditStore: AutoSwapAuditStore

    init(arguments: [String]) {
        self.arguments = arguments
        paths = SwitchboardPaths()
        surfaceService = CLISurfaceService(paths: paths)
        accountStore = CLIAccountStore(paths: paths)
        switchService = CLISwitchService(paths: paths, surfaceService: surfaceService)
        autoSwapPolicyStore = AutoSwapPolicyStore(url: paths.autoSwapPolicyURL)
        autoSwapAuditStore = AutoSwapAuditStore(url: paths.autoSwapAuditURL)
    }

    func run() throws -> CommandResult {
        guard let command = arguments.first else {
            throw CLIError.usage("Missing command. Use status, switch, or doctor.", jsonPreferred: false)
        }

        switch command {
        case "status":
            return try status(Array(arguments.dropFirst()))
        case "switch":
            return try switchProfile(Array(arguments.dropFirst()))
        case "doctor":
            return try doctor(Array(arguments.dropFirst()))
        case "autoswap":
            return try autoswap(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            return CommandResult(payload: .text(Self.helpText), json: false, exitCode: 0)
        default:
            throw CLIError.usage("Unknown command: \(command)", jsonPreferred: false)
        }
    }

    private func status(_ args: [String]) throws -> CommandResult {
        let options = try StatusOptions.parse(args)
        let surfaces = surfaceService.statuses(scope: options.surface)
        let accounts = accountStore.accounts()
            .filter { !options.paidOnly || !$0.isFreePlan }
            .filter { !options.usableOnly || $0.usableForCodex }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.profileKey < rhs.profileKey
                }
                return lhs.score > rhs.score
            }
        let payload = StatusPayload(
            generatedAt: Date(),
            surfaces: surfaces,
            accounts: accounts
        )
        return CommandResult(payload: .status(payload), json: options.json, exitCode: 0)
    }

    private func switchProfile(_ args: [String]) throws -> CommandResult {
        let options = try SwitchOptions.parse(args)
        let outcome = try switchService.switchProfile(
            profileKey: options.profileKey,
            scope: options.surface,
            stopConsumers: options.stopConsumers
        )
        return CommandResult(payload: .switchOutcome(outcome), json: options.json, exitCode: 0)
    }

    private func doctor(_ args: [String]) throws -> CommandResult {
        let options = try DoctorOptions.parse(args)
        let surfaces = surfaceService.statuses(scope: .all)
        let consumerProcesses = switchService.consumerProcesses()
        let unsupported = surfaces.filter { $0.detected && !$0.supportsFileSwitching }
        let payload = DoctorPayload(
            generatedAt: Date(),
            appSupportPath: paths.appSupportURL.path,
            profilesPath: paths.profilesURL.path,
            consumersRunning: !consumerProcesses.isEmpty,
            consumerCount: consumerProcesses.count,
            unsupportedSurfaces: unsupported.map(\.kind),
            surfaces: surfaces
        )
        return CommandResult(payload: .doctor(payload), json: options.json, exitCode: 0)
    }

    private func autoswap(_ args: [String]) throws -> CommandResult {
        guard let subcommand = args.first else {
            throw CLIError.usage("Missing autoswap command. Use status, enable, disable, or run-once.", jsonPreferred: false)
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "status":
            return try autoswapStatus(rest)
        case "enable":
            return try autoswapSetEnabled(rest, enabled: true)
        case "disable":
            return try autoswapSetEnabled(rest, enabled: false)
        case "run-once":
            return try autoswapRunOnce(rest)
        default:
            throw CLIError.usage("Unknown autoswap command: \(subcommand)", jsonPreferred: false)
        }
    }

    private func autoswapStatus(_ args: [String]) throws -> CommandResult {
        let options = try AutoSwapStatusOptions.parse(args)
        let policy = autoSwapPolicyStore.load()
        let decisions = autoswapDecisions(policy: policy, scope: options.surface)
        let payload = AutoSwapStatusPayload(
            generatedAt: Date(),
            policy: policy,
            recentEvents: Array(autoSwapAuditStore.load().suffix(10)),
            decisions: decisions
        )
        return CommandResult(payload: .autoSwapStatus(payload), json: options.json, exitCode: 0)
    }

    private func autoswapSetEnabled(_ args: [String], enabled: Bool) throws -> CommandResult {
        let options = try AutoSwapToggleOptions.parse(args)
        var policy = autoSwapPolicyStore.load()
        for surface in options.surface.surfaceKinds {
            policy.setEnabled(enabled, for: surface.autoSwapKind)
        }
        options.apply(to: &policy)
        try autoSwapPolicyStore.save(policy)
        let decisions = autoswapDecisions(policy: policy, scope: options.surface)
        let payload = AutoSwapStatusPayload(
            generatedAt: Date(),
            policy: policy,
            recentEvents: Array(autoSwapAuditStore.load().suffix(10)),
            decisions: decisions
        )
        return CommandResult(payload: .autoSwapStatus(payload), json: options.json, exitCode: 0)
    }

    private func autoswapRunOnce(_ args: [String]) throws -> CommandResult {
        let options = try AutoSwapRunOptions.parse(args)
        let policy = autoSwapPolicyStore.load()
        let surfaces = surfaceService.statuses(scope: options.surface)
        let accounts = accountStore.accounts()
        let history = autoSwapAuditStore.load()
        let allConsumers = switchService.consumerProcesses()
        let stopConsumers = options.stopConsumers
        var decisions: [AutoSwapDecision] = []
        var switches: [AutoSwapSwitchPayload] = []
        var switchedAuthStores = Set<String>()

        for surface in surfaces {
            let planned = AutoSwapDecisionEngine.evaluate(
                policy: policy,
                surface: surface.autoSwapSurface,
                accounts: accounts.map(\.autoSwapAccount),
                history: history
            )
            guard planned.decision == .wouldSwitch,
                  let candidate = planned.candidateProfileKey else {
                decisions.append(planned)
                continue
            }
            guard options.dryRun == false else {
                decisions.append(planned)
                continue
            }
            let consumers = switchService.consumerProcesses(for: [surface])
            if !consumers.isEmpty && !stopConsumers {
                let blocked = AutoSwapDecision(
                    generatedAt: Date(),
                    surface: planned.surface,
                    decision: .blocked,
                    reason: .consumersRunning,
                    activeProfileKey: planned.activeProfileKey,
                    candidateProfileKey: planned.candidateProfileKey,
                    triggerSessionFreePercent: planned.triggerSessionFreePercent,
                    triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
                    targetMinSessionFreePercent: planned.targetMinSessionFreePercent
                )
                decisions.append(blocked)
                continue
            }
            let authStoreKey = surface.authStorePath.isEmpty ? surface.kind.rawValue : surface.authStorePath
            if switchedAuthStores.contains(authStoreKey) {
                decisions.append(AutoSwapDecision(
                    generatedAt: Date(),
                    surface: planned.surface,
                    decision: .switched,
                    reason: .switched,
                    activeProfileKey: planned.activeProfileKey,
                    candidateProfileKey: planned.candidateProfileKey,
                    triggerSessionFreePercent: planned.triggerSessionFreePercent,
                    triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
                    targetMinSessionFreePercent: planned.targetMinSessionFreePercent
                ))
                continue
            }
            let outcome = try switchService.switchProfile(
                profileKey: candidate,
                scope: SurfaceScope(surface.kind),
                stopConsumers: stopConsumers
            )
            switchedAuthStores.insert(authStoreKey)
            switches.append(AutoSwapSwitchPayload(outcome: outcome))
            let switched = AutoSwapDecision(
                generatedAt: Date(),
                surface: planned.surface,
                decision: .switched,
                reason: .switched,
                activeProfileKey: planned.activeProfileKey,
                candidateProfileKey: planned.candidateProfileKey,
                triggerSessionFreePercent: planned.triggerSessionFreePercent,
                triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
                targetMinSessionFreePercent: planned.targetMinSessionFreePercent
            )
            try autoSwapAuditStore.record(AutoSwapAuditEvent(
                generatedAt: switched.generatedAt,
                surface: switched.surface,
                decision: switched.decision,
                reason: .thresholdReached,
                fromProfileKey: switched.activeProfileKey,
                toProfileKey: switched.candidateProfileKey
            ))
            decisions.append(switched)
        }

        let payload = AutoSwapRunPayload(
            generatedAt: Date(),
            policy: policy,
            dryRun: options.dryRun,
            consumerCount: allConsumers.count,
            decisions: decisions,
            switches: switches
        )
        return CommandResult(payload: .autoSwapRun(payload), json: options.json, exitCode: 0)
    }

    private func autoswapDecisions(policy: AutoSwapPolicy, scope: SurfaceScope) -> [AutoSwapDecision] {
        let accounts = accountStore.accounts().map(\.autoSwapAccount)
        let history = autoSwapAuditStore.load()
        return surfaceService.statuses(scope: scope).map { surface in
            AutoSwapDecisionEngine.evaluate(
                policy: policy,
                surface: surface.autoSwapSurface,
                accounts: accounts,
                history: history
            )
        }
    }

    private static let helpText = """
    codex-switchboard status --json [--surface all|desktop|cli] [--paid-only] [--usable-only]
    codex-switchboard switch --profile-key <key> --surface desktop|cli|both --json [--stop-consumers]
    codex-switchboard autoswap status --json [--surface all|desktop|cli]
    codex-switchboard autoswap enable --surface cli|desktop|both --json [--trigger-session-free <percent>] [--target-min-session-free <percent>]
    codex-switchboard autoswap disable --surface cli|desktop|both --json
    codex-switchboard autoswap run-once --surface cli|desktop|both --json [--dry-run] [--stop-consumers]
    codex-switchboard doctor --json
    """
}

private enum SurfaceScope: String, Codable {
    case all
    case desktop
    case cli
    case both

    var surfaceKinds: [SurfaceKind] {
        switch self {
        case .all: return [.desktop, .cli]
        case .both: return [.desktop, .cli]
        case .desktop: return [.desktop]
        case .cli: return [.cli]
        }
    }

    init(_ surface: SurfaceKind) {
        switch surface {
        case .desktop:
            self = .desktop
        case .cli:
            self = .cli
        }
    }
}

private enum SurfaceKind: String, Codable, Hashable {
    case desktop
    case cli

    var displayName: String {
        switch self {
        case .desktop: return "Codex Desktop"
        case .cli: return "Codex CLI"
        }
    }

    var autoSwapKind: AutoSwapSurfaceKind {
        switch self {
        case .desktop: return .desktop
        case .cli: return .cli
        }
    }
}

private struct StatusOptions {
    let json: Bool
    let surface: SurfaceScope
    let paidOnly: Bool
    let usableOnly: Bool

    static func parse(_ args: [String]) throws -> StatusOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let paidOnly = parser.takeFlag("--paid-only")
        let usableOnly = parser.takeFlag("--usable-only")
        let surface = try parser.takeSurface(default: .all, allowed: [.all, .desktop, .cli])
        try parser.finish()
        return StatusOptions(json: json, surface: surface, paidOnly: paidOnly, usableOnly: usableOnly)
    }
}

private struct SwitchOptions {
    let json: Bool
    let profileKey: String
    let surface: SurfaceScope
    let stopConsumers: Bool

    static func parse(_ args: [String]) throws -> SwitchOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let stopConsumers = parser.takeFlag("--stop-consumers")
        let profileKey = try parser.takeRequiredValue("--profile-key")
        let surface = try parser.takeSurface(default: nil, allowed: [.desktop, .cli, .both])
        try parser.finish()
        return SwitchOptions(
            json: json,
            profileKey: profileKey,
            surface: surface,
            stopConsumers: stopConsumers
        )
    }
}

private struct DoctorOptions {
    let json: Bool

    static func parse(_ args: [String]) throws -> DoctorOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        try parser.finish()
        return DoctorOptions(json: json)
    }
}

private struct AutoSwapStatusOptions {
    let json: Bool
    let surface: SurfaceScope

    static func parse(_ args: [String]) throws -> AutoSwapStatusOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let surface = try parser.takeSurface(default: .all, allowed: [.all, .desktop, .cli])
        try parser.finish()
        return AutoSwapStatusOptions(json: json, surface: surface)
    }
}

private struct AutoSwapToggleOptions {
    let json: Bool
    let surface: SurfaceScope
    let triggerSessionFreePercent: Double?
    let triggerWeeklyFreePercent: Double?
    let targetMinSessionFreePercent: Double?
    let cooldownSeconds: Double?
    let maxSwitchesPerHour: Int?

    static func parse(_ args: [String]) throws -> AutoSwapToggleOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let triggerSessionFreePercent = try parser.takeOptionalDouble("--trigger-session-free")
        let triggerWeeklyFreePercent = try parser.takeOptionalDouble("--trigger-weekly-free")
        let targetMinSessionFreePercent = try parser.takeOptionalDouble("--target-min-session-free")
        let cooldownSeconds = try parser.takeOptionalDouble("--cooldown-seconds")
        let maxSwitchesPerHour = try parser.takeOptionalInt("--max-switches-per-hour")
        let surface = try parser.takeSurface(default: nil, allowed: [.desktop, .cli, .both])
        try parser.finish()
        return AutoSwapToggleOptions(
            json: json,
            surface: surface,
            triggerSessionFreePercent: triggerSessionFreePercent,
            triggerWeeklyFreePercent: triggerWeeklyFreePercent,
            targetMinSessionFreePercent: targetMinSessionFreePercent,
            cooldownSeconds: cooldownSeconds,
            maxSwitchesPerHour: maxSwitchesPerHour
        )
    }

    func apply(to policy: inout AutoSwapPolicy) {
        if let triggerSessionFreePercent {
            policy.triggerSessionFreePercent = max(0, min(100, triggerSessionFreePercent))
        }
        if let triggerWeeklyFreePercent {
            policy.triggerWeeklyFreePercent = max(0, min(100, triggerWeeklyFreePercent))
        }
        if let targetMinSessionFreePercent {
            policy.targetMinSessionFreePercent = max(0, min(100, targetMinSessionFreePercent))
        }
        if let cooldownSeconds {
            policy.cooldownSeconds = max(0, cooldownSeconds)
        }
        if let maxSwitchesPerHour {
            policy.maxSwitchesPerHour = max(1, maxSwitchesPerHour)
        }
    }
}

private struct AutoSwapRunOptions {
    let json: Bool
    let surface: SurfaceScope
    let dryRun: Bool
    let stopConsumers: Bool

    static func parse(_ args: [String]) throws -> AutoSwapRunOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let dryRun = parser.takeFlag("--dry-run")
        let stopConsumers = parser.takeFlag("--stop-consumers")
        let surface = try parser.takeSurface(default: nil, allowed: [.desktop, .cli, .both])
        try parser.finish()
        return AutoSwapRunOptions(json: json, surface: surface, dryRun: dryRun, stopConsumers: stopConsumers)
    }
}

private struct ArgumentParser {
    private var args: [String]

    init(_ args: [String]) {
        self.args = args
    }

    mutating func takeFlag(_ flag: String) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    mutating func takeRequiredValue(_ flag: String) throws -> String {
        guard let value = takeOptionalValue(flag), !value.isEmpty else {
            throw CLIError.usage("Missing required \(flag).", jsonPreferred: false)
        }
        return value
    }

    mutating func takeOptionalValue(_ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        args.remove(at: index)
        guard index < args.count else { return "" }
        return args.remove(at: index)
    }

    mutating func takeOptionalDouble(_ flag: String) throws -> Double? {
        guard let raw = takeOptionalValue(flag) else { return nil }
        guard let value = Double(raw) else {
            throw CLIError.usage("Invalid \(flag) \(raw). Expected a number.", jsonPreferred: false)
        }
        return value
    }

    mutating func takeOptionalInt(_ flag: String) throws -> Int? {
        guard let raw = takeOptionalValue(flag) else { return nil }
        guard let value = Int(raw) else {
            throw CLIError.usage("Invalid \(flag) \(raw). Expected an integer.", jsonPreferred: false)
        }
        return value
    }

    mutating func takeSurface(default defaultSurface: SurfaceScope?, allowed: Set<SurfaceScope>) throws -> SurfaceScope {
        guard let raw = takeOptionalValue("--surface") else {
            if let defaultSurface { return defaultSurface }
            throw CLIError.usage("Missing required --surface.", jsonPreferred: false)
        }
        guard let surface = SurfaceScope(rawValue: raw), allowed.contains(surface) else {
            let values = allowed.map(\.rawValue).sorted().joined(separator: "|")
            throw CLIError.usage("Invalid --surface \(raw). Expected \(values).", jsonPreferred: false)
        }
        return surface
    }

    func finish() throws {
        guard args.isEmpty else {
            throw CLIError.usage("Unexpected arguments: \(args.joined(separator: " "))", jsonPreferred: false)
        }
    }
}

private struct SwitchboardPaths {
    let fileManager = FileManager.default
    let homeURL: URL
    let appSupportURL: URL
    let profilesURL: URL
    let backupsURL: URL
    let accountsURL: URL
    let snapshotURL: URL
    let autoSwapPolicyURL: URL
    let autoSwapAuditURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
        if let override = ProcessInfo.processInfo.environment["CODEX_SWITCHBOARD_APP_SUPPORT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appSupportURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexSwitchboard", isDirectory: true)
        }
        profilesURL = appSupportURL.appendingPathComponent("profiles", isDirectory: true)
        backupsURL = appSupportURL.appendingPathComponent("backups", isDirectory: true)
        accountsURL = appSupportURL.appendingPathComponent("accounts.json")
        snapshotURL = appSupportURL.appendingPathComponent("accounts-snapshot.json")
        autoSwapPolicyURL = appSupportURL.appendingPathComponent("auto-swap-policy.json")
        autoSwapAuditURL = appSupportURL.appendingPathComponent("auto-swap-events.json")
    }

    func codexHome(for kind: SurfaceKind) -> URL {
        switch kind {
        case .desktop:
            return homeURL.appendingPathComponent(".codex", isDirectory: true)
        case .cli:
            if let value = ProcessInfo.processInfo.environment["CODEX_HOME"],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return URL(fileURLWithPath: value)
            }
            return homeURL.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    func ensureDirectory(_ url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func writeJSON(_ object: Any, to url: URL, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeData(data, to: url, permissions: permissions)
    }

    func writeData(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
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

private final class CLISurfaceService {
    private let paths: SwitchboardPaths
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths) {
        self.paths = paths
    }

    func statuses(scope: SurfaceScope) -> [SurfaceStatusPayload] {
        let raw = scope.surfaceKinds.map(status)
        return annotateSharedStores(raw)
    }

    func status(for kind: SurfaceKind) -> SurfaceStatusPayload {
        let codexHome = paths.codexHome(for: kind)
        let authURL = codexHome.appendingPathComponent("auth.json")
        let activeAuth = StoredAuth.load(from: authURL)
        let match = activeAuth.flatMap { CapturedProfileStore(paths: paths).profileMatching(auth: $0) }
        let mode = authStoreMode(in: codexHome)
        return SurfaceStatusPayload(
            kind: kind,
            displayName: kind.displayName,
            detected: detected(kind),
            running: running(kind),
            authStorePath: authURL.path,
            authStoreMode: mode,
            supportsFileSwitching: mode == "file",
            activeProfileKey: match?.sourceProfileKey,
            activeEmail: match?.email ?? activeAuth?.email,
            activeAccountID: match?.accountID ?? activeAuth?.accountID,
            sharedAuthStore: false,
            sharedWith: nil
        )
    }

    private func annotateSharedStores(_ statuses: [SurfaceStatusPayload]) -> [SurfaceStatusPayload] {
        statuses.map { status in
            var status = status
            let shared = statuses.first {
                $0.kind != status.kind
                    && $0.authStorePath == status.authStorePath
                    && !$0.authStorePath.isEmpty
            }
            status.sharedAuthStore = shared != nil
            status.sharedWith = shared?.kind
            return status
        }
    }

    private func detected(_ kind: SurfaceKind) -> Bool {
        switch kind {
        case .desktop:
            return codexDesktopAppPaths
                .contains { isCodexDesktopApp(atPath: $0) } || running(.desktop)
        case .cli:
            return cliExecutablePath() != nil
        }
    }

    private func running(_ kind: SurfaceKind) -> Bool {
        let lines = processLines()
        switch kind {
        case .desktop:
            return lines.contains { isCodexDesktopProcessCommand($0.lowercased()) }
        case .cli:
            return lines.contains { isCodexExecutableCommand($0.lowercased()) }
        }
    }

    private func cliExecutablePath() -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = envPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
        } + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(paths.homeURL.path)/.local/bin/codex",
            "\(paths.homeURL.path)/.openclaw/bin/codex",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func authStoreMode(in codexHome: URL) -> String {
        guard let config = try? String(
            contentsOf: codexHome.appendingPathComponent("config.toml"),
            encoding: .utf8
        ) else {
            return "file"
        }
        for key in ["cli_auth_credentials_store", "auth_credentials_store_mode", "auth_credentials_store"] {
            if let value = tomlStringValue(named: key, in: config) {
                return value
            }
        }
        return "file"
    }

    private func tomlStringValue(named key: String, in text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard line.hasPrefix("\(key)") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        return nil
    }
}

private final class CLIAccountStore {
    private let paths: SwitchboardPaths
    private let capturedProfiles: CapturedProfileStore

    init(paths: SwitchboardPaths) {
        self.paths = paths
        capturedProfiles = CapturedProfileStore(paths: paths)
    }

    func accounts() -> [AccountPayload] {
        if let snapshot = snapshotAccounts(), !snapshot.isEmpty {
            return snapshot
        }
        return profileFallbackAccounts()
    }

    private func snapshotAccounts() -> [AccountPayload]? {
        guard let data = try? Data(contentsOf: paths.snapshotURL),
              let snapshot = try? JSONDecoder().decode(AccountSnapshot.self, from: data) else {
            return nil
        }
        let snapshotRefreshDate = snapshot.lastRefreshEpoch.map {
            Date(timeIntervalSince1970: $0)
        } ?? Date()
        return snapshot.accounts.compactMap { account in
            guard let profileKey = account.profileKey else { return nil }
            return AccountPayload(
                snapshot: account,
                snapshotRefreshDate: snapshotRefreshDate,
                hasCapturedAuth: capturedProfiles.hasProfile(sourceProfileKey: profileKey)
            )
        }
    }

    private func profileFallbackAccounts() -> [AccountPayload] {
        let collection = LocalProfileCollection.load(from: paths.accountsURL)
        return collection.orderedKeys.compactMap { key in
            guard let entry = collection.profiles[key] else { return nil }
            let email = entry["email"] as? String
                ?? entry["accountId"] as? String
                ?? key.components(separatedBy: ":").last
                ?? key
            return AccountPayload(
                profileKey: key,
                email: email,
                workspace: "?",
                plan: "?",
                sessionFreePercent: 0,
                weeklyFreePercent: 0,
                usableForCodex: false,
                needsRelogin: false,
                nextResetAt: nil,
                isFreePlan: false,
                score: 0
            )
        }
    }
}

private final class CLISwitchService {
    private let paths: SwitchboardPaths
    private let surfaceService: CLISurfaceService
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths, surfaceService: CLISurfaceService) {
        self.paths = paths
        self.surfaceService = surfaceService
    }

    func switchProfile(profileKey: String, scope: SurfaceScope, stopConsumers: Bool) throws -> SwitchPayload {
        let profileStore = CapturedProfileStore(paths: paths)
        let profile = try profileStore.profile(sourceProfileKey: profileKey)
        try validateCapturedProfile(profile)

        let surfaces = surfaceService.statuses(scope: scope)
        let undetected = surfaces.filter { !$0.detected }
        if let firstUndetected = undetected.first {
            throw CLIError.surfaceNotDetected(
                surface: firstUndetected.kind.rawValue,
                jsonPreferred: true
            )
        }
        let unsupported = surfaces.filter { !$0.supportsFileSwitching }
        if let firstUnsupported = unsupported.first {
            throw CLIError.unsupportedMode(
                surface: firstUnsupported.kind.rawValue,
                mode: firstUnsupported.authStoreMode,
                path: firstUnsupported.authStorePath,
                jsonPreferred: true
            )
        }

        let consumers = consumerProcesses(for: surfaces)
        if !consumers.isEmpty {
            guard stopConsumers else {
                throw CLIError.consumersRunning(consumers.map(\.description), jsonPreferred: true)
            }
            terminate(consumers, for: surfaces)
        }

        var written: [SwitchSurfacePayload] = []
        var destinations: [(surface: SurfaceStatusPayload, url: URL)] = []
        var seenDestinations = Set<String>()
        for surface in surfaces {
            let destination = URL(fileURLWithPath: surface.authStorePath)
            guard !seenDestinations.contains(destination.path) else {
                written.append(SwitchSurfacePayload(
                    kind: surface.kind,
                    authStorePath: destination.path,
                    authStoreMode: surface.authStoreMode,
                    sharedAuthStore: true
                ))
                continue
            }
            seenDestinations.insert(destination.path)
            destinations.append((surface, destination))
        }

        let sourceData = try Data(contentsOf: profile.authURL)
        let previousAuth = destinations.reduce(into: [String: Data?]()) { result, destination in
            result[destination.url.path] = try? Data(contentsOf: destination.url)
        }
        var mutatedDestinations: [URL] = []
        do {
            for (surface, destination) in destinations {
                try backupLiveAuth(at: destination, target: profile)
                try paths.writeData(sourceData, to: destination, permissions: 0o600)
                mutatedDestinations.append(destination)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                written.append(SwitchSurfacePayload(
                    kind: surface.kind,
                    authStorePath: destination.path,
                    authStoreMode: surface.authStoreMode,
                    sharedAuthStore: surface.sharedAuthStore
                ))
            }
        } catch {
            rollback(destinations: mutatedDestinations, previousAuth: previousAuth)
            throw error
        }

        for surface in surfaces {
            let destination = URL(fileURLWithPath: surface.authStorePath)
            guard seenDestinations.contains(destination.path),
                  destinations.contains(where: { $0.url.path == destination.path }) else {
                continue
            }
            if written.contains(where: { $0.kind == surface.kind }) {
                continue
            }
            written.append(SwitchSurfacePayload(
                kind: surface.kind,
                authStorePath: destination.path,
                authStoreMode: surface.authStoreMode,
                sharedAuthStore: surface.sharedAuthStore
            ))
        }

        return SwitchPayload(
            generatedAt: Date(),
            profileKey: profile.sourceProfileKey,
            email: profile.email,
            accountID: profile.accountID,
            surfaces: written
        )
    }

    private func rollback(destinations: [URL], previousAuth: [String: Data?]) {
        for destination in destinations.reversed() {
            if let previous = previousAuth[destination.path] ?? nil {
                try? paths.writeData(previous, to: destination, permissions: 0o600)
            } else {
                try? fileManager.removeItem(at: destination)
            }
        }
    }

    func consumerProcesses() -> [ProcessInfoPayload] {
        let currentPID = Darwin.getpid()
        return processLinesWithPID().compactMap { pid, command in
            guard pid != currentPID else { return nil }
            guard isCodexConsumerCommand(command.lowercased()) else { return nil }
            return ProcessInfoPayload(pid: pid, command: command)
        }
    }

    func consumerProcesses(for surfaces: [SurfaceStatusPayload]) -> [ProcessInfoPayload] {
        let targetKinds = consumerTargetKinds(for: surfaces)
        let currentPID = Darwin.getpid()
        return processLinesWithPID().compactMap { pid, command in
            guard pid != currentPID else { return nil }
            guard isCodexConsumerCommand(command.lowercased(), for: targetKinds) else { return nil }
            return ProcessInfoPayload(pid: pid, command: command)
        }
    }

    private func consumerTargetKinds(for surfaces: [SurfaceStatusPayload]) -> Set<SurfaceKind> {
        surfaces.reduce(into: Set<SurfaceKind>()) { result, surface in
            result.insert(surface.kind)
            if surface.sharedAuthStore, let sharedWith = surface.sharedWith {
                result.insert(sharedWith)
            }
        }
    }

    private func validateCapturedProfile(_ profile: CapturedProfile) throws {
        guard let auth = StoredAuth.load(from: profile.authURL),
              auth.hasCompleteTokens,
              auth.email.isEmpty || profile.email.isEmpty || auth.email == profile.email,
              auth.accountID.isEmpty || profile.accountID.isEmpty || auth.accountID == profile.accountID else {
            throw CLIError.failure(message: "Captured profile is missing valid redacted identity fields.", jsonPreferred: true)
        }
    }

    private func terminate(_ consumers: [ProcessInfoPayload], for surfaces: [SurfaceStatusPayload]) {
        let pids = consumers.map(\.pid)
        _ = try? run("/bin/kill", ["-TERM"] + pids.map(String.init), timeout: 3)
        if waitForConsumersToExit(for: surfaces, timeout: 3) {
            return
        }
        let remaining = consumerProcesses(for: surfaces).map(\.pid)
        guard !remaining.isEmpty else { return }
        _ = try? run("/bin/kill", ["-KILL"] + remaining.map(String.init), timeout: 3)
        _ = waitForConsumersToExit(for: surfaces, timeout: 2)
    }

    private func waitForConsumersToExit(for surfaces: [SurfaceStatusPayload], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if consumerProcesses(for: surfaces).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return consumerProcesses(for: surfaces).isEmpty
    }

    private func backupLiveAuth(at authURL: URL, target: CapturedProfile) throws {
        guard fileManager.fileExists(atPath: authURL.path) else { return }
        let timestamp = DateFormatter.cliBackup.string(from: Date())
        let backupURL = paths.backupsURL
            .appendingPathComponent("\(timestamp)-cli-switch", isDirectory: true)
        try paths.ensureDirectory(backupURL, permissions: 0o700)
        let safeAuthName = authURL.path
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let backupAuthURL = backupURL.appendingPathComponent("\(safeAuthName)-auth.json")
        try fileManager.copyItem(at: authURL, to: backupAuthURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupAuthURL.path)
        try paths.writeJSON(
            [
                "target_email": target.email,
                "target_account_id": target.accountID,
                "target_source_profile_key": target.sourceProfileKey,
                "destination_auth_store": authURL.path,
                "created_at": ISO8601DateFormatter.cli.string(from: Date()),
                "reason": "cli-switch",
            ],
            to: backupURL.appendingPathComponent("\(safeAuthName)-metadata.json"),
            permissions: 0o600
        )
    }

    private func copyReplacing(source: URL, destination: URL) throws {
        let data = try Data(contentsOf: source)
        try paths.writeData(data, to: destination, permissions: 0o600)
    }
}

private struct LocalProfileCollection {
    let profiles: [String: [String: Any]]
    let orderedKeys: [String]

    static func load(from url: URL) -> LocalProfileCollection {
        guard let root = readJSON(url),
              let profiles = root["profiles"] as? [String: [String: Any]] else {
            return LocalProfileCollection(profiles: [:], orderedKeys: [])
        }
        return LocalProfileCollection(
            profiles: profiles,
            orderedKeys: orderedKeys(root: root, profiles: profiles)
        )
    }

    private static func orderedKeys(root: [String: Any], profiles: [String: [String: Any]]) -> [String] {
        let orderMap = root["order"] as? [String: [String]] ?? [:]
        var ordered: [String] = []
        var seen = Set<String>()
        for keys in orderMap.values {
            for key in keys where profiles[key] != nil && !seen.contains(key) {
                ordered.append(key)
                seen.insert(key)
            }
        }
        for key in profiles.keys.sorted() where !seen.contains(key) {
            ordered.append(key)
        }
        return ordered
    }
}

private final class CapturedProfileStore {
    private let paths: SwitchboardPaths
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths) {
        self.paths = paths
    }

    func profile(sourceProfileKey: String) throws -> CapturedProfile {
        let matches = profiles().filter { $0.sourceProfileKey == sourceProfileKey }
        guard let newest = matches.max(by: { $0.freshnessDate < $1.freshnessDate }) else {
            throw CLIError.failure(message: "Captured auth was not found for profile_key \(sourceProfileKey).", jsonPreferred: true)
        }
        return newest
    }

    func profileMatching(auth: StoredAuth) -> CapturedProfile? {
        let loadedProfiles = profiles().compactMap { profile -> (profile: CapturedProfile, auth: StoredAuth)? in
            guard let profileAuth = StoredAuth.load(from: profile.authURL) else { return nil }
            return (profile, profileAuth)
        }
        let exactMatches = loadedProfiles.filter { candidate in
            candidate.auth.idToken == auth.idToken
                && candidate.auth.accessToken == auth.accessToken
                && candidate.auth.refreshToken == auth.refreshToken
        }
        if let match = newestProfile(from: exactMatches) {
            return match
        }

        return newestProfile(from: loadedProfiles.filter { candidate in
            candidate.auth.matchesStableIdentity(auth, capturedProfile: candidate.profile)
        })
    }

    func hasProfile(sourceProfileKey: String) -> Bool {
        profiles().contains { $0.sourceProfileKey == sourceProfileKey }
    }

    private func profiles() -> [CapturedProfile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.profilesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            guard entry.lastPathComponent != "backups",
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let authURL = entry.appendingPathComponent("auth.json")
            guard fileManager.fileExists(atPath: authURL.path) else { return nil }
            let meta = readJSON(entry.appendingPathComponent("meta.json")) ?? [:]
            let auth = StoredAuth.load(from: authURL)
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return CapturedProfile(
                profileURL: entry,
                authURL: authURL,
                email: ((meta["email"] as? String) ?? auth?.email ?? "").lowercased(),
                accountID: (meta["account_id"] as? String) ?? auth?.accountID ?? "",
                sourceProfileKey: (meta["source_profile_key"] as? String) ?? "",
                freshnessDate: modified
            )
        }
    }

    private func newestProfile(from matches: [(profile: CapturedProfile, auth: StoredAuth)]) -> CapturedProfile? {
        matches.map(\.profile).max { $0.freshnessDate < $1.freshnessDate }
    }
}

private struct CapturedProfile {
    let profileURL: URL
    let authURL: URL
    let email: String
    let accountID: String
    let sourceProfileKey: String
    let freshnessDate: Date
}

private struct StoredAuth {
    let root: [String: Any]
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let email: String
    let subject: String

    var hasCompleteTokens: Bool {
        !idToken.isEmpty && !accessToken.isEmpty && !refreshToken.isEmpty
    }

    static func load(from url: URL) -> StoredAuth? {
        guard let root = readJSON(url),
              let tokens = root["tokens"] as? [String: Any] else {
            return nil
        }
        let idToken = tokens["id_token"] as? String ?? ""
        let accessToken = tokens["access_token"] as? String ?? ""
        let refreshToken = tokens["refresh_token"] as? String ?? ""
        let idPayload = decodePayload(idToken)
        let authPayload = idPayload?["https://api.openai.com/auth"] as? [String: Any]
        return StoredAuth(
            root: root,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: ((tokens["account_id"] as? String) ?? (authPayload?["chatgpt_account_id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            email: ((idPayload?["email"] as? String) ?? "").lowercased(),
            subject: ((idPayload?["sub"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func matchesStableIdentity(_ other: StoredAuth, capturedProfile: CapturedProfile) -> Bool {
        if !subject.isEmpty, !other.subject.isEmpty, subject == other.subject {
            return accountIDsCompatible(accountID, other.accountID)
        }
        if !accountID.isEmpty, !other.accountID.isEmpty, accountID == other.accountID {
            return true
        }
        if !capturedProfile.accountID.isEmpty,
           !other.accountID.isEmpty,
           capturedProfile.accountID == other.accountID {
            return true
        }
        if !email.isEmpty, !other.email.isEmpty, email == other.email {
            return accountIDsCompatible(accountID, other.accountID)
        }
        if !capturedProfile.email.isEmpty, !other.email.isEmpty, capturedProfile.email == other.email {
            return accountIDsCompatible(capturedProfile.accountID, other.accountID)
        }
        return false
    }

    private func accountIDsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs.isEmpty || rhs.isEmpty || lhs == rhs
    }

    private static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Data(base64URLString: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload
    }
}

private struct AccountSnapshot: Decodable {
    let lastRefreshEpoch: TimeInterval?
    let accounts: [SnapshotAccount]
}

private struct SnapshotAccount: Decodable {
    let profileKey: String?
    let email: String
    let workspace: String
    let plan: String
    let sessionFree: Double
    let weeklyFree: Double
    let sessionResetSeconds: Double
    let weeklyResetSeconds: Double
    let hasError: Bool
    let errorMessage: String?
}

private struct AccountPayload: Codable {
    let profileKey: String
    let email: String
    let workspace: String
    let plan: String
    let sessionFreePercent: Double
    let weeklyFreePercent: Double
    let usableForCodex: Bool
    let needsRelogin: Bool
    let nextResetAt: Date?
    let isFreePlan: Bool
    let score: Double

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key"
        case email
        case workspace
        case plan
        case sessionFreePercent = "session_free_percent"
        case weeklyFreePercent = "weekly_free_percent"
        case usableForCodex = "usable_for_codex"
        case needsRelogin = "needs_relogin"
        case nextResetAt = "next_reset_at"
        case isFreePlan = "is_free_plan"
        case score
    }

    init(
        profileKey: String,
        email: String,
        workspace: String,
        plan: String,
        sessionFreePercent: Double,
        weeklyFreePercent: Double,
        usableForCodex: Bool,
        needsRelogin: Bool,
        nextResetAt: Date?,
        isFreePlan: Bool,
        score: Double
    ) {
        self.profileKey = profileKey
        self.email = email
        self.workspace = workspace
        self.plan = plan
        self.sessionFreePercent = sessionFreePercent
        self.weeklyFreePercent = weeklyFreePercent
        self.usableForCodex = usableForCodex
        self.needsRelogin = needsRelogin
        self.nextResetAt = nextResetAt
        self.isFreePlan = isFreePlan
        self.score = score
    }

    init?(
        snapshot: SnapshotAccount,
        snapshotRefreshDate: Date,
        hasCapturedAuth: Bool
    ) {
        guard let profileKey = snapshot.profileKey, !profileKey.isEmpty else { return nil }
        let usable = !snapshot.hasError
            && snapshot.sessionFree > 0.001
            && snapshot.weeklyFree > 0.001
            && hasCapturedAuth
        let isFree = snapshot.plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free"
        let nextReset = Self.nextResetDate(
            sessionFree: snapshot.sessionFree,
            weeklyFree: snapshot.weeklyFree,
            sessionResetSeconds: snapshot.sessionResetSeconds,
            weeklyResetSeconds: snapshot.weeklyResetSeconds,
            baseDate: snapshotRefreshDate
        )
        let needsRelogin = Self.needsRelogin(snapshot.errorMessage) || !hasCapturedAuth
        let baseScore = snapshot.sessionFree * 0.6 + snapshot.weeklyFree * 0.4
        let penalty = (snapshot.hasError ? 1_000.0 : 0) + (isFree ? 100.0 : 0)
        self.init(
            profileKey: profileKey,
            email: snapshot.email,
            workspace: snapshot.workspace,
            plan: snapshot.plan,
            sessionFreePercent: snapshot.sessionFree,
            weeklyFreePercent: snapshot.weeklyFree,
            usableForCodex: usable,
            needsRelogin: needsRelogin,
            nextResetAt: nextReset,
            isFreePlan: isFree,
            score: baseScore - penalty
        )
    }

    private static func nextResetDate(
        sessionFree: Double,
        weeklyFree: Double,
        sessionResetSeconds: Double,
        weeklyResetSeconds: Double,
        baseDate: Date
    ) -> Date? {
        let seconds: Double
        if sessionFree <= 0.001, sessionResetSeconds > 0 {
            seconds = sessionResetSeconds
        } else if weeklyFree <= 0.001, weeklyResetSeconds > 0 {
            seconds = weeklyResetSeconds
        } else if weeklyResetSeconds > 0 {
            seconds = weeklyResetSeconds
        } else if sessionResetSeconds > 0 {
            seconds = sessionResetSeconds
        } else {
            return nil
        }
        return baseDate.addingTimeInterval(seconds)
    }

    private static func needsRelogin(_ errorMessage: String?) -> Bool {
        guard let value = errorMessage?.lowercased() else { return false }
        return value.contains("expired")
            || value.contains("revoked")
            || value.contains("invalidated")
            || value.contains("http 401")
            || value.contains("http 403")
            || value.contains("refresh failed")
    }
}

private struct SurfaceStatusPayload: Codable {
    let kind: SurfaceKind
    let displayName: String
    let detected: Bool
    let running: Bool
    let authStorePath: String
    let authStoreMode: String
    let supportsFileSwitching: Bool
    let activeProfileKey: String?
    let activeEmail: String?
    let activeAccountID: String?
    var sharedAuthStore: Bool
    var sharedWith: SurfaceKind?

    enum CodingKeys: String, CodingKey {
        case kind
        case displayName = "display_name"
        case detected
        case running
        case authStorePath = "auth_store_path"
        case authStoreMode = "auth_store_mode"
        case supportsFileSwitching = "supports_file_switching"
        case activeProfileKey = "active_profile_key"
        case activeEmail = "active_email"
        case activeAccountID = "active_account_id"
        case sharedAuthStore = "shared_auth_store"
        case sharedWith = "shared_with"
    }
}

private extension SurfaceStatusPayload {
    var autoSwapSurface: AutoSwapSurface {
        AutoSwapSurface(
            kind: kind.autoSwapKind,
            detected: detected,
            supportsFileSwitching: supportsFileSwitching,
            activeProfileKey: activeProfileKey,
            authStoreMode: authStoreMode
        )
    }
}

private extension AccountPayload {
    var autoSwapAccount: AutoSwapAccount {
        AutoSwapAccount(
            profileKey: profileKey,
            sessionFreePercent: sessionFreePercent,
            weeklyFreePercent: weeklyFreePercent,
            usableForCodex: usableForCodex,
            needsRelogin: needsRelogin,
            isFreePlan: isFreePlan,
            score: score
        )
    }
}

private struct StatusPayload: Codable {
    let generatedAt: Date
    let surfaces: [SurfaceStatusPayload]
    let accounts: [AccountPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case surfaces
        case accounts
    }
}

private struct SwitchPayload: Codable {
    let generatedAt: Date
    let profileKey: String
    let email: String
    let accountID: String
    let surfaces: [SwitchSurfacePayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case profileKey = "profile_key"
        case email
        case accountID = "account_id"
        case surfaces
    }
}

private struct SwitchSurfacePayload: Codable {
    let kind: SurfaceKind
    let authStorePath: String
    let authStoreMode: String
    let sharedAuthStore: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case authStorePath = "auth_store_path"
        case authStoreMode = "auth_store_mode"
        case sharedAuthStore = "shared_auth_store"
    }
}

private struct DoctorPayload: Codable {
    let generatedAt: Date
    let appSupportPath: String
    let profilesPath: String
    let consumersRunning: Bool
    let consumerCount: Int
    let unsupportedSurfaces: [SurfaceKind]
    let surfaces: [SurfaceStatusPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case appSupportPath = "app_support_path"
        case profilesPath = "profiles_path"
        case consumersRunning = "consumers_running"
        case consumerCount = "consumer_count"
        case unsupportedSurfaces = "unsupported_surfaces"
        case surfaces
    }
}

private struct AutoSwapStatusPayload: Codable {
    let generatedAt: Date
    let policy: AutoSwapPolicy
    let recentEvents: [AutoSwapAuditEvent]
    let decisions: [AutoSwapDecision]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case policy
        case recentEvents = "recent_events"
        case decisions
    }
}

private struct AutoSwapRunPayload: Codable {
    let generatedAt: Date
    let policy: AutoSwapPolicy
    let dryRun: Bool
    let consumerCount: Int
    let decisions: [AutoSwapDecision]
    let switches: [AutoSwapSwitchPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case policy
        case dryRun = "dry_run"
        case consumerCount = "consumer_count"
        case decisions
        case switches
    }
}

private struct AutoSwapSwitchPayload: Codable {
    let generatedAt: Date
    let profileKey: String
    let surfaces: [AutoSwapSwitchSurfacePayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case profileKey = "profile_key"
        case surfaces
    }

    init(outcome: SwitchPayload) {
        generatedAt = outcome.generatedAt
        profileKey = outcome.profileKey
        surfaces = outcome.surfaces.map(AutoSwapSwitchSurfacePayload.init)
    }
}

private struct AutoSwapSwitchSurfacePayload: Codable {
    let kind: SurfaceKind
    let authStoreMode: String
    let sharedAuthStore: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case authStoreMode = "auth_store_mode"
        case sharedAuthStore = "shared_auth_store"
    }

    init(surface: SwitchSurfacePayload) {
        kind = surface.kind
        authStoreMode = surface.authStoreMode
        sharedAuthStore = surface.sharedAuthStore
    }
}

private struct ProcessInfoPayload: Codable {
    let pid: Int32
    let command: String

    var description: String {
        "\(pid) \(command)"
    }
}

private enum EncodablePayload {
    case text(String)
    case status(StatusPayload)
    case switchOutcome(SwitchPayload)
    case doctor(DoctorPayload)
    case autoSwapStatus(AutoSwapStatusPayload)
    case autoSwapRun(AutoSwapRunPayload)
    case error(ErrorPayload)
}

private struct ErrorPayload: Codable {
    let generatedAt: Date
    let error: String
    let message: String
    let details: [String]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case error
        case message
        case details
    }
}

private enum CLIError: LocalizedError {
    case usage(String, jsonPreferred: Bool)
    case surfaceNotDetected(surface: String, jsonPreferred: Bool)
    case consumersRunning([String], jsonPreferred: Bool)
    case unsupportedMode(surface: String, mode: String, path: String, jsonPreferred: Bool)
    case failure(message: String, jsonPreferred: Bool)

    var errorDescription: String? {
        switch self {
        case let .usage(message, _):
            return message
        case let .surfaceNotDetected(surface, _):
            return "Requested Codex surface is not detected: \(surface)."
        case let .consumersRunning(processes, _):
            return "Codex consumers are running; pass --stop-consumers to terminate them before switching. \(processes.joined(separator: "; "))"
        case let .unsupportedMode(surface, mode, path, _):
            return "Unsupported auth store mode for \(surface): \(mode) at \(path). File-backed switching is supported; keyring, auto, and ephemeral modes are detected but not mutated."
        case let .failure(message, _):
            return message
        }
    }

    var code: String {
        switch self {
        case .usage:
            return "usage"
        case .surfaceNotDetected:
            return "surface_not_detected"
        case .consumersRunning:
            return "consumers_running"
        case .unsupportedMode:
            return "unsupported_auth_store_mode"
        case .failure:
            return "failure"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage:
            return 64
        case .surfaceNotDetected, .consumersRunning, .unsupportedMode:
            return 2
        case .failure:
            return 1
        }
    }

    var jsonPreferred: Bool {
        switch self {
        case let .usage(_, value),
             let .surfaceNotDetected(_, value),
             let .consumersRunning(_, value),
             let .unsupportedMode(_, _, _, value),
             let .failure(_, value):
            return value
        }
    }

    var details: [String]? {
        switch self {
        case let .consumersRunning(processes, _):
            return processes
        default:
            return nil
        }
    }
}

private enum Output {
    static func write(_ payload: EncodablePayload, json: Bool) {
        if json {
            switch payload {
            case let .status(value):
                printJSON(value)
            case let .switchOutcome(value):
                printJSON(value)
            case let .doctor(value):
                printJSON(value)
            case let .autoSwapStatus(value):
                printJSON(value)
            case let .autoSwapRun(value):
                printJSON(value)
            case let .error(value):
                printJSON(value)
            case let .text(value):
                print(value)
            }
        } else {
            switch payload {
            case let .text(value):
                print(value)
            case let .status(value):
                print("surfaces: \(value.surfaces.count), accounts: \(value.accounts.count)")
            case let .switchOutcome(value):
                print("switched \(value.profileKey) on \(value.surfaces.map { $0.kind.rawValue }.joined(separator: ","))")
            case let .doctor(value):
                print("consumers_running: \(value.consumersRunning), unsupported_surfaces: \(value.unsupportedSurfaces.map(\.rawValue).joined(separator: ","))")
            case let .autoSwapStatus(value):
                print("autoswap_enabled: \(value.policy.enabledSurfaces.map(\.rawValue).sorted().joined(separator: ",")), decisions: \(value.decisions.count)")
            case let .autoSwapRun(value):
                let summary = value.decisions.map { "\($0.surface.rawValue):\($0.decision.rawValue)" }.joined(separator: ",")
                print("autoswap_run: \(summary), consumers: \(value.consumerCount)")
            case let .error(value):
                fputs("\(value.message)\n", stderr)
            }
        }
    }

    static func writeError(_ error: CLIError, json: Bool) {
        let payload = ErrorPayload(
            generatedAt: Date(),
            error: error.code,
            message: error.localizedDescription,
            details: error.details
        )
        if json {
            printJSON(payload)
        } else {
            fputs("\(payload.message)\n", stderr)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            print(#"{"error":"encode_failed"}"#)
        }
    }
}

private func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func processLines() -> [String] {
    runBestEffort("/bin/ps", ["-axo", "command="])
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private func processLinesWithPID() -> [(pid: Int32, command: String)] {
    runBestEffort("/bin/ps", ["-axo", "pid=,command="])
        .split(separator: "\n")
        .compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<split]) else {
                return nil
            }
            let command = trimmed[split...].trimmingCharacters(in: .whitespaces)
            return (pid, command)
        }
}

private func isCodexConsumerCommand(_ lowercasedCommand: String) -> Bool {
    isCodexConsumerCommand(lowercasedCommand, for: [.desktop, .cli])
}

private func isCodexConsumerCommand(_ lowercasedCommand: String, for targetKinds: Set<SurfaceKind>) -> Bool {
    if targetKinds.contains(.desktop),
       isCodexDesktopProcessCommand(lowercasedCommand) {
        return true
    }
    guard targetKinds.contains(.cli) else {
        return false
    }
    if isCodexExecutableCommand(lowercasedCommand) {
        return true
    }
    if lowercasedCommand.hasPrefix("node "),
       lowercasedCommand.contains("/codex "),
       (lowercasedCommand.contains(" app-server ") || lowercasedCommand.contains(" exec ")) {
        return true
    }
    return lowercasedCommand.hasPrefix("/")
        && (
            lowercasedCommand.contains("/node_repl ")
                || lowercasedCommand.hasSuffix("/node_repl")
        )
}

private let codexDesktopAppPaths = [
    "/Applications/ChatGPT.app",
    "/Applications/Codex.app",
]

private func isCodexDesktopProcessCommand(_ lowercasedCommand: String) -> Bool {
    codexDesktopAppPaths.contains { appPath in
        lowercasedCommand.contains("\(appPath.lowercased())/contents/")
            && isCodexDesktopApp(atPath: appPath)
    }
}

private func isCodexDesktopApp(atPath path: String) -> Bool {
    let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return false
    }
    return info["CFBundleIdentifier"] as? String == "com.openai.codex"
}

private func isCodexExecutableCommand(_ lowercasedCommand: String) -> Bool {
    if lowercasedCommand == "codex" || lowercasedCommand.hasPrefix("codex ") {
        return true
    }
    guard lowercasedCommand.hasPrefix("/") else {
        return false
    }
    return lowercasedCommand.hasSuffix("/codex")
        || lowercasedCommand.contains("/codex ")
        || lowercasedCommand.hasSuffix("/codex/codex")
        || lowercasedCommand.contains("/codex/codex ")
}

@discardableResult
private func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSwitchboardCLI-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          let outputHandle = FileHandle(forWritingAtPath: outputURL.path) else {
        throw CLIError.failure(message: "Could not create temporary command output file.", jsonPreferred: true)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    defer {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
    }

    process.standardOutput = outputHandle
    process.standardError = outputHandle
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.25)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()
    try outputHandle.synchronize()

    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw CLIError.failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines), jsonPreferred: true)
    }
    return output
}

private func runBestEffort(_ launchPath: String, _ arguments: [String]) -> String {
    (try? run(launchPath, arguments)) ?? ""
}

private extension Data {
    init?(base64URLString: String) {
        var normalized = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

private extension ISO8601DateFormatter {
    static let cli: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension DateFormatter {
    static let cliBackup: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
