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

    static func resetPhrase(_ date: Date?, now: Date, calendar: Calendar, locale: Locale, style: DayStyle = .inline) -> ResetPhrase {
        guard let date else { return .notStarted }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return .resetting }
        if remaining < 24 * 3600 { return .within(remaining) }
        return .on(dayTime(date, now: now, calendar: calendar, locale: locale, style: style))
    }

    /// How a day and time are worded where they appear.
    public enum DayStyle: Sendable {
        /// Mid-sentence: "tomorrow 09:00"; Russian day names in lowercase.
        case inline
        /// Starting a label: "Tomorrow 09:00".
        case label
        /// The copy card, where a long phrase squeezes the limit's name: "Sat 09:00" for
        /// tomorrow, and the date without the weekday a week out ("4 Dec, 09:00").
        case compact
    }

    /// Which day a future time falls on, by calendar day rather than 24-hour steps, so "tomorrow"
    /// is the next date, not "within 48 h".
    enum Day {
        case today, tomorrow, thisWeek
        /// Six or more days out: the weekday alone would read as today's, or nearly.
        case weekAhead
    }

    static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .tomorrow
        case 2...5: return .thisWeek
        default: return .weekAhead
        }
    }

    /// "16:40" today, "tomorrow 9:00", "Fri 9:00", or "Fri 4 Dec, 9:00" six or more days out,
    /// where "Fri" alone could mean today. The time is `time(_:)`'s own, so it keeps the same
    /// 12/24-hour clock (a template here forced 24-hour). See `DayStyle` for the variants.
    static func dayTime(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = L10n.locale,
                        style: DayStyle = .inline) -> String {
        let clock = time(date, calendar: calendar, locale: locale)
        let text: String
        switch (day(of: date, now: now, calendar: calendar), style) {
        case (.today, _): text = clock
        case (.tomorrow, .inline), (.tomorrow, .label): text = tr("tomorrow %@", clock)
        case (.tomorrow, .compact), (.thisWeek, _):
            text = dayName(date, template: "EEE", calendar: calendar, locale: locale) + " " + clock
        case (.weekAhead, .compact): text = dayName(date, template: "dMMM", calendar: calendar, locale: locale) + ", " + clock
        case (.weekAhead, _): text = dayName(date, template: "EEEdMMM", calendar: calendar, locale: locale) + ", " + clock
        }
        guard style == .label, let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "Fri" / "Fri 4 Dec" in the locale's order; Russian in lowercase ("пт, 4 дек."). Only the
    /// day part is lowercased, so a 12-hour "PM" stays as `time(_:)` writes it.
    private static func dayName(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        let day = formatter.string(from: date)
        return locale.language.languageCode == .russian ? day.lowercased(with: locale) : day
    }

    /// "At this pace: limit at 16:40", "… limit tomorrow at 09:00" or "… limit at Fri 09:00".
    /// A no-break space keeps the time with "at", so a wrap never leaves it alone.
    public static func forecastText(_ limit: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        if day(of: limit, now: now, calendar: calendar) == .tomorrow {
            // Its own phrase: "limit at tomorrow 09:00" reads badly.
            return tr("At this pace: limit tomorrow at %@", time(limit, calendar: calendar, locale: locale))
        }
        return tr("At this pace: limit at %@", dayTime(limit, now: now, calendar: calendar, locale: locale))
    }

    /// "Resets in 2h 14m" when under 24h, otherwise "Resets tomorrow 15:00" / "Resets Fri 09:00".
    public static func resetText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        switch resetPhrase(date, now: now, calendar: calendar, locale: locale) {
        case .notStarted: return tr("Not started")
        case .resetting: return tr("Resetting…")
        case .within(let remaining): return tr("Resets in %@", duration(remaining))
        case .on(let day): return tr("Resets %@", day)
        }
    }

    /// Short countdown for tight spaces: "in 2h 14m" or "tomorrow 9:00", worded for where it
    /// sits (`DayStyle`).
    public static func shortReset(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale,
                                  style: DayStyle = .inline) -> String {
        switch resetPhrase(date, now: now, calendar: calendar, locale: locale, style: style) {
        case .within(let remaining): return tr("in %@", duration(remaining))
        case .on(let day): return day
        case .notStarted, .resetting: return resetText(date, now: now, calendar: calendar, locale: locale)
        }
    }

    /// Right-hand text of a copy-card row: "68% · resets Fri 21:53" (compact wording, so the
    /// limit's name isn't cut), or "0% · Not started" / "92% · Resetting…" when there's no
    /// countdown ("resets Not started" read wrong).
    public static func cardDetail(_ window: LimitWindow, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let used = percent(window.utilization)
        switch resetPhrase(window.resetsAt, now: now, calendar: calendar, locale: locale) {
        case .notStarted, .resetting:
            return tr("%@ · %@", used, resetText(window.resetsAt, now: now, calendar: calendar, locale: locale))
        case .within, .on:
            return tr("%@ · resets %@", used, shortReset(window.resetsAt, now: now, calendar: calendar, locale: locale, style: .compact))
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
        time(date, calendar: .current, locale: L10n.locale)
    }

    static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    public static func planName(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// VoiceOver description of a window: title, percent, level, reset, then the pace and
    /// forecast lines the row shows. "Session (5h), 91 percent used, near limit, Resets in 2h 40m".
    /// Pace is read only where the status pill shows it: live data at a normal level.
    public static func accessibilityLabel(_ window: LimitWindow, level: UsageLevel = .ok, stale: Bool = false, now: Date = Date(),
                                          pace: Pace? = nil, forecast: Date? = nil) -> String {
        var parts = [window.title, tr("%lld percent used", Int(min(max(window.utilization, 0), 999).rounded()))]
        if let label = levelLabel(level) { parts.append(stale ? tr("last known %@", label) : label) }
        parts.append(stale ? tr("out of date") : resetText(window.resetsAt, now: now))
        if !stale {
            if level == .ok, let pace { parts.append(paceLabel(pace)) }
            if let forecast { parts.append(forecastText(forecast, now: now)) }
        }
        return parts.joined(separator: ", ")
    }

    /// "Ahead of pace" / "On track", as on the status pill.
    public static func paceLabel(_ pace: Pace) -> String {
        switch pace {
        case .ahead: return tr("Ahead of pace")
        case .under, .on: return tr("On track")
        }
    }

    /// Spoken/short form of a level: "near limit", "getting close".
    public static func levelLabel(_ level: UsageLevel) -> String? {
        switch level {
        case .critical: return tr("near limit")
        case .warning: return tr("getting close")
        case .ok, .unknown: return nil
        }
    }

    /// "$12.40" in the UI language's style, with exactly `decimals` fraction digits.
    public static func currency(_ amount: Double, code: String, decimals: Int, locale: Locale = L10n.locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: amount)) ?? "\(code) \(amount)"
    }

    /// "$12.40 of $50.00", or just "$12.40" when there's no spending limit.
    public static func extraUsageText(_ extra: ExtraUsage, locale: Locale = L10n.locale) -> String {
        let used = currency(extra.used, code: extra.currency, decimals: extra.decimals, locale: locale)
        guard let limit = extra.limit else { return used }
        return tr("%@ of %@", used, currency(limit, code: extra.currency, decimals: extra.decimals, locale: locale))
    }

    /// VoiceOver: "Extra usage, $12.40 of $50.00", plus the level the row's tag shows.
    public static func extraUsageAccessibilityLabel(_ extra: ExtraUsage, level: UsageLevel = .unknown, stale: Bool = false,
                                                    locale: Locale = L10n.locale) -> String {
        var parts = [tr("Extra usage"), extraUsageText(extra, locale: locale)]
        if let label = levelLabel(level) { parts.append(stale ? tr("last known %@", label) : label) }
        return parts.joined(separator: ", ")
    }

    /// "Not updated since 14:05" / "Not updated since 10/10/26, 14:05": the one phrase for
    /// stale data on every surface (popover, widget, copy card, notification).
    public static func notUpdatedText(_ fetched: Date, now: Date = Date()) -> String {
        tr("Not updated since %@", timestamp(fetched, now: now))
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
