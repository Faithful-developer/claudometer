import SwiftUI

/// Widget layouts, independent of WidgetKit's timeline so the app can render previews.
public enum WidgetSize: String, CaseIterable, Sendable {
    case small, medium, large

    /// Nominal macOS widget sizes in points. The large one is the smallest real size seen on
    /// a desktop (~346 pt square); the 364×382 figure overflowed and clipped header and footer.
    public var size: CGSize {
        switch self {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        case .large: return CGSize(width: 344, height: 344)
        }
    }
}

public struct WidgetStyle: Codable, Sendable {
    public var metric: MenuBarMetric
    public var warning: Double
    public var critical: Double

    public init(metric: MenuBarMetric = .session, warning: Double = 60, critical: Double = 85) {
        self.metric = metric
        self.warning = warning
        self.critical = critical
    }

    /// The real level for a window (kept when stale so the last known severity stays visible).
    func level(_ window: LimitWindow?) -> UsageLevel {
        UsageLevel.of(window?.utilization, warning: warning, critical: critical)
    }

    /// Level used for fills: grey when the data is out of date.
    func fillLevel(_ window: LimitWindow?, stale: Bool) -> UsageLevel {
        stale ? .unknown : level(window)
    }
}

public struct UsageWidgetContent: View {
    let size: WidgetSize
    let state: UsageState
    let now: Date
    let style: WidgetStyle
    /// The widget's refresh button. WidgetKit's `Button(intent:)` only exists in the widget
    /// target, so it is passed in; previews pass a bare `RefreshGlyph`.
    let refreshControl: AnyView?

    public init(size: WidgetSize, state: UsageState, now: Date, style: WidgetStyle, refreshControl: AnyView? = nil) {
        self.size = size
        self.state = state
        self.now = now
        self.style = style
        self.refreshControl = refreshControl
    }

    private var isStale: Bool {
        guard let fetched = state.snapshot?.fetchedAt else { return true }
        return now.timeIntervalSince(fetched) > 30 * 60 || state.error != nil
    }

