import SwiftUI
import AppKit

struct AccountListView: View {
    @ObservedObject var vm: UsageViewModel

    var body: some View {
        listBody
    }

    @ViewBuilder
    private var listBody: some View {
        VStack(spacing: 0) {
            if vm.groupByWorkspace {
                if !vm.priorityAccounts.isEmpty {
                    PrioritySeparatorHeader(count: vm.priorityAccounts.count)
                    ForEach(vm.groupedPriorityAccounts, id: \.0) { ws, accs in
                        SectionHeader(name: ws, count: accs.count)
                        rows(accs)
                    }
                }
                if !vm.normalActiveAccounts.isEmpty {
                    ForEach(vm.groupedNormalActiveAccounts, id: \.0) { ws, accs in
                        SectionHeader(name: ws, count: accs.count)
                        rows(accs)
                    }
                }
                if !vm.exhaustedAccounts.isEmpty {
                    waitingForResetGroup {
                        ForEach(vm.groupedExhaustedAccounts, id: \.0) { ws, accs in
                            SectionHeader(name: ws, count: accs.count)
                            rows(accs)
                        }
                        freeWaitingGroup
                    }
                }
            } else {
                if !vm.priorityAccounts.isEmpty {
                    PrioritySeparatorHeader(count: vm.priorityAccounts.count)
                    rows(vm.priorityAccounts)
                }
                if !vm.normalActiveAccounts.isEmpty {
                    rows(vm.normalActiveAccounts)
                }
                if !vm.exhaustedAccounts.isEmpty {
                    waitingForResetGroup {
                        rows(vm.nonFreeExhaustedAccounts)
                        freeWaitingGroup
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func waitingForResetGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = vm.waitingForResetCollapsed && vm.searchText.isEmpty
        ExhaustedSeparatorHeader(
            count: vm.exhaustedAccounts.count,
            isCollapsed: isCollapsed,
            toggle: { vm.toggleWaitingForResetCollapsed() }
        )
        if !isCollapsed {
            content()
        }
    }

    @ViewBuilder
    private var freeWaitingGroup: some View {
        if !vm.freeWaitingAccounts.isEmpty {
            let isCollapsed = vm.freeWaitingCollapsed && vm.searchText.isEmpty
            FreeWaitingGroupHeader(
                count: vm.freeWaitingAccounts.count,
                isCollapsed: isCollapsed,
                toggle: { vm.toggleFreeWaitingCollapsed() }
            )
            if !isCollapsed {
                rows(vm.freeWaitingAccounts)
            }
        }
    }

    @ViewBuilder
    private func rows(_ accs: [Account]) -> some View {
        ForEach(Array(accs.enumerated()), id: \.element.id) { i, acc in
            accountRow(for: acc)
            if i < accs.count - 1 {
                Divider().padding(.horizontal, 12).opacity(0.08)
            }
        }
    }

    @ViewBuilder
    private func accountRow(for acc: Account) -> some View {
        AccountCompactRow(
            account: acc,
            needsRelogin: vm.needsRelogin(acc),
            isRelogging: vm.isRelogging(acc),
            isReloginBlocked: vm.hasPendingAccountAction && !vm.isRelogging(acc),
            isSwitchingToCodex: vm.isSwitchingToCodex(acc),
            isActiveInCodex: vm.isActiveInCodex(acc),
            showsCodexControls: !vm.availableCodexSurfaces.isEmpty,
            isSwitchBlocked: vm.hasPendingAccountAction && !vm.isSwitchingToCodex(acc),
            isRemoving: vm.isRemoving(acc),
            isRemoveBlocked: vm.hasPendingAccountAction && !vm.isRemoving(acc),
            informationMode: vm.informationMode,
            resetTextScale: vm.resetTextScale,
            relogin: { vm.relogin(acc) },
            cancelRelogin: { vm.cancelRelogin() },
            switchToCodex: { vm.switchCodex(to: acc) },
            removeAccount: { vm.removeAccount(acc) }
        )
    }
}

// MARK: - Section Headers

struct SectionHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack {
            Text("\(name.uppercased()) (\(count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Color.primary.opacity(0.03))
    }
}

struct PrioritySeparatorHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(hex: "FF9F0A"))
            Text("PRIORITY (\(count))")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct ExhaustedSeparatorHeader: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("WAITING FOR RESET (\(count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.primary.opacity(0.03))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show waiting accounts" : "Hide waiting accounts")
    }
}

struct FreeWaitingGroupHeader: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Text("FREE (\(count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.primary.opacity(0.025))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show free accounts" : "Hide free accounts")
    }
}

