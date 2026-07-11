import Foundation
import Combine
import CodexSwitchboardCore

/// Central state holder observed by all SwiftUI views.
@MainActor
final class UsageViewModel: ObservableObject {

    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var isLoading = false
    @Published var isAddingAccount = false
    @Published var reloggingAccountID: String?
    @Published var switchingAccountID: String?
    @Published var removingAccountID: String?
    @Published var accountActionError: String?
    @Published var codexLoginStatus: CodexLoginStatus = .empty
    @Published var activeCodexProfileKey: String?
    @Published var codexSurfaceStatuses: [CodexSurfaceStatus] = []
    @Published var selectedCodexSurface: CodexSurfaceKind = .desktop
    @Published var autoSwapPolicy: AutoSwapPolicy = AutoSwapPolicy()
    @Published var autoSwapDecisions: [CodexSurfaceKind: AutoSwapDecision] = [:]
    @Published var autoSwapSwitchingSurface: CodexSurfaceKind?
    @Published var isCodexInstalled = false
    @Published var lastRefresh: Date?
    @Published var error: String?

    @Published var searchText = ""
    @Published var groupByWorkspace = false {
        didSet { UserDefaults.standard.set(groupByWorkspace, forKey: "groupByWorkspace") }
    }
    @Published var informationMode: AccountInformationMode = .focused {
        didSet { UserDefaults.standard.set(informationMode.rawValue, forKey: "accountInformationMode") }
    }
    @Published var listDensity: ListDensity = .compact {
        didSet { UserDefaults.standard.set(listDensity.rawValue, forKey: "listDensity") }
    }
    @Published var resetTextScalePercent = ResetTextScale.defaultPercent {
        didSet {
            UserDefaults.standard.set(resetTextScalePercent, forKey: "resetTextScalePercent")
        }
    }
    @Published var waitingForResetCollapsed = false
    @Published var freeWaitingCollapsed = true

    // MARK: - Internals

    private let service = UsageService()
    private let captureService = CodexAccountCaptureService()
    private let switchService = CodexAccountSwitchService()
    private let surfaceService = CodexSurfaceService()
    private let autoSwapPolicyStore = AutoSwapAppStores.policyStore
    private let autoSwapAuditStore = AutoSwapAppStores.auditStore
    private let removalService = LocalAccountRemovalService()
    private var refreshTimer: Timer?
    private var reloginTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var pendingDebouncedRefreshTask: Task<Void, Never>?
    private var pendingRefreshAfterCurrent = false

    // MARK: - Init

    init() {
        if UserDefaults.standard.object(forKey: "groupByWorkspace") != nil {
            groupByWorkspace = UserDefaults.standard.bool(forKey: "groupByWorkspace")
        }
        if let rawMode = UserDefaults.standard.string(forKey: "accountInformationMode"),
           let savedMode = AccountInformationMode(rawValue: rawMode) {
            informationMode = savedMode
        } else {
            informationMode = .focused
        }
        listDensity = .compact
        if UserDefaults.standard.object(forKey: "resetTextScalePercent") != nil {
            resetTextScalePercent = ResetTextScale.clampedPercent(
                UserDefaults.standard.integer(forKey: "resetTextScalePercent")
            )
        }
        if AccountProfileStore.hasProfiles, let snap = AccountSnapshotStore.load() {
            accounts = snap.accounts
            lastRefresh = snap.lastRefresh
        }
        autoSwapPolicy = autoSwapPolicyStore.load()
        codexLoginStatus = CodexLoginStatusStore.load()
        refreshCodexAvailability()
    }

    // MARK: - Derived Lists

    private var visibleAccounts: [Account] {
        Self.visibleAccounts(from: accounts)
    }

    static func visibleAccounts(from accounts: [Account]) -> [Account] {
        accounts
    }

    private var searchFiltered: [Account] {
        guard !searchText.isEmpty else { return visibleAccounts }
        return visibleAccounts.filter { $0.email.localizedCaseInsensitiveContains(searchText) }
    }

    /// Smart score for default ordering of active rows.
    static func smartScore(_ a: Account) -> Double {
        min(a.sessionFree, a.weeklyFree)
    }