    public var body: some View {
        if let snapshot = state.snapshot {
            switch size {
            case .small: small(snapshot)
            case .medium: medium(snapshot)
            case .large: large(snapshot)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.title2).foregroundStyle(Ink.secondary)
                // Markdown (e.g. `claude`) renders like in the popover instead of raw backticks.
                Text(LocalizedStringKey(state.error?.message ?? "Open Claudometer to start"))
                    .font(.caption).multilineTextAlignment(.center)
                    .foregroundStyle(Ink.secondary)
                    .invalidatableContent()
                refreshControl
            }
        }
    }

    // MARK: Small: a single capacity ring, like the Batteries widget

    private func small(_ snapshot: UsageSnapshot) -> some View {
        let window = snapshot.window(for: style.metric)
        let level = style.level(window)
        return VStack(spacing: 8) {
            RingGauge(fraction: (window?.utilization ?? 0) / 100, level: style.fillLevel(window, stale: isStale), lineWidth: 10) {
                PercentText(window?.utilization, size: 28, dimmed: isStale)
            }
            .frame(width: 96, height: 96)
            VStack(spacing: 2) {
                Text(window.map(label) ?? "Usage")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .truncationMode(.tail)
                Group {
                    if isStale {
                        HStack(spacing: 3) {
                            if Palette.symbol(for: level) != nil { LevelTag(level: level, stale: true, showsText: false) }
                            Text(Formatters.outOfDateText(snapshot.fetchedAt))
                        }
                    } else if let tag = Palette.label(for: level) {
                        // Symbol + short label, so the state reads without the ring colour.
                        HStack(spacing: 3) {
                            LevelTag(level: level, showsText: false)
                            Text("\(tag) · \(Formatters.shortReset(window?.resetsAt, now: now))")
                        }
                    } else {
                        Text(Formatters.resetText(window?.resetsAt, now: now))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
                .minimumScaleFactor(0.92)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { Formatters.accessibilityLabel($0, level: level, stale: isStale, now: now) } ?? "No data")
        // Corner button: the ring fills the middle, so the footer row isn't available here.
        .overlay(alignment: .topTrailing) {
            refreshControl.offset(x: 6, y: -6)
        }
    }

    // MARK: Medium: ring + the other limits

    private func medium(_ snapshot: UsageSnapshot) -> some View {
        let hero = snapshot.window(for: style.metric)
        let others = Array(snapshot.windows.filter { $0.id != hero?.id }.prefix(2))
        let level = style.level(hero)
        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 4) {
                RingGauge(fraction: (hero?.utilization ?? 0) / 100, level: style.fillLevel(hero, stale: isStale), lineWidth: 9) {
                    PercentText(hero?.utilization, size: 22, dimmed: isStale)
                }
                .frame(width: 72, height: 72)
                Text(hero.map(label) ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let hero {
                    Text(Formatters.resetText(hero.resetsAt, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                StatusLabel(level: level, stale: isStale)
                    .font(.system(size: 10))
                    .scaleEffect(0.92)
            }
            .frame(minWidth: 96)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hero.map { Formatters.accessibilityLabel($0, level: level, stale: isStale, now: now) } ?? "No data")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(others) { row($0, caption: true) }
                Spacer(minLength: 0)
                footer(snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: Large: everything

    private func large(_ snapshot: UsageSnapshot) -> some View {
        let hero = snapshot.window(for: style.metric)
        let others = Array(snapshot.windows.filter { $0.id != hero?.id }.prefix(3))
        let level = style.level(hero)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claudometer").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary)
                Spacer()
                if let plan = Formatters.planName(snapshot.plan) {
                    Text("\(plan) plan").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
            }
            if let hero {
                HStack(spacing: 14) {
                    RingGauge(fraction: hero.utilization / 100, level: style.fillLevel(hero, stale: isStale), lineWidth: 8) {
                        PercentText(hero.utilization, size: 22, dimmed: isStale)
                    }
                    .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label(hero)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Text(Formatters.resetText(hero.resetsAt, now: now))
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        StatusLabel(level: level, pace: hero.pace(now: now), stale: isStale)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Formatters.accessibilityLabel(hero, level: level, stale: isStale, now: now))
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others) { row($0, caption: true) }
                }
            }
            if snapshot.breakdown.contains(where: { $0.percent > 0 }) {
                // The table legend fills the card when there's room; with two or more limit
                // rows the one-line legend keeps everything inside the large size.
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Usage by Surface This Week")
                    BreakdownChart(rows: snapshot.breakdown, legend: others.count <= 1 ? .table : .inline, dimmed: isStale)
                }
            }
            Spacer(minLength: 0)
            footer(snapshot)
        }
    }

    // MARK: Pieces

    private func row(_ window: LimitWindow, caption: Bool) -> some View {
        let level = style.level(window)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.group == .weekly ? "Weekly · \(window.shortTitle)" : window.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Ink.secondary)
                LevelTag(level: level, stale: isStale, showsText: false)
                Spacer(minLength: 4)
                Text(Formatters.percent(window.utilization))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(isStale ? Ink.secondary : Ink.primary)
                    .fixedSize()
            }
            .font(.system(size: 11))
            MeterBar(fraction: window.utilization / 100, level: style.fillLevel(window, stale: isStale), elapsed: window.elapsedFraction(now: now), height: 5)
            if caption {
                Text([isStale ? nil : Palette.label(for: level), Formatters.resetText(window.resetsAt, now: now)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatters.accessibilityLabel(window, level: level, stale: isStale, now: now))
    }

    /// "Updated 14:05", or a clear "Out of date · 14:05" marker when the data is stale.
    private func footer(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 4) {
            Group {
                if isStale {
                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(Palette.warningGlyph)
                    Text(Formatters.outOfDateText(snapshot.fetchedAt)).foregroundStyle(Ink.secondary)
                } else {
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(Ink.tertiary)
                }
            }
            // Shimmers while the refresh intent runs, until the app reloads the timeline.
            .invalidatableContent()
            if let refreshControl {
                Spacer(minLength: 4)
                refreshControl
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }

    private func label(_ window: LimitWindow) -> String {
        switch window.group {
        case .session: return "Session"
        case .weekly: return window.id == "weekly_all" ? "Weekly" : "Weekly · \(window.shortTitle)"
        case .other: return window.title
        }
    }
}

/// The widget's refresh icon. A 22pt hit area around a small glyph, in secondary ink.
public struct RefreshGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .accessibilityLabel("Refresh")
    }
}