// MARK: - Expanded Row

struct AccountRow: View {
    let account: Account
    @State private var hovered = false

    private var exhausted: Bool { account.isWeeklyExhausted }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(account.email)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                WorkspaceChip(ws: account.workspace, compact: false)
            }
            .opacity(exhausted ? 0.5 : 1)

            if !exhausted {
                BarRow(
                    label: "Session",
                    pct: account.sessionFree,
                    resetSeconds: account.sessionResetSeconds,
                    style: .normal,
                    urgentReset: false
                )
            }

            BarRow(
                label: "Weekly",
                pct: account.weeklyFree,
                resetSeconds: account.weeklyResetSeconds,
                style: exhausted ? .weeklyExhausted : .normal,
                urgentReset: account.isWeeklyResetUrgent
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, exhausted ? 6 : 8)
        .frame(maxWidth: .infinity, minHeight: exhausted ? 38 : 56, alignment: .leading)
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
        }
    }
}

// MARK: - Compact Row

enum CompactRowLayout {
    static let horizontalPadding: CGFloat = 12
    static let emailMinWidth: CGFloat = 160
    static let actionWidth: CGFloat = 96

    struct Metrics {
        let spacing: CGFloat
        let emailWidth: CGFloat
        let workspaceWidth: CGFloat
        let metricWidth: CGFloat
        let sessionResetWidth: CGFloat
        let weeklyResetWidth: CGFloat
        let planCycleWidth: CGFloat
        let actionWidth: CGFloat
    }

    static func metrics(
        totalWidth: CGFloat,
        showsFullInformation: Bool,
        showsActionControl: Bool,
        resetTextScale: CGFloat
    ) -> Metrics {
        let spacing: CGFloat = showsFullInformation ? 4 : 8
        let contentWidth = max(0, totalWidth - horizontalPadding * 2)
        let readableScale = min(max(resetTextScale, 0.8), 2)
        func fittingEmailWidth(after fixedWidth: CGFloat) -> CGFloat {
            let availableWidth = max(0, contentWidth - fixedWidth)
            return availableWidth < emailMinWidth ? availableWidth : max(emailMinWidth, availableWidth)
        }

        guard showsFullInformation else {
            let metricWidth: CGFloat = 66
            let freeResetWidth = ceil((metricWidth * 2 + spacing) * readableScale)
            let quotaFixedWidth = actionWidth + metricWidth * 2 + spacing * 4 + 16
            let freeResetFixedWidth = actionWidth + freeResetWidth + spacing * 3 + 16
            let fixedWidth = max(quotaFixedWidth, freeResetFixedWidth)
            return Metrics(
                spacing: spacing,
                emailWidth: fittingEmailWidth(after: fixedWidth),
                workspaceWidth: 0,
                metricWidth: metricWidth,
                sessionResetWidth: 0,
                weeklyResetWidth: 0,
                planCycleWidth: 0,
                actionWidth: actionWidth
            )
        }

        let workspaceWidth = min(64, max(44, contentWidth * 0.11))
        let metricWidth = min(66, max(58, contentWidth * 0.11))
        let sessionResetWidth: CGFloat = ceil(34 * readableScale)
        let weeklyResetWidth: CGFloat = ceil(64 * readableScale)
        let planCycleWidth: CGFloat = ceil(32 * readableScale)
        let swapControlWidth: CGFloat = actionWidth
        let quotaFixedWidth = 16
            + workspaceWidth
            + swapControlWidth
            + metricWidth * 2
            + sessionResetWidth
            + weeklyResetWidth
            + planCycleWidth
            + spacing * 6
        let freeResetWidth = metricWidth * 2 + sessionResetWidth + weeklyResetWidth + planCycleWidth + spacing * 2 + 4
        let freeResetFixedWidth = 16
            + workspaceWidth
            + swapControlWidth
            + freeResetWidth
            + spacing * 4
        let fixedWidth = max(quotaFixedWidth, freeResetFixedWidth)

        return Metrics(
            spacing: spacing,
            emailWidth: fittingEmailWidth(after: fixedWidth),
            workspaceWidth: workspaceWidth,
            metricWidth: metricWidth,
            sessionResetWidth: sessionResetWidth,
            weeklyResetWidth: weeklyResetWidth,
            planCycleWidth: planCycleWidth,
            actionWidth: swapControlWidth
        )
    }
}

