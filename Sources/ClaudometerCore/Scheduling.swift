import Foundation

/// Polling delay with exponential backoff on errors (TZ FR-15, FR-16).
public enum Backoff {
    public static let cap: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - interval: normal polling interval.
    ///   - failures: consecutive failed fetches (0 after a success).
    ///   - error: the last error, used to honour `Retry-After`.
    public static func nextDelay(interval: TimeInterval, failures: Int, error: AppError? = nil) -> TimeInterval {
        guard failures > 0 else { return interval }
        switch error {
        case .notSignedIn, .keychainDenied, .apiChanged:
            // Retrying sooner will not help; keep the normal cadence.
            return interval
        case .tokenExpired:
            // Re-reading the Keychain is cheap (an expired token is caught before any request),
            // so a token Claude Code refreshes is picked up within a minute.
            return min(interval, 60)
        case .sessionKeyInvalid:
            // Needs a new key from the user; Settings → Save & Test restarts polling.
            return interval
        case .rateLimited(let retryAfter?):
            return max(backoff(failures), retryAfter)
        default:
            return backoff(failures)
        }
    }

    /// Shortens `delay` so a fetch happens just after the next limit resets; otherwise the
    /// UI would show "Resetting…" next to pre-reset numbers until the next regular poll.
    public static func untilNextReset(_ delay: TimeInterval, resets: [Date], now: Date = Date(), grace: TimeInterval = 15) -> TimeInterval {
        guard let next = resets.filter({ $0 > now }).min() else { return delay }
        return min(delay, max(next.timeIntervalSince(now) + grace, 5))
    }

    /// 1, 2, 4, 8, 15, 15, … minutes.
    static func backoff(_ failures: Int) -> TimeInterval {
        min(60 * pow(2, Double(min(failures, 10) - 1)), cap)
    }
}

/// Decides which threshold notifications to send, once per window per reset cycle (TZ FR-20, FR-21).
public struct ThresholdTracker: Sendable {
    public enum Event: Hashable, Sendable {
        case crossed(window: LimitWindow, threshold: Int)
        case reset(window: LimitWindow)
    }

    /// Keys already notified, e.g. `session|2026-10-06T12:19:59Z|80`.
    public private(set) var fired: Set<String>
    /// Windows that were at or above the top threshold, by id.
    public private(set) var nearLimit: Set<String>

    public init(fired: Set<String> = [], nearLimit: Set<String> = []) {
        self.fired = fired
        self.nearLimit = nearLimit
    }

    public mutating func evaluate(_ snapshot: UsageSnapshot, thresholds: [Int], notifyReset: Bool) -> [Event] {
        var events: [Event] = []
        let sorted = thresholds.sorted()
        let top = sorted.last ?? 100

        for window in snapshot.windows {
            let cycle = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
            // Highest threshold crossed only — no double notification when jumping 70 → 97.
            if let threshold = sorted.last(where: { window.utilization >= Double($0) }) {
                let key = "\(window.id)|\(cycle)|\(threshold)"
                if !fired.contains(key) {
                    fired.insert(key)
                    // Mark lower thresholds as fired too.
                    for lower in sorted where lower < threshold { fired.insert("\(window.id)|\(cycle)|\(lower)") }
                    events.append(.crossed(window: window, threshold: threshold))
                }
            }

            if window.utilization >= Double(top) {
                nearLimit.insert(window.id)
            } else if nearLimit.contains(window.id), window.utilization < Double(sorted.first ?? top) {
                nearLimit.remove(window.id)
                if notifyReset { events.append(.reset(window: window)) }
            }
        }
        pruneOldKeys(keep: snapshot)
        return events
    }

    /// Drop keys of cycles that no longer exist so the set does not grow forever.
    private mutating func pruneOldKeys(keep snapshot: UsageSnapshot) {
        let live = Set(snapshot.windows.map { w in
            "\(w.id)|" + (w.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none")
        })
        fired = fired.filter { key in
            let parts = key.split(separator: "|")
            guard parts.count == 3 else { return false }
            return live.contains("\(parts[0])|\(parts[1])")
        }
    }
}
