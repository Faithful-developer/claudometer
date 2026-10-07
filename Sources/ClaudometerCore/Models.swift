import Foundation

/// Broad category of a limit window. Used for ordering and for picking the menu bar metric.
public enum LimitGroup: String, Codable, Sendable {
    case session
    case weekly
    case other
}

/// One rolling usage limit (e.g. the 5-hour session window).
public struct LimitWindow: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier, e.g. `session`, `weekly_all`, `weekly_scoped:Opus`.
    public let id: String
    public let group: LimitGroup
    public let title: String
    /// Percent used, 0...100 (may exceed 100; clamp for display only).
    public let utilization: Double
    public let resetsAt: Date?
    /// Server-provided severity (`normal`, `warning`, `critical`, …) if any.
    public let severity: String?

    public init(id: String, group: LimitGroup, title: String, utilization: Double, resetsAt: Date?, severity: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.severity = severity
    }

    /// Length of the rolling window, if known (5 h session, 7 d weekly).
    public var windowLength: TimeInterval? {
        switch group {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86400
        case .other: return nil
        }
    }

    /// Share of the window's time that has passed, 0...1. Compared with `utilization`
    /// it shows pace: using 40% after 80% of the time is comfortably under.
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let length = windowLength, let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / length, 0), 1)
    }

    /// Usage compared with time elapsed in the window (±10 points counts as on pace).
    public func pace(now: Date = Date()) -> Pace? {
        guard let elapsed = elapsedFraction(now: now), elapsed > 0.05, elapsed < 1 else { return nil }
        let used = utilization / 100
        if used <= elapsed - 0.1 { return .under }
        if used >= elapsed + 0.1 { return .ahead }
        return .on
    }

    /// Next reset once `resetsAt` has passed. Weekly windows run on a fixed weekly cadence;
    /// a session window only starts again with the next message, so it has no reset yet.
    func nextReset(after resetsAt: Date, now: Date) -> Date? {
        guard group == .weekly, let length = windowLength else { return nil }
        var next = resetsAt
        while next <= now { next += length }
        return next
    }

    /// Title without the group prefix, for rows under a "Weekly limits" heading.
    public var shortTitle: String {
        if id == "weekly_all" { return "All models" }
        if let range = title.range(of: " · ") { return String(title[range.upperBound...]) }
        return title
    }

    /// One character for the menu bar ring: 5 for the 5-hour session, W for weekly (all
    /// models), or the model's initial for model-scoped limits (F for Fable, S for Sonnet).
    /// Session is a digit so it never collides with a model's initial.
    public var badgeLetter: String {
        if group == .session { return "5" }
        if id == "weekly_all" { return "W" }
        return shortTitle.first.map { String($0).uppercased() } ?? "?"
    }
}

/// Share of the weekly usage by surface (Claude Code, Chats, …).
public struct BreakdownRow: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let percent: Double

    public init(key: String, title: String, percent: Double) {
        self.key = key
        self.title = title
        self.percent = percent
    }
}