struct AccountCompactRow: View {
    let account: Account
    let needsRelogin: Bool
    let isRelogging: Bool
    let isReloginBlocked: Bool
    let isSwitchingToCodex: Bool
    let isActiveInCodex: Bool
    let showsCodexControls: Bool
    let isSwitchBlocked: Bool
    let isRemoving: Bool
    let isRemoveBlocked: Bool
    let informationMode: AccountInformationMode
    let resetTextScale: CGFloat
    let relogin: () -> Void
    let cancelRelogin: () -> Void
    let switchToCodex: () -> Void
    let removeAccount: () -> Void
    @State private var hovered = false

    private var exhausted: Bool { account.isWeeklyExhausted }
    private var showsFullInformation: Bool { informationMode == .complete }
    private var showsActionControl: Bool { needsRelogin || isRelogging || isSwitchingToCodex || canShowSwapControl }
    private var resetFontSize: CGFloat { 10 * resetTextScale }
    private var rowHeight: CGFloat { ceil((showsFullInformation ? 34 : 28) * max(1, min(resetTextScale, 1.6))) }
    private var canShowSwapControl: Bool {
        showsCodexControls
            && !isActiveInCodex
            && !needsRelogin
            && !isRelogging
            && account.isUsableForCodex
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = CompactRowLayout.metrics(
                totalWidth: proxy.size.width,
                showsFullInformation: showsFullInformation,
                showsActionControl: showsActionControl,
                resetTextScale: resetTextScale
            )
            let resetWidthScale = max(1, min(resetTextScale, 2))
            let freeResetWidth = showsFullInformation
                ? layout.metricWidth * 2 + layout.sessionResetWidth + layout.weeklyResetWidth + layout.planCycleWidth + layout.spacing * 2 + 4
                : ceil((layout.metricWidth * 2 + layout.spacing) * resetWidthScale)
            HStack(alignment: .center, spacing: layout.spacing) {
                leadingAccountControl

                Text(account.email)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: layout.emailWidth, alignment: .leading)

                if showsFullInformation {
                    WorkspaceChip(ws: account.workspace, compact: true)
                        .frame(width: layout.workspaceWidth, alignment: .leading)
                }

                if account.isFreeWaitingForReset {
                    if showsFullInformation {
                        accountActionControl(width: layout.actionWidth)
                        freeResetStatus(width: freeResetWidth, alignment: .leading)
                    } else if showsActionControl {
                        accountActionControl(width: layout.actionWidth)
                        freeResetStatus(width: freeResetWidth, alignment: .trailing)
                    } else {
                        freeResetStatus(width: layout.actionWidth + layout.spacing + freeResetWidth, alignment: .trailing)
                    }
                } else {
                    accountActionControl(width: layout.actionWidth)

                    if showsFullInformation {
                        sessionMetricGroup(layout: layout)
                        weeklyMetricGroup(layout: layout)
                        planCycleText(width: layout.planCycleWidth)
                    } else if account.hasError {
                        compactErrorStatus(width: layout.metricWidth * 2 + layout.spacing)
                    } else {
                        Group {
                            if !exhausted {
                                compactQuota(label: "S", pct: account.sessionFree, gray: false, width: layout.metricWidth)
                            } else {
                                Color.clear.frame(width: layout.metricWidth, height: 1)
                            }
                        }
                        .opacity(exhausted ? 0.5 : 1)

                        compactQuota(label: "W", pct: account.weeklyFree, gray: exhausted, width: layout.metricWidth)
                            .opacity(exhausted ? 0.5 : 1)
                    }
                }
            }
            .padding(.horizontal, CompactRowLayout.horizontalPadding)
            .padding(.vertical, showsFullInformation ? 7 : 5)
            .frame(width: proxy.size.width, height: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(height: rowHeight)
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var leadingAccountControl: some View {
        Group {
            if showsCodexControls && isActiveInCodex {
                CodexIconView()
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Color(hex: "30D158"))
                            .background(Circle().fill(.black.opacity(0.72)))
                    }
                    .help("Active in Codex")
            } else if isRemoving {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else if hovered {
                Button(action: removeAccount) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .disabled(isRemoveBlocked)
                .help("Remove from list")
            } else {
                Color.clear.frame(width: 5, height: 5)
            }
        }
        .frame(width: 16, height: 18)
    }

