import Foundation

public enum Formatters {
    /// "2h 14m", "45m", "3d 4h", "<1m".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if minutes < 1 { return tr("<1m") }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? tr("%lldd %lldh", days, hours) : tr("%lldd", days) }
        if hours > 0 { return mins > 0 ? tr("%lldh %lldm", hours, mins) : tr("%lldh", hours) }
        return tr("%lldm", mins)
    }

    /// When a window resets, in words; `resetText` and `shortReset` phrase it differently.
    enum ResetPhrase {
        case notStarted
        case resetting
        case within(TimeInterval)
        case on(String)
    }

    static func resetPhrase(_ date: Date?, now: Date, calendar: Calendar, locale: Locale) -> ResetPhrase {
        guard let date else { return .notStarted }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return .resetting }
        if remaining < 24 * 3600 { return .within(remaining) }
        return .on(weekdayTime(date, calendar: calendar, locale: locale))
    }

    /// "Fri 09:00", for use mid-sentence; Russian writes day names in lowercase there.
    static func weekdayTime(_ date: Date, calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        let day = formatter.string(from: date)
        return locale.language.languageCode == .russian ? day.lowercased(with: locale) : day
    }

    /// "At this pace: limit at 16:40", or "… limit at Fri 09:00" when it's not today.
    public static func forecastText(_ limit: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = calendar.isDate(limit, inSameDayAs: now) ? time(limit) : weekdayTime(limit, calendar: calendar)
        return tr("At this pace: limit at %@", when)
    }

    /// "Resets in 2h 14m" when under 24h, otherwise "Resets Fri 09:00".
    public static func resetText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        switch resetPhrase(date, now: now, calendar: calendar, locale: locale) {
        case .notStarted: return tr("Not started")
        case .resetting: return tr("Resetting…")
        case .within(let remaining): return tr("Resets in %@", duration(remaining))
        case .on(let day): return tr("Resets %@", day)
        }
    }

    /// Short countdown for tight spaces: "in 2h 14m" or "Fri 09:00".
    public static func shortReset(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        switch resetPhrase(date, now: now, calendar: calendar, locale: locale) {
        case .within(let remaining): return tr("in %@", duration(remaining))
        case .on(let day): return day
        case .notStarted, .resetting: return resetText(date, now: now, calendar: calendar, locale: locale)
        }
    }

    /// "42%", clamped at 0. Over the limit reads "100%+" rather than a figure above 100.
    public static func percent(_ value: Double) -> String {
        if value > 100 { return tr("100%+") }
        return tr("%lld%%", Int(min(max(value, 0), 100).rounded()))
    }

    /// "Updated just now" / "Updated 3 min ago" / "Updated 14:05".
    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return tr("Updated just now") }
        if seconds < 3600 { return tr("Updated %lld min ago", Int(seconds / 60)) }
        return tr("Updated %@", timestamp(date, now: now))
    }

    /// "14:05" today, otherwise with the date: "10/10/26, 14:05".
    static func timestamp(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .short
        return formatter.string(from: date)
    }

    /// Time of day in the UI language: "14:05".
    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
    }

    public static func planName(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// VoiceOver description of a window: title, percent, level, reset.
    /// "Session (5h), 91 percent used, near limit, Resets in 2h 40m".
    public static func accessibilityLabel(_ window: LimitWindow, level: UsageLevel = .ok, stale: Bool = false, now: Date = Date()) -> String {
        var parts = [window.title, tr("%lld percent used", Int(min(max(window.utilization, 0), 999).rounded()))]
        if let label = levelLabel(level) { parts.append(stale ? tr("last known %@", label) : label) }
        parts.append(stale ? tr("out of date") : resetText(window.resetsAt, now: now))
        return parts.joined(separator: ", ")
    }

    /// Spoken/short form of a level: "near limit", "getting close".
    public static func levelLabel(_ level: UsageLevel) -> String? {
        switch level {
        case .critical: return tr("near limit")
        case .warning: return tr("getting close")
        case .ok, .unknown: return nil
        }
    }

    /// "Showing data from 14:05" / "Showing data from 10/10/26, 14:05" for stale data.
    public static func dataFromText(_ fetched: Date, now: Date = Date()) -> String {
        tr("Showing data from %@", timestamp(fetched, now: now))
    }

    /// "Out of date · 14:05" for stale data.
    public static func outOfDateText(_ fetched: Date) -> String {
        tr("Out of date · %@", time(fetched))
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
