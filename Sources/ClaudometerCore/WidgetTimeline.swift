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
    /// the `finalStretch` before each reset in the span, the reset itself, and one second past
    /// `staleAt` (when the data turns stale) if that falls in the span. `isStale` is a strict
    /// `>`, so an entry at exactly `staleAt` would still draw as live until the next one.
    /// Entries closer than 5 s collapse into one; a reset or the stale entry wins over a regular
    /// one there, except that the first entry (`now`) is never dropped. At most a few dozen entries.
    public static func entryDates(now: Date, resets: [Date], staleAt: Date?) -> [Date] {
        let end = now.addingTimeInterval(span)
        var dates = stride(from: 0, through: span, by: step).map { now.addingTimeInterval($0) }
        // The entries that change what's drawn; the rest only move countdowns along.
        var priority = Set<Date>()
        for reset in Set(resets) where reset > now && reset <= end {
            let start = max(now, reset.addingTimeInterval(-finalStretch))
            dates += stride(from: reset.timeIntervalSince(start), to: 0, by: -60).map { reset.addingTimeInterval(-$0) }
            priority.insert(reset)
        }
        if let stale = staleAt?.addingTimeInterval(1), stale > now, stale <= end { priority.insert(stale) }
        // Entries closer than a few seconds draw the same thing.
        var result: [Date] = []
        for date in Set(dates).union(priority).sorted() {
            guard let last = result.last, date.timeIntervalSince(last) < 5 else {
                result.append(date)
                continue
            }
            guard priority.contains(date), !priority.contains(last) else { continue }
            if result.count == 1 { result.append(date) } else { result[result.count - 1] = date }
        }
        return result
    }
}