    @ViewBuilder
    private func sessionMetricGroup(layout: CompactRowLayout.Metrics) -> some View {
        HStack(spacing: 2) {
            Group {
                if !exhausted {
                    compactQuota(label: "S", pct: account.sessionFree, gray: false, width: layout.metricWidth)
                } else {
                    Color.clear.frame(width: layout.metricWidth, height: 1)
                }
            }
            .opacity(exhausted ? 0.5 : 1)

            sessionResetText(width: layout.sessionResetWidth)
        }
    }

    @ViewBuilder
    private func weeklyMetricGroup(layout: CompactRowLayout.Metrics) -> some View {
        HStack(spacing: 2) {
            compactQuota(label: "W", pct: account.weeklyFree, gray: exhausted, width: layout.metricWidth)
                .opacity(exhausted ? 0.5 : 1)

            weeklyResetText(width: layout.weeklyResetWidth)
        }
    }

    @ViewBuilder
    private func sessionResetText(width: CGFloat) -> some View {
        Group {
            if exhausted {
                Color.clear.frame(width: width, height: 1)
            } else {
                Text(ResetFormatter.timeOnly(seconds: account.sessionResetSeconds))
                    .font(.system(size: resetFontSize))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: width, alignment: .trailing)
                    .help(ResetFormatter.fullTooltip(seconds: account.sessionResetSeconds))
            }
        }
    }

    @ViewBuilder
    private func planCycleText(width: CGFloat) -> some View {
        Group {
            if let text = PlanCycleFormatter.daysText(for: account),
               let date = account.planRenewalDate {
                Text(text)
                    .font(.system(size: resetFontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Color(hex: "FF453A"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: width, alignment: .trailing)
                    .help(PlanCycleFormatter.tooltip(for: date))
            } else {
                Color.clear.frame(width: width, height: 1)
            }
        }
    }

    private func weeklyResetText(width: CGFloat) -> some View {
        HStack(spacing: 3) {
            if account.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color(hex: "FF453A"))
            } else if account.isWeeklyResetUrgent && !exhausted {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "FF9F0A"))
            }
            Text(weeklyStatusText)
                .font(.system(size: resetFontSize))
                .foregroundColor(weeklyStatusColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(width: width, alignment: .trailing)
        .multilineTextAlignment(.trailing)
        .help(account.hasError ? (account.errorMessage ?? "Invalid account") : ResetFormatter.fullTooltip(seconds: account.weeklyResetSeconds))
    }

    private var weeklyStatusText: String {
        if account.hasError {
            return account.errorMessage ?? "invalid"
        }
        return exhausted ? ResetFormatter.formatReset(seconds: account.weeklyResetSeconds) : ResetFormatter.format(seconds: account.weeklyResetSeconds)
    }

    private var weeklyStatusColor: Color {
        if account.hasError { return Color(hex: "FF453A") }
        return account.isWeeklyResetUrgent && !exhausted ? Color(hex: "FF9F0A") : .secondary
    }

    @ViewBuilder
    private func accountActionControl(width: CGFloat) -> some View {
        Group {
            if isRelogging {
                Button(action: cancelRelogin) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else if needsRelogin {
                ReloginAccountButton(action: relogin)
                .disabled(isReloginBlocked)
            } else if isSwitchingToCodex {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            } else if canShowSwapControl {
                SwitchAccountButton(action: switchToCodex)
                    .disabled(isSwitchBlocked)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            } else {
                Color.clear.frame(width: width, height: 1)
            }
        }
        .frame(width: width, height: 18)
    }
}

