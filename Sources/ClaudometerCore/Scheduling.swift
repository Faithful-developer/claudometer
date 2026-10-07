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
///
/// A cycle is identified by the window's reset time, compared with a tolerance: the API
/// computes `resets_at` per request, so it drifts by fractions of a second (and across minute
/// boundaries) between fetches without the limit having reset.
public struct ThresholdTracker: Codable, Sendable {
    public enum Event: Hashable, Sendable {
        case crossed(window: LimitWindow, threshold: Int)
        case reset(window: LimitWindow)
    }

    /// What has been notified for one window in its current cycle.
    public struct Cycle: Codable, Hashable, Sendable {
        public var resetsAt: Date?
        public var fired: Set<Int>
        /// Reached the top threshold this cycle, so its rollover gets a "has reset" alert.
        public var nearLimit: Bool

        public init(resetsAt: Date?, fired: Set<Int> = [], nearLimit: Bool = false) {
            self.resetsAt = resetsAt
            self.fired = fired
            self.nearLimit = nearLimit
        }
    }

    /// Reset times closer than this belong to the same cycle. Real resets move it by 5 h or 7 d.
    public static let cycleTolerance: TimeInterval = 15 * 60

    /// By window id.
    public private(set) var cycles: [String: Cycle]

    public init(cycles: [String: Cycle] = [:]) {
        self.cycles = cycles
    }

    /// Migrates the state of older builds: keys like `session|29999999|80` (reset time in whole
    /// minutes) and the ids of windows that were near their limit.
    public init(legacyFired: Set<String>, nearLimit: Set<String>) {
        var cycles: [String: Cycle] = [:]
        for key in legacyFired {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let threshold = Int(parts[2]) else { continue }
            let resetsAt = Double(parts[1]).map { Date(timeIntervalSince1970: $0 * 60) }
            let id = String(parts[0])
            var cycle = cycles[id] ?? Cycle(resetsAt: resetsAt)
            if let resetsAt, resetsAt > (cycle.resetsAt ?? .distantPast) { cycle.resetsAt = resetsAt }
            cycle.fired.insert(threshold)
            cycles[id] = cycle
        }
        for id in nearLimit { cycles[id]?.nearLimit = true }
        self.cycles = cycles
    }

    public mutating func evaluate(_ snapshot: UsageSnapshot, thresholds: [Int], notifyReset: Bool) -> [Event] {
        var events: [Event] = []
        let sorted = thresholds.sorted()
        let top = sorted.last ?? 100

        for window in snapshot.windows {
            var cycle = cycles[window.id] ?? Cycle(resetsAt: window.resetsAt)
            if Self.isNewCycle(from: cycle.resetsAt, to: window.resetsAt) {
                if cycle.nearLimit, notifyReset { events.append(.reset(window: window)) }
                cycle = Cycle(resetsAt: window.resetsAt)
            } else if let resetsAt = window.resetsAt {
                cycle.resetsAt = resetsAt
            }

            // Highest threshold crossed only — no double notification when jumping 70 → 97.
            if let threshold = sorted.last(where: { window.utilization >= Double($0) }), !cycle.fired.contains(threshold) {
                // Mark lower thresholds as fired too.
                cycle.fired.formUnion(sorted.filter { $0 <= threshold })
                events.append(.crossed(window: window, threshold: threshold))
            }
            if window.utilization >= Double(top) { cycle.nearLimit = true }
            cycles[window.id] = cycle
        }
        prune(keeping: snapshot)
        return events
    }

    /// A different reset time, or a window that ended ("Not started") or started.
    static func isNewCycle(from stored: Date?, to current: Date?) -> Bool {
        switch (stored, current) {
        case (nil, nil): return false
        case let (stored?, current?): return abs(current.timeIntervalSince(stored)) > cycleTolerance
        default: return true
        }
    }

    /// Forgets windows that are gone and whose cycle has ended. A window missing from a single
    /// response keeps its record, so it does not notify again when it comes back.
    private mutating func prune(keeping snapshot: UsageSnapshot) {
        let live = Set(snapshot.windows.map(\.id))
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-Self.cycleTolerance)
        cycles = cycles.filter { id, cycle in
            live.contains(id) || (cycle.resetsAt.map { $0 > cutoff } ?? false)
        }
    }
}