    /// Urgency for priority ordering.
    static func expiringScore(_ a: Account) -> Double {
        let w = a.weeklyFree
        let h = min(max(0, a.hoursUntilWeeklyReset), 168)
        let urgencyMultiplier = 1 + (168 - h) / 168 * 2
        let sessionHealthFactor = min(a.sessionFree / 30, 1.0)
        return w * urgencyMultiplier * sessionHealthFactor
    }

    static func sortedExhaustedAccounts(_ accounts: [Account]) -> [Account] {
        accounts.sorted { compareExhausted($0, $1) }
    }

    private static func exhaustedPlanRank(_ account: Account) -> Int {
        if account.hasError { return 2 }
        if account.isFreePlan { return 1 }
        return 0
    }

    private static func compareExhausted(_ a: Account, _ b: Account) -> Bool {
        let planRankA = exhaustedPlanRank(a)
        let planRankB = exhaustedPlanRank(b)
        if planRankA != planRankB {
            return planRankA < planRankB
        }
        if a.nextWaitingResetSeconds != b.nextWaitingResetSeconds {
            return a.nextWaitingResetSeconds < b.nextWaitingResetSeconds
        }
        return a.email.localizedCaseInsensitiveCompare(b.email) == .orderedAscending
    }

    private static func compareSmart(_ a: Account, _ b: Account) -> Bool {
        let sa = smartScore(a), sb = smartScore(b)
        if sa != sb { return sa > sb }
        if a.sessionFree != b.sessionFree { return a.sessionFree > b.sessionFree }
        return a.weeklyFree > b.weeklyFree
    }

    private static func comparePriority(_ a: Account, _ b: Account) -> Bool {
        let ea = expiringScore(a), eb = expiringScore(b)
        if ea != eb { return ea > eb }
        return compareSmart(a, b)
    }

    /// Priority accounts with useful balance and weekly reset under 24 hours.
    var priorityAccounts: [Account] {
        let usable = searchFiltered.filter { $0.isUsableForCodex && $0.isWeeklyPriority }
        return usable.sorted { Self.comparePriority($0, $1) }
    }

    /// Active accounts not in the priority strip, sorted by smart score.
    var normalActiveAccounts: [Account] {
        let ids = Set(priorityAccounts.map(\.id))
        let usable = searchFiltered.filter { $0.isUsableForCodex && !ids.contains($0.id) }
        return usable.sorted { Self.compareSmart($0, $1) }
    }

    var exhaustedAccounts: [Account] {
        Self.sortedExhaustedAccounts(searchFiltered.filter { !$0.isUsableForCodex })
    }

    var nonFreeExhaustedAccounts: [Account] {
        Self.sortedExhaustedAccounts(searchFiltered.filter { !$0.isUsableForCodex && !$0.isFreeWaitingForReset })
    }

    var freeWaitingAccounts: [Account] {
        Self.sortedExhaustedAccounts(searchFiltered.filter(\.isFreeWaitingForReset))
    }

    var groupedPriorityAccounts: [(String, [Account])] {
        Self.groupByWorkspace(priorityAccounts)
    }

    var groupedNormalActiveAccounts: [(String, [Account])] {
        Self.groupByWorkspace(normalActiveAccounts)
    }

    var groupedExhaustedAccounts: [(String, [Account])] {
        Self.groupByWorkspace(nonFreeExhaustedAccounts)
    }

    var hasAnyAccount: Bool {
        !priorityAccounts.isEmpty || !normalActiveAccounts.isEmpty || !exhaustedAccounts.isEmpty
    }

    static func groupByWorkspace(_ accounts: [Account]) -> [(String, [Account])] {
        var order: [String] = []
        var map: [String: [Account]] = [:]
        for a in accounts {
            if map[a.workspace] == nil { order.append(a.workspace) }
            map[a.workspace, default: []].append(a)
        }
        return order.map { ($0, map[$0]!) }
    }

    var errorsCount: Int { Self.errorCount(in: accounts) }

    static func errorCount(in accounts: [Account]) -> Int {
        accounts.filter(\.hasError).count
    }

    // MARK: - Actions

    func refresh() {
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil

        guard !isLoading else {
            pendingRefreshAfterCurrent = true
            return
        }

        runRefresh()
    }