struct ReloginAccountButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 8, weight: .semibold))
                Text("Re-login")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color(hex: "FF9F0A").opacity(hovered ? 1 : 0.88))
            .frame(width: 86, height: 18)
            .background(hovered ? .thinMaterial : .ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(hex: "FF9F0A").opacity(hovered ? 0.36 : 0.22), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Re-login")
    }
}

struct SwitchAccountButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8, weight: .semibold))
                Text("Use in Codex")
                    .font(.system(size: 9, weight: .semibold))
            }
                .foregroundStyle(.primary.opacity(hovered ? 0.92 : 0.78))
                .frame(width: 86, height: 18)
                .background(hovered ? .thinMaterial : .ultraThinMaterial)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(hovered ? 0.26 : 0.14), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Use in Codex")
    }
}

struct CodexIconView: View {
    private static let image: NSImage = {
        let codexPNG = Bundle.main.url(forResource: "codex", withExtension: "png")
        let image = codexPNG.flatMap { NSImage(contentsOf: $0) }
            ?? NSWorkspace.shared.icon(forFile: "/Applications/Codex.app")
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(.primary.opacity(0.82))
            .frame(width: 16, height: 16)
    }
}

private extension AccountCompactRow {
    func freeResetStatus(width: CGFloat, alignment: Alignment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Free resets \(ResetFormatter.formatFreeReturn(seconds: account.freePlanResetSeconds))")
                .font(.system(size: resetFontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: width, alignment: alignment)
        .help("Free quota resets \(ResetFormatter.fullTooltip(seconds: account.freePlanResetSeconds))")
    }

    func compactErrorStatus(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Color(hex: "FF453A"))
            Text(account.errorMessage ?? "Invalid account")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "FF453A"))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: width, alignment: .trailing)
        .help(account.errorMessage ?? "Invalid account")
    }

    func compactQuota(label: String, pct: Double, gray: Bool, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 7, alignment: .leading)
            MiniBar(
                pct: pct,
                fill: gray ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct)
            )
            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(gray ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 24, alignment: .trailing)
        }
        .frame(width: width, alignment: .leading)
    }
}

struct MiniBar: View {
    let pct: Double
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 3)
                if pct > 0.001 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fill)
                        .frame(width: max(2, geo.size.width * pct / 100), height: 3)
                }
            }
        }
        .frame(width: 25, height: 3)
    }
}

// MARK: - Workspace Chip

struct WorkspaceChip: View {
    let ws: String
    var compact: Bool = false

    var body: some View {
        Text(ws)
            .font(.system(size: compact ? 9 : 11, weight: .medium))
            .foregroundColor(Theme.workspaceTextColor(for: ws))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(Theme.workspaceColor(for: ws))
            .cornerRadius(4)
    }
}

// MARK: - Horizontal Bar Row

enum BarRowStyle {
    case normal
    case weeklyExhausted
}

struct BarRow: View {
    let label: String
    let pct: Double
    let resetSeconds: Double
    let style: BarRowStyle
    let urgentReset: Bool

    var body: some View {
        let dimmed = style == .weeklyExhausted
        let fillColor: Color = dimmed ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct)

        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)
                .opacity(dimmed ? 0.5 : 1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 4)
                    if pct > 0.001 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fillColor)
                            .frame(width: max(4, geo.size.width * pct / 100), height: 4)
                    }
                }
            }
            .frame(height: 4)
            .opacity(dimmed ? 0.5 : 1)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 38, alignment: .trailing)
                .opacity(dimmed ? 0.5 : 1)

            Text("·")
                .foregroundColor(.secondary.opacity(0.5))
                .opacity(dimmed ? 0.5 : 1)

            HStack(spacing: 4) {
                if urgentReset && !dimmed {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "FF9F0A"))
                }
                Text(dimmed ? ResetFormatter.formatReset(seconds: resetSeconds) : ResetFormatter.format(seconds: resetSeconds))
                    .font(.system(size: 11))
                    .foregroundColor(urgentReset && !dimmed ? Color(hex: "FF9F0A") : .secondary)
                    .help(ResetFormatter.fullTooltip(seconds: resetSeconds))
            }
        }
        .frame(height: 14)
    }
}
