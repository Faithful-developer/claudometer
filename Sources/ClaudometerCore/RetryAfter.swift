import Foundation

/// The `Retry-After` header of a 429: either seconds or an HTTP date (RFC 9110 §10.2.3).
public enum RetryAfter {
    /// Longer waits are clamped, so one odd header can't stop polling for hours.
    public static let cap: TimeInterval = 3600

    /// Seconds to wait, clamped to `0...cap`; nil when the header is missing or unreadable.
    public static func parse(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text) {
            return clamp(seconds)
        }
        guard let date = httpDate.date(from: text) else { return nil }
        return clamp(date.timeIntervalSince(now))
    }

    private static func clamp(_ seconds: TimeInterval) -> TimeInterval? {
        guard seconds.isFinite else { return nil }
        return min(max(seconds, 0), cap)
    }

    /// IMF-fixdate, e.g. `Wed, 11 Nov 2026 17:30:00 GMT`.
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
