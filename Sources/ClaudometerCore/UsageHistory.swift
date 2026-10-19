import Foundation

/// A week of usage, kept so the popover can show usage per day and when a limit will run out
/// at the current pace (TZ F-3, F-4). Only successful fetches are recorded, never projected or
/// stale data.
public struct UsageHistory: Codable, Equatable, Sendable {
    /// One reading: utilization and reset time per window id.
    public struct Sample: Codable, Equatable, Sendable {
        public let t: Date
        public let u: [String: Double]
        public let r: [String: Date]

        public init(t: Date, u: [String: Double], r: [String: Date] = [:]) {
            self.t = t
            self.u = u
            self.r = r
        }
    }

    public private(set) var samples: [Sample]

    /// Samples closer together than this are merged, so a 1-minute poll doesn't grow the file.
    static let spacing: TimeInterval = 15 * 60
    static let keep: TimeInterval = 8 * 86400

    public init(samples: [Sample] = []) {
        self.samples = samples
    }

    public mutating func record(_ snapshot: UsageSnapshot) {
        let sample = Sample(
            t: snapshot.fetchedAt,
            u: Dictionary(snapshot.windows.map { ($0.id, $0.utilization) }, uniquingKeysWith: { a, _ in a }),
            r: Dictionary(snapshot.windows.compactMap { w in w.resetsAt.map { (w.id, $0) } }, uniquingKeysWith: { a, _ in a })
        )
        if let last = samples.last, sample.t <= last.t { return }
        // The newest sample moves forward until it's `spacing` past the one before it.
        if samples.count >= 2, sample.t.timeIntervalSince(samples[samples.count - 2].t) < Self.spacing {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        samples.removeAll { sample.t.timeIntervalSince($0.t) > Self.keep }
    }

    // MARK: - Usage per day

    public struct Day: Equatable, Sendable {
        public let date: Date
        /// Points of the limit used that day.
        public let percent: Double
    }

    /// How much of a limit was used on each of the last `days` days, oldest first, today last.
    /// A reset (new reset time, or a drop) counts the new reading as used since the reset.
    public func dailyUse(windowId: String, days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var totals: [Date: Double] = [:]
        let readings = samples.filter { $0.u[windowId] != nil }
        for (previous, sample) in zip(readings, readings.dropFirst()) {
            guard let before = previous.u[windowId], let after = sample.u[windowId] else { continue }
            let reset = previous.r[windowId].map { old in sample.r[windowId].map { abs($0.timeIntervalSince(old)) > 60 } ?? false } ?? false
            let used = (reset || after < before) ? after : after - before
            totals[calendar.startOfDay(for: sample.t), default: 0] += max(used, 0)
        }
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, percent: totals[$0] ?? 0) }
        }
    }

    /// Days that have at least one reading of the window.
    public func daysWithData(windowId: String, calendar: Calendar = .current) -> Int {
        Set(samples.filter { $0.u[windowId] != nil }.map { calendar.startOfDay(for: $0.t) }).count
    }

    // MARK: - Forecast

    /// When `window` reaches 100% at its recent pace, if that's before it resets; nil otherwise
    /// (idle, slowing down, not enough data, or the reset comes first).
    ///
    /// The pace is measured over the last hour for the 5-hour session and the last day for
    /// weekly limits, within the current window only.
    public func forecast(for window: LimitWindow, at now: Date) -> Date? {
        guard let resetsAt = window.resetsAt, resetsAt > now, window.utilization < 100 else { return nil }
        let lookback: TimeInterval = window.group == .session ? 3600 : 86400
        let minimumSpan: TimeInterval = window.group == .session ? 10 * 60 : 3600
        let sameWindow = samples.filter { sample in
            guard sample.u[window.id] != nil, now.timeIntervalSince(sample.t) <= lookback, sample.t < now else { return false }
            guard let reset = sample.r[window.id] else { return false }
            return abs(reset.timeIntervalSince(resetsAt)) <= 60
        }
        guard let first = sameWindow.first, let start = first.u[window.id] else { return nil }
        let span = now.timeIntervalSince(first.t)
        guard span >= minimumSpan else { return nil }
        let rate = (window.utilization - start) / span
        guard rate > 0 else { return nil }
        let limit = now.addingTimeInterval((100 - window.utilization) / rate)
        return limit < resetsAt ? limit : nil
    }
}

/// `usage-history.json` (one per account) next to the usage state, readable by the widget.
public struct HistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func `default`(account: Account = .primary) -> HistoryStore {
        HistoryStore(fileURL: SnapshotStore.sharedDirectory.appendingPathComponent(account.fileName("usage-history")))
    }

    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func load() -> UsageHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return UsageHistory() }
        return (try? SnapshotStore.decoder.decode(UsageHistory.self, from: data)) ?? UsageHistory()
    }

    public func save(_ history: UsageHistory) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
