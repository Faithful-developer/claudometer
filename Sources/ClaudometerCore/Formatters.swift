import Foundation

public enum Formatters {
    /// "2h 14m", "45m", "3d 4h", "<1m".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if minutes < 1 { return "<1m" }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// "Resets in 2h 14m" when under 24h, otherwise "Resets Fri 09:00".
    public static func resetText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "Not started" }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "Resetting…" }
        if remaining < 24 * 3600 { return "Resets in \(duration(remaining))" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return "Resets \(formatter.string(from: date))"
    }

    /// Short countdown for tight spaces: "2h 14m" or "Fri 09:00".
    public static func shortReset(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let text = resetText(date, now: now, calendar: calendar, locale: locale)
        if text.hasPrefix("Resets in ") { return "in " + text.dropFirst("Resets in ".count) }
        if text.hasPrefix("Resets ") { return String(text.dropFirst("Resets ".count)) }
        return text
    }

    /// "42%", clamped at 0. Over the limit reads "100%+" rather than a figure above 100.
    public static func percent(_ value: Double) -> String {
        if value > 100 { return "100%+" }
        return "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    /// "Updated just now" / "Updated 3 min ago" / "Updated 14:05".
    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return "Updated \(formatter.string(from: date))"
    }

    public static func planName(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// VoiceOver description of a window: title, percent, level, reset.
    /// "Session (5h), 91 percent used, near limit, Resets in 2h 40m".
    public static func accessibilityLabel(_ window: LimitWindow, level: UsageLevel = .ok, stale: Bool = false, now: Date = Date()) -> String {
        var parts = [window.title, "\(Int(min(max(window.utilization, 0), 999).rounded())) percent used"]
        if let label = levelLabel(level) { parts.append(stale ? "last known \(label)" : label) }
        parts.append(stale ? "out of date" : resetText(window.resetsAt, now: now))
        return parts.joined(separator: ", ")
    }

    /// Spoken/short form of a level: "near limit", "getting close".
    public static func levelLabel(_ level: UsageLevel) -> String? {
        switch level {
        case .critical: return "near limit"
        case .warning: return "getting close"
        case .ok, .unknown: return nil
        }
    }

    /// "Out of date · 14:05" for stale data.
    public static func outOfDateText(_ fetched: Date) -> String {
        "Out of date · \(fetched.formatted(date: .omitted, time: .shortened))"
    }
}

/// Traffic-light level for a utilization value.
public enum UsageLevel: String, Sendable {
    case ok, warning, critical, unknown

    public static func of(_ utilization: Double?, warning: Double = 60, critical: Double = 85) -> UsageLevel {
        guard let utilization else { return .unknown }
        if utilization >= critical { return .critical }
        if utilization >= warning { return .warning }
        return .ok
    }
}
