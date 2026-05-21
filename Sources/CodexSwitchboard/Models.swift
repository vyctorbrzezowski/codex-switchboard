import AppKit
import SwiftUI

// MARK: - Account

struct Account: Identifiable, Equatable, Codable {
    let id: String          // dedup key: "email|accountId"
    let profileKey: String?
    let email: String
    let workspace: String   // team name or plan type
    let plan: String
    let sessionFree: Double // 0-100 (% remaining)
    let weeklyFree: Double
    let sessionResetSeconds: Double
    let weeklyResetSeconds: Double
    var planRenewalDate: Date?
    let hasError: Bool
    let errorMessage: String?

    var emailPrefix: String {
        email.components(separatedBy: "@").first ?? email
    }

    var accountID: String {
        let pieces = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return "" }
        return String(pieces[1])
    }

    /// Weekly quota fully used; session line is hidden and cell uses exhausted styling.
    var isWeeklyExhausted: Bool { hasError || weeklyFree <= 0.001 }

    var isFreePlan: Bool {
        plan.codexSwitchboardNormalized == "free"
    }

    var isFreeWaitingForReset: Bool {
        !hasError
            && isFreePlan
            && sessionFree <= 0.001
            && weeklyFree > 0.001
            && freePlanResetSeconds > 0
    }

    var freePlanResetSeconds: Double {
        if sessionResetSeconds > 0 { return sessionResetSeconds }
        return weeklyResetSeconds
    }

    var nextWaitingResetSeconds: Double {
        if sessionFree <= 0.001, sessionResetSeconds > 0 {
            return sessionResetSeconds
        }
        if weeklyFree <= 0.001, weeklyResetSeconds > 0 {
            return weeklyResetSeconds
        }
        if weeklyResetSeconds > 0 {
            return weeklyResetSeconds
        }
        if sessionResetSeconds > 0 {
            return sessionResetSeconds
        }
        return Double.greatestFiniteMagnitude
    }

    var isUsableForCodex: Bool {
        !hasError && sessionFree > 0.001 && weeklyFree > 0.001
    }

    /// Hours until weekly window resets (from API `reset_after_seconds`).
    var hoursUntilWeeklyReset: Double { max(0, weeklyResetSeconds / 3600) }

    /// Highlight reset text when meaningful balance expires soon.
    var isWeeklyResetUrgent: Bool {
        isUsableForCodex && weeklyFree >= 20 && hoursUntilWeeklyReset < 12
    }

    /// Top priority strip: useful balance that resets in less than 24 hours.
    var isWeeklyPriority: Bool {
        isUsableForCodex && sessionFree >= 20 && weeklyFree >= 20 && hoursUntilWeeklyReset < 24
    }

    var planDaysRemaining: Int? {
        guard let planRenewalDate else { return nil }
        return max(0, Int(ceil(planRenewalDate.timeIntervalSinceNow / 86_400)))
    }
}

// MARK: - Enums

enum ListDensity: String {
    case expanded
    case compact
}

enum AccountInformationMode: String {
    case complete
    case focused
}

extension String {
    fileprivate var codexSwitchboardNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isGenericWorkspaceName: Bool {
        let trimmed = codexSwitchboardNormalized
        return trimmed == "team" || trimmed == "plus" || trimmed == "pro" || trimmed == "free" || trimmed == "?"
    }

    var isPersonalPlanType: Bool {
        let trimmed = codexSwitchboardNormalized
        return trimmed == "plus" || trimmed == "pro" || trimmed == "free" || trimmed == "personal" || trimmed == "individual"
    }

    var isUnknownPlanType: Bool {
        let trimmed = codexSwitchboardNormalized
        return trimmed.isEmpty || trimmed == "?"
    }

    var isLikelyPersonalAccountID: Bool {
        codexSwitchboardNormalized.hasPrefix("user-")
    }
}

// MARK: - Theme

struct Theme {
    /// Bar fill color based on % free remaining.
    static func barColor(for pct: Double) -> Color {
        switch pct {
        case 50...:       return Color(hex: "30D158")   // green
        case 20..<50:     return Color(lightHex: "8A6A00", darkHex: "FFD60A")   // yellow
        case 5..<20:      return Color(hex: "FF9F0A")   // orange
        case 0.001..<5:   return Color(hex: "FF453A")   // red
        default:          return Color(hex: "8E8E93")   // gray (0 %)
        }
    }

