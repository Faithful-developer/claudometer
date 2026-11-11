import Foundation

/// When the widget should redraw between app reloads (TZ FR-13). Countdowns are text baked into
/// each entry, so the entries have to be close enough together that "Resets in 4m" is right.
public enum WidgetTimeline {
    /// How far ahead the timeline reaches; the system asks again after the last entry.
    public static let span: TimeInterval = 2 * 3600
    /// Spacing in general: a countdown is at most 5 min behind (it was 15). Near a reset, when
    /// that matters, entries go per minute.
    public static let step: TimeInterval = 5 * 60
    /// The last stretch before a reset, redrawn every minute, then once at the reset itself
    /// (the projected state drops the limit to 0% there).
    public static let finalStretch: TimeInterval = 15 * 60

    /// Sorted, distinct entry dates from `now`: every `step` across `span`, every minute in
    /// the `finalStretch` before each reset in the span, the reset itself, and `staleAt` (when
    /// the data turns stale) if it falls in the span. At most a few dozen entries.
    public static func entryDates(now: Date, resets: [Date], staleAt: Date?) -> [Date] {
        let end = now.addingTimeInterval(span)
        var dates = stride(from: 0, through: span, by: step).map { now.addingTimeInterval($0) }
        for reset in Set(resets) where reset > now && reset <= end {
            let start = max(now, reset.addingTimeInterval(-finalStretch))
            dates += stride(from: reset.timeIntervalSince(start), to: 0, by: -60).map { reset.addingTimeInterval(-$0) }
            dates.append(reset)
        }
        if let staleAt, staleAt > now, staleAt <= end { dates.append(staleAt) }
        // Entries closer than a few seconds draw the same thing.
        var result: [Date] = []
        for date in dates.sorted() where result.last.map({ date.timeIntervalSince($0) >= 5 }) ?? true {
            result.append(date)
        }
        return result
    }
}