    private func runRefresh() {
        isLoading = true
        error = nil
        codexLoginStatus = CodexLoginStatusStore.load()
        refreshCodexAvailability()

        Task {
            let result = await service.loadAll()
            accounts = result
            let now = Date()
            lastRefresh = now
            AccountSnapshotStore.save(accounts: accounts, lastRefresh: now)
            codexLoginStatus = CodexLoginStatusStore.load()
            refreshCodexAvailability()
            evaluateAutoSwap()
            isLoading = false
            startTimer()
            if pendingRefreshAfterCurrent {
                pendingRefreshAfterCurrent = false
                refresh()
            }
        }
    }

    private func schedulePostCaptureRefresh() {
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingDebouncedRefreshTask = nil
            self.refresh()
        }
    }

    func needsRelogin(_ account: Account) -> Bool {
        !codexLoginStatus.contains(account)
            || UsageService.isExpiredOrRevokedAuthError(account.errorMessage)
    }

    func isRelogging(_ account: Account) -> Bool {
        reloggingAccountID == account.id
    }

    func isSwitchingToCodex(_ account: Account) -> Bool {
        switchingAccountID == account.id
    }

    func isActiveInCodex(_ account: Account) -> Bool {
        guard selectedSurfaceStatus?.detected == true else { return false }
        guard let activeCodexProfileKey = activeCodexProfileKey(for: selectedCodexSurface),
              let profileKey = account.profileKey else {
            return false
        }
        return activeCodexProfileKey == profileKey
    }

    var canShowDesktopSwitchControls: Bool {
        selectedCodexSurface == .desktop && isCodexInstalled
    }

    var availableCodexSurfaces: [CodexSurfaceStatus] {
        codexSurfaceStatuses.filter(\.detected)
    }

    var selectedSurfaceStatus: CodexSurfaceStatus? {
        availableCodexSurfaces.first { $0.kind == selectedCodexSurface }
            ?? availableCodexSurfaces.first
    }

    func selectCodexSurface(_ kind: CodexSurfaceKind) {
        guard availableCodexSurfaces.contains(where: { $0.kind == kind }) else { return }
        selectedCodexSurface = kind
    }

    func activeCodexProfileKey(for surface: CodexSurfaceKind) -> String? {
        codexSurfaceStatuses.first { $0.kind == surface }?.activeProfileKey
    }

    var hasPendingAccountAction: Bool {
        isAddingAccount
            || reloggingAccountID != nil
            || switchingAccountID != nil
            || removingAccountID != nil
            || autoSwapSwitchingSurface != nil
    }

    func addAccount() {
        guard !hasPendingAccountAction else { return }
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil
        isAddingAccount = true
        accountActionError = nil

        reloginTask = Task {
            do {
                _ = try await captureService.captureNewAccount()
                guard !Task.isCancelled else { return }
                codexLoginStatus = CodexLoginStatusStore.load()
                isAddingAccount = false
                reloginTask = nil
                schedulePostCaptureRefresh()
            } catch is CancellationError {
                isAddingAccount = false
                reloginTask = nil
                accountActionError = nil
            } catch {
                isAddingAccount = false
                reloginTask = nil
                accountActionError = error.localizedDescription
            }
        }
    }

    func relogin(_ account: Account) {
        guard !hasPendingAccountAction else { return }
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil
        reloggingAccountID = account.id
        accountActionError = nil

        reloginTask = Task {
            do {
                _ = try await captureService.captureAccount(for: account)
                guard !Task.isCancelled else { return }
                codexLoginStatus = CodexLoginStatusStore.load()
                reloggingAccountID = nil
                reloginTask = nil
                schedulePostCaptureRefresh()
            } catch is CancellationError {
                reloggingAccountID = nil
                reloginTask = nil
                accountActionError = nil
            } catch {
                reloggingAccountID = nil
                reloginTask = nil
                accountActionError = error.localizedDescription
            }
        }
    }

    func cancelRelogin() {
        reloginTask?.cancel()
        reloginTask = nil
        reloggingAccountID = nil
        isAddingAccount = false
        accountActionError = nil
    }

    func switchCodex(to account: Account) {
        guard selectedCodexSurface == .desktop,
              isCodexInstalled,
              !hasPendingAccountAction,
              !needsRelogin(account) else { return }
        switchingAccountID = account.id
        accountActionError = nil

        switchTask = Task.detached { [switchService] in
            do {
                let result = try switchService.switchToAccount(account)
                await MainActor.run {
                    self.activeCodexProfileKey = result.sourceProfileKey
                    self.refreshCodexAvailability()
                    self.switchingAccountID = nil
                    self.switchTask = nil
                }
            } catch {
                await MainActor.run {
                    self.switchingAccountID = nil
                    self.switchTask = nil
                    self.accountActionError = error.localizedDescription
                }
            }
        }
    }

    func isRemoving(_ account: Account) -> Bool {
        removingAccountID == account.id
    }

    func removeAccount(_ account: Account) {
        guard !hasPendingAccountAction else { return }
        removingAccountID = account.id
        accountActionError = nil

        Task.detached { [removalService] in
            do {
                _ = try removalService.remove(account)
                await MainActor.run {
                    self.removingAccountID = nil
                    self.codexLoginStatus = CodexLoginStatusStore.load()
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.removingAccountID = nil
                    self.accountActionError = error.localizedDescription
                }
            }
        }
    }

    func toggleListDensity() {
        listDensity = .compact
    }

    var resetTextScale: CGFloat {
        ResetTextScale.scale(for: resetTextScalePercent)
    }

    func setResetTextScale(percent: Int) {
        resetTextScalePercent = ResetTextScale.clampedPercent(percent)
    }

    func adjustResetTextScale(by delta: Int) {
        resetTextScalePercent = ResetTextScale.stepped(resetTextScalePercent, by: delta)
    }

    func toggleInformationMode() {
        informationMode = informationMode == .complete ? .focused : .complete
    }

    func toggleWaitingForResetCollapsed() {
        waitingForResetCollapsed.toggle()
    }

    func toggleFreeWaitingCollapsed() {
        freeWaitingCollapsed.toggle()
    }

    func toggleGroupByWorkspace() { groupByWorkspace.toggle() }

    func isAutoSwapEnabled(for surface: CodexSurfaceKind) -> Bool {
        autoSwapPolicy.isEnabled(for: surface.autoSwapKind)
    }

    func setAutoSwapEnabled(_ enabled: Bool, for surface: CodexSurfaceKind) {
        var nextPolicy = autoSwapPolicy
        nextPolicy.setEnabled(enabled, for: surface.autoSwapKind)
        do {
            try autoSwapPolicyStore.save(nextPolicy)
            autoSwapPolicy = nextPolicy
            refreshCodexAvailability()
            refresh()
        } catch {
            accountActionError = error.localizedDescription
        }
    }

    func autoSwapStatusText(for surface: CodexSurfaceKind) -> String {
        guard isAutoSwapEnabled(for: surface) else { return "off" }
        if autoSwapSwitchingSurface == surface { return "switching" }
        guard let decision = autoSwapDecisions[surface] else { return "armed" }
        switch decision.decision {
        case .noAction:
            return "armed"
        case .wouldSwitch:
            return "ready"
        case .switched:
            return "switched"
        case .blocked:
            return "blocked"
        case .error:
            return "error"
        }
    }

    // MARK: - Timer

    private func refreshCodexAvailability() {
        codexSurfaceStatuses = surfaceService.statuses()
        isCodexInstalled = codexSurfaceStatuses.contains { $0.kind == .desktop && $0.detected }
        activeCodexProfileKey = activeCodexProfileKey(for: .desktop)
        if !availableCodexSurfaces.contains(where: { $0.kind == selectedCodexSurface }),
           let firstSurface = availableCodexSurfaces.first?.kind {
            selectedCodexSurface = firstSurface
        }
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: nextRefreshInterval(), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func nextRefreshInterval() -> TimeInterval {
        let enabledActiveKeys = codexSurfaceStatuses
            .filter { autoSwapPolicy.isEnabled(for: $0.kind.autoSwapKind) }
            .compactMap(\.activeProfileKey)
        let activeAccounts = accounts.filter { account in
            guard let profileKey = account.profileKey else { return false }
            return enabledActiveKeys.contains(profileKey)
        }
        guard let lowestActiveFree = activeAccounts
            .map({ min($0.sessionFree, $0.weeklyFree) })
            .min() else {
            return 300
        }
        if lowestActiveFree <= 10 { return 15 }
        if lowestActiveFree <= 30 { return 60 }
        return 300
    }

    private func evaluateAutoSwap() {
        guard autoSwapSwitchingSurface == nil,
              !accounts.isEmpty else {
            return
        }
        let autoAccounts = accounts.compactMap {
            $0.autoSwapAccount(needsRelogin: needsRelogin($0))
        }
        let history = autoSwapAuditStore.load()
        var nextDecisions: [CodexSurfaceKind: AutoSwapDecision] = [:]

        for status in codexSurfaceStatuses {
            let decision = AutoSwapDecisionEngine.evaluate(
                policy: autoSwapPolicy,
                surface: status.autoSwapSurface,
                accounts: autoAccounts,
                history: history
            )
            if decision.decision == .wouldSwitch,
               status.hasRunningConsumer(in: codexSurfaceStatuses) {
                nextDecisions[status.kind] = AutoSwapDecision(
                    generatedAt: Date(),
                    surface: status.kind.autoSwapKind,
                    decision: .blocked,
                    reason: .consumersRunning,
                    activeProfileKey: decision.activeProfileKey,
                    candidateProfileKey: decision.candidateProfileKey,
                    triggerSessionFreePercent: decision.triggerSessionFreePercent,
                    triggerWeeklyFreePercent: decision.triggerWeeklyFreePercent,
                    targetMinSessionFreePercent: decision.targetMinSessionFreePercent
                )
                continue
            }
            nextDecisions[status.kind] = decision
            guard decision.decision == .wouldSwitch,
                  let candidateKey = decision.candidateProfileKey,
                  let candidate = accounts.first(where: { $0.profileKey == candidateKey }) else {
                continue
            }
            performAutoSwap(on: status.kind, to: candidate, planned: decision)
            break
        }

        autoSwapDecisions = nextDecisions
    }

    private func performAutoSwap(
        on surface: CodexSurfaceKind,
        to account: Account,
        planned: AutoSwapDecision
    ) {
        guard !hasPendingAccountAction,
              !needsRelogin(account) else {
            return
        }
        autoSwapSwitchingSurface = surface
        switchingAccountID = account.id
        accountActionError = nil

        switchTask = Task.detached { [switchService, autoSwapAuditStore] in
            do {
                let result: CodexSwitchResult
                switch surface {
                case .desktop:
                    result = try switchService.switchToAccount(account)
                case .cli:
                    result = try switchService.switchCLIToAccount(account)
                }
                let switched = AutoSwapDecision(
                    generatedAt: Date(),
                    surface: surface.autoSwapKind,
                    decision: .switched,
                    reason: .switched,
                    activeProfileKey: planned.activeProfileKey,
                    candidateProfileKey: planned.candidateProfileKey,
                    triggerSessionFreePercent: planned.triggerSessionFreePercent,
                    triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
                    targetMinSessionFreePercent: planned.targetMinSessionFreePercent
                )
                try? autoSwapAuditStore.record(AutoSwapAuditEvent(
                    generatedAt: switched.generatedAt,
                    surface: switched.surface,
                    decision: switched.decision,
                    reason: .thresholdReached,
                    fromProfileKey: switched.activeProfileKey,
                    toProfileKey: switched.candidateProfileKey
                ))
                await MainActor.run {
                    self.activeCodexProfileKey = result.sourceProfileKey
                    self.autoSwapDecisions[surface] = switched
                    self.refreshCodexAvailability()
                    self.switchingAccountID = nil
                    self.autoSwapSwitchingSurface = nil
                    self.switchTask = nil
                }
            } catch {
                await MainActor.run {
                    self.switchingAccountID = nil
                    self.autoSwapSwitchingSurface = nil
                    self.switchTask = nil
                    self.accountActionError = error.localizedDescription
                    self.autoSwapDecisions[surface] = AutoSwapDecision(
                        generatedAt: Date(),
                        surface: surface.autoSwapKind,
                        decision: .error,
                        reason: .thresholdReached,
                        activeProfileKey: planned.activeProfileKey,
                        candidateProfileKey: planned.candidateProfileKey,
                        triggerSessionFreePercent: planned.triggerSessionFreePercent,
                        triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
                        targetMinSessionFreePercent: planned.targetMinSessionFreePercent
                    )
                }
            }
        }
    }
}
