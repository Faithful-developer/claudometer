import Foundation
import os

/// Remembers that the Claude Code usage endpoint answered 429, so polling doesn't ask it again
/// until the wait is over. Meanwhile the claude.ai backup key, if any, serves the readings
/// (TZ FR-16). Kept in memory: a relaunch costs at most one more 429.
public final class RouteCooldown: Sendable {
    /// Without a `Retry-After`: 5 min, doubling for each 429 in a row, up to an hour.
    static let firstWait: TimeInterval = 5 * 60
    static let minimumWait: TimeInterval = 60

    private struct State {
        var until: Date?
        var strikes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Seconds left before the endpoint may be asked again; nil when it may be asked now.
    public func remaining(now: Date = Date()) -> TimeInterval? {
        state.withLock { state in
            guard let until = state.until, until > now else { return nil }
            return until.timeIntervalSince(now)
        }
    }

    /// The endpoint answered 429.
    public func block(retryAfter: TimeInterval?, now: Date = Date()) {
        state.withLock { state in
            state.strikes += 1
            let escalating = Self.firstWait * pow(2, Double(min(state.strikes, 8) - 1))
            let wait = max(retryAfter ?? min(escalating, RetryAfter.cap), Self.minimumWait)
            state.until = now.addingTimeInterval(wait)
        }
    }

    /// The endpoint answered normally.
    public func clear() {
        state.withLock { $0 = State() }
    }
}