/// Which login the data came from.
public enum UsageSource: String, Codable, Sendable {
    /// Claude Code's OAuth token from the Keychain (the default).
    case claudeCode
    /// The claude.ai session key saved in Settings, used when Claude Code's token has expired.
    case claudeWeb

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code login"
        case .claudeWeb: return "claude.ai session key"
        }
    }
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public let windows: [LimitWindow]
    public let breakdown: [BreakdownRow]
    public let plan: String?
    public let fetchedAt: Date
    /// Missing in states cached before the claude.ai fallback existed.
    public let source: UsageSource?

    public init(windows: [LimitWindow], breakdown: [BreakdownRow] = [], plan: String? = nil, fetchedAt: Date = Date(), source: UsageSource? = nil) {
        self.windows = windows
        self.breakdown = breakdown
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public var session: LimitWindow? { windows.first { $0.group == .session } }
    public var weekly: LimitWindow? { windows.first { $0.id == "weekly_all" } ?? windows.first { $0.group == .weekly } }
    public var highest: LimitWindow? { windows.max { $0.utilization < $1.utilization } }

    public func window(for metric: MenuBarMetric) -> LimitWindow? {
        switch metric {
        case .session: return session ?? highest
        case .weekly: return weekly ?? highest
        case .highest: return highest
        }
    }

    /// Limits other than the menu bar's own that are high enough to get a ring of their own,
    /// highest first, at most `limit` so the menu bar item stays narrow enough not to be hidden.
    public func highWindows(excluding primary: LimitWindow?, from threshold: Double, limit: Int = 2) -> [LimitWindow] {
        Array(windows
            .filter { $0.id != primary?.id && $0.utilization >= threshold }
            .sorted { $0.utilization > $1.utilization }
            .prefix(limit))
    }

    public func withPlan(_ plan: String?) -> UsageSnapshot {
        UsageSnapshot(windows: windows, breakdown: breakdown, plan: plan, fetchedAt: fetchedAt, source: source)
    }

    public func withSource(_ source: UsageSource) -> UsageSnapshot {
        UsageSnapshot(windows: windows, breakdown: breakdown, plan: plan, fetchedAt: fetchedAt, source: source)
    }

    /// Windows whose reset time has passed read 0%: the old figure no longer applies, and
    /// without a fetch nothing new has been used that we know of. Keeps last known data
    /// honest while every login is unavailable (e.g. Claude Code closed overnight).
    public func projected(at now: Date) -> UsageSnapshot {
        guard windows.contains(where: { ($0.resetsAt ?? .distantFuture) <= now }) else { return self }
        let updated = windows.map { window -> LimitWindow in
            guard let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            return LimitWindow(id: window.id, group: window.group, title: window.title, utilization: 0,
                               resetsAt: window.nextReset(after: resetsAt, now: now), severity: nil)
        }
        return UsageSnapshot(windows: updated, breakdown: breakdown, plan: plan, fetchedAt: fetchedAt, source: source)
    }
}

public enum Pace: Sendable {
    case under, on, ahead
}

public enum MenuBarMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case session, weekly, highest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .session: return "Session (5h)"
        case .weekly: return "Weekly"
        case .highest: return "Highest"
        }
    }
}

public enum AppError: Error, Codable, Hashable, Sendable {
    case notSignedIn
    case keychainDenied
    case tokenExpired
    /// claude.ai rejected the saved session key (signed out or expired).
    case sessionKeyInvalid
    /// claude.ai answered with a bot check instead of data (Cloudflare).
    case webBlocked
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case server(status: Int)
    case apiChanged
    case unknown(String)

    public var message: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `claude` in Terminal and use /login."
        case .keychainDenied:
            return "Keychain access denied. Click Retry and choose “Always Allow”."
        case .tokenExpired:
            return "Claude Code login expired. Open Claude Code, or add a claude.ai session key in Settings."
        case .sessionKeyInvalid:
            return "claude.ai session key expired. Paste a new one in Settings."
        case .webBlocked:
            return "claude.ai blocked the request. Retrying later."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Rate limited, retrying in \(Formatters.duration(retryAfter))."
            }
            return "Rate limited, retrying soon."
        case .offline:
            return "Offline. Retrying automatically."
        case .server(let status):
            return "Claude service error (\(status)). Retrying…"
        case .apiChanged:
            return "Usage format not recognised. Check for an update."
        case .unknown(let text):
            return text
        }
    }

    /// Errors where keeping the last good data on screen makes sense.
    public var keepsStaleData: Bool {
        switch self {
        case .rateLimited, .offline, .server, .tokenExpired, .sessionKeyInvalid, .webBlocked, .unknown: return true
        case .notSignedIn, .keychainDenied, .apiChanged: return false
        }
    }
}

/// Everything the UI (menu bar and widget) needs to render.
public struct UsageState: Codable, Hashable, Sendable {
    public var snapshot: UsageSnapshot?
    public var error: AppError?

    public init(snapshot: UsageSnapshot? = nil, error: AppError? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    public var isStale: Bool { snapshot != nil && error != nil }

    public func projected(at now: Date) -> UsageState {
        UsageState(snapshot: snapshot?.projected(at: now), error: error)
    }
}