    /// Weekly bar when quota is exhausted: neutral gray, not alert red.
    static let weeklyExhaustedBar = Color(hex: "8E8E93")

    /// Workspace chip background.
    static func workspaceColor(for ws: String) -> Color {
        let stableIndex = ws.lowercased().unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        switch stableIndex % 6 {
        case 0: return Color(hex: "5F80A8")
        case 1: return Color(hex: "6F9277")
        case 2: return Color(hex: "8A6F9B")
        case 3: return Color(hex: "A7666E")
        case 4: return Color(hex: "AF8158")
        default: return Color(hex: "7871A6")
        }
    }

    /// Workspace chip text (black or white for contrast).
    static func workspaceTextColor(for ws: String) -> Color {
        Color.white.opacity(0.96)
    }
}

// MARK: - Color Helper

extension Color {
    init(lightHex: String, darkHex: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex)
        })
    }

    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let r, g, b, a: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, n >> 16, n >> 8 & 0xFF, n & 0xFF)
        case 8: (a, r, g, b) = (n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:     Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let r, g, b, a: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, n >> 16, n >> 8 & 0xFF, n & 0xFF)
        case 8: (a, r, g, b) = (n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(srgbRed: Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  alpha:   Double(a) / 255)
    }
}

// MARK: - Reset Formatter

struct ResetFormatter {
    private static let weekdaysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Weekly exhausted row: "resets Wed 18:19" because reset is the only actionable info.
    static func formatReset(seconds: Double) -> String {
        let inner = format(seconds: seconds)
        if inner == "now" { return "resets now" }
        return "resets \(inner)"
    }

    /// Short context-aware string.
    static func format(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t   = hhmm(tgt)
        if cal.isDateInToday(tgt) { return t }
        if cal.isDateInTomorrow(tgt) { return "tomorrow \(t)" }
        if isSameWeekStartingSunday(now, tgt) {
            let wd = cal.component(.weekday, from: tgt)
            return "\(weekdaysShort[wd - 1]) \(t)"
        }
        return dateTimeString(target: tgt, now: now, time: t)
    }

    static func formatFreeReturn(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t = hhmm(tgt)
        if cal.isDateInToday(tgt) { return "today \(t)" }
        if cal.isDateInTomorrow(tgt) { return "tomorrow \(t)" }
        return dateTimeString(target: tgt, now: now, time: t)
    }

    static func timeOnly(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        return hhmm(Date().addingTimeInterval(seconds))
    }

    private static func startOfWeekSunday(containing date: Date) -> Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: dayStart)
        return cal.date(byAdding: .day, value: -(weekday - 1), to: dayStart) ?? dayStart
    }

    private static func isSameWeekStartingSunday(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        let sa = startOfWeekSunday(containing: a)
        let sb = startOfWeekSunday(containing: b)
        return cal.isDate(sa, inSameDayAs: sb)
    }

    private static func dateTimeString(target: Date, now: Date, time: String) -> String {
        "\(dateString(target: target, now: now)) \(time)"
    }

    private static func dateString(target: Date, now: Date) -> String {
        let cal = Calendar.current
        let d = cal.component(.day, from: target)
        let m = cal.component(.month, from: target)
        let y = cal.component(.year, from: target)
        let yNow = cal.component(.year, from: now)
        if y == yNow {
            return String(format: "%02d/%02d", d, m)
        }
        return String(format: "%02d/%02d/%d", d, m, y)
    }

    /// Full tooltip string.
    static func fullTooltip(seconds: Double) -> String {
        guard seconds > 0 else { return "Now" }
        let tgt = Date().addingTimeInterval(seconds)
        return tooltipFormatter.string(from: tgt)
    }

    static func fullTooltip(date: Date) -> String {
        tooltipFormatter.string(from: date)
    }

    private static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d 'at' HH:mm"
        return f
    }()
}

struct PlanCycleFormatter {
    static func daysText(for account: Account) -> String? {
        guard let days = account.planDaysRemaining else { return nil }
        return "\(days)D"
    }

    static func tooltip(for date: Date) -> String {
        "Plan renews \(ResetFormatter.fullTooltip(date: date))"
    }
}
