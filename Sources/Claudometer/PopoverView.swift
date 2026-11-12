import AppKit
import ClaudometerCore
import SwiftUI

/// Content of the menu bar popover (TZ FR-6…FR-9, FR-24, §6.2).
///
/// Modelled on the system menu bar extras (Battery, Wi‑Fi, Control Center): the window keeps
/// the system material, text uses hierarchical styles so it picks up vibrancy, and actions
/// are full-width menu rows with keyboard shortcuts.
struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @Environment(UpdateStore.self) private var updates
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @Environment(\.isPreviewRender) private var isPreviewRender
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openSettings) private var openSettings
    @Environment(\.isOnGlass) private var isOnGlass
    @AppStorage(SettingsKey.language) private var language = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.hasManyAccounts {
                Group {
                    // `ImageRenderer` can't draw the system control; renders use the drawn one.
                    if isOnGlass && !isPreviewRender { GlassAccountSwitcher() } else { AccountSwitcher() }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            // Countdowns tick every 30 s without a network call (FR-9).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            MenuDivider()
            actions
        }
        .padding(.vertical, 6)
        // Rebuilt in a new language; `tr` reads it when the views are created.
        .id(language)
        .frame(width: 300)
        // On glass (macOS 26) the window keeps the system's own material: no painted wash.
        .background { if !isPreviewRender && !isOnGlass { MenuBackground() } }
        .fitsMenuWindowHeight()
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: "Claudometer").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary)
            Spacer()
            if let plan = Formatters.planName(store.state.snapshot?.plan) {
                Text(tr("%@ plan", plan)).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let snapshot = store.state.snapshot
        let stale = store.isStale(at: now)
        let hero = snapshot?.window(for: MenuBarMetric(rawValue: metric) ?? .session)
        let others = snapshot?.windows.filter { $0.id != hero?.id } ?? []
        // Pace forecast from the history, measured up to the reading itself; never on old data.
        let forecast: (LimitWindow) -> Date? = { window in
            guard !stale, let fetched = snapshot?.fetchedAt else { return nil }
            return store.history.forecast(for: window, at: fetched)
        }
        let weeklyId = snapshot?.weekly?.id ?? "weekly_all"
        let account = store.hasManyAccounts ? store.selected.title : nil

        VStack(alignment: .leading, spacing: 0) {
            if let error = store.state.error {
                let hasSessionKey = SessionKeyStore(accountID: store.selectedID).hasKey
                ErrorNotice(
                    error: error,
                    message: error.message(hasSessionKey: hasSessionKey),
                    staleSince: stale ? snapshot?.fetchedAt : nil,
                    recoveries: error.recoveries(hasSessionKey: hasSessionKey),
                    now: now,
                    perform: recover
                )
                .padding(.horizontal, 14).padding(.vertical, 6)
            } else if stale, let fetched = snapshot?.fetchedAt {
                // Old data with no error (the Mac slept, or refreshes stalled): everything is
                // grey, so say why here rather than only in the footer.
                StaleNotice(fetched: fetched, now: now, isLoading: store.isLoading) { store.refresh() }
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }

            if let hero {
                CopyableLimit { scheme in
                    LimitImage.copy(snapshot: snapshot, account: account, stale: stale, now: now, colorScheme: scheme)
                } content: {
                    HeroRow(window: hero, level: level(hero), stale: stale, now: now, forecast: forecast(hero))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                if store.state.hasNoSessionLimit {
                    // Says why there's no session ring, so it doesn't look like missing data (TZ FR-33).
                    Text(tr("No 5-hour session limit on this plan"))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 8)
                }
            } else if store.state.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Loading usage…")).foregroundStyle(Ink.secondary)
                }
                .font(.system(size: 13))
                .padding(14)
            }

            if !others.isEmpty {
                MenuDivider()
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(others.allSatisfy { $0.group == .weekly } ? tr("Weekly Limits") : tr("Limits"))
                    ForEach(others) { window in
                        CopyableLimit(bleedY: 4) { scheme in
                            LimitImage.copy(snapshot: snapshot, account: account, stale: stale, now: now, colorScheme: scheme)
                        } content: {
                            LimitRow(window: window, level: level(window), stale: stale, now: now, forecast: forecast(window))
                        }
                    }
                    if (snapshot?.windows ?? []).contains(where: { $0.elapsedFraction(now: now) != nil }) {
                        PaceLegend()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }

            // Usage per day of the weekly limit, once there's more than a day of history.
            if snapshot != nil, store.history.daysWithData(windowId: weeklyId) >= 2 {
                MenuDivider()
                DailyUseSection(days: store.history.dailyUse(windowId: weeklyId, now: now), dimmed: stale)
            }

            if let breakdown = snapshot?.breakdown, breakdown.contains(where: { $0.percent > 0 }) {
                MenuDivider()
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(tr("Usage by Surface This Week"))
                    // Stale: series fills go grey; the text keeps its full-contrast ink.
                    BreakdownChart(rows: breakdown, dimmed: stale)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    /// One click installs the update in place and relaunches; the release page is the fallback
    /// when that isn't possible or failed.
    @ViewBuilder
    private func updateRow(_ release: AppRelease) -> some View {
        switch updates.installState {
        case .downloading(let fraction):
            UpdateProgressRow(title: tr("Downloading Update… %lld%%", Int(fraction * 100)), fraction: fraction)
        case .installing:
            UpdateProgressRow(title: tr("Installing Update…"), fraction: 1)
        case .failed(let message):
            MenuRow(title: tr("Download Update %@…", release.version), shortcut: nil) { updates.openDownload() }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        case .idle:
            if updates.canInstall {
                MenuRow(title: tr("Install Update %@", release.version), shortcut: nil) { updates.installUpdate() }
            } else {
                MenuRow(title: tr("Update Available: %@…", release.version), shortcut: nil) { updates.openDownload() }
            }
        }
    }

    private func recover(_ recovery: ErrorRecovery) {
        switch recovery {
        case .tryAgain: store.retry()
        case .addSessionKey, .updateSessionKey: SettingsWindow.open(openSettings, tab: .login)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    // Without data the "Loading usage…" line already says it; with an error or
                    // old data the notice says how old it is, and a second "Updated 2 min ago"
                    // here read as if the last update had worked.
                    if let fetched = store.state.snapshot?.fetchedAt {
                        if store.isLoading {
                            Text(tr("Updating…"))
                        } else if store.state.error == nil, !store.isStale(at: context.date) {
                            Text(Formatters.updatedText(fetched, now: context.date))
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Ink.tertiary(contrast))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
            if let release = updates.available {
                updateRow(release)
            }
            MenuRow(title: tr("Refresh Now"), shortcut: "⌘R") { store.refresh() }
                .keyboardShortcut("r")
                .disabled(store.isLoading)
            if isPreviewRender {
                MenuRowLabel(title: tr("Settings…"), shortcut: "⌘,").padding(.horizontal, 5)
            } else {
                MenuRow(title: tr("Settings…"), shortcut: "⌘,") { SettingsWindow.open(openSettings) }
                    .keyboardShortcut(",")
            }
            MenuRow(title: tr("Quit Claudometer"), shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func level(_ window: LimitWindow) -> UsageLevel {
        UsageLevel.of(window.utilization, warning: warning, critical: critical)
    }
}

// MARK: - Hero

/// The menu bar metric, shown as a capacity ring with its details beside it.
///
/// Stale data is dimmed through ink, not opacity: the ring goes grey, the figure moves to
/// secondary ink (still ≥4.5:1), and the last known level stays as a "Last known" pill.
struct HeroRow: View {
    let window: LimitWindow
    let level: UsageLevel
    let stale: Bool
    let now: Date
    /// When the limit runs out at the current pace, if before the reset.
    var forecast: Date? = nil
    @Environment(\.isRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 14) {
            RingGauge(fraction: window.utilization / 100, level: stale ? .unknown : level, lineWidth: 7, highlighted: highlighted) {
                PercentText(window.utilization, size: 18, dimmed: stale)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(window.group == .session ? tr("Current Session") : window.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Formatters.resetText(window.resetsAt, now: now))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                if let forecast {
                    Text(Formatters.forecastText(forecast, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                }
                StatusLabel(level: level, pace: window.pace(now: now), stale: stale).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatters.accessibilityLabel(window, level: level, stale: stale, now: now))
    }
}

// MARK: - Rows

/// Label in secondary ink, value in primary (same hierarchy as the widget rows and legend).
struct LimitRow: View {
    let window: LimitWindow
    let level: UsageLevel
    let stale: Bool
    let now: Date
    var forecast: Date? = nil
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isRowHighlighted) private var highlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.shortTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                LevelTag(level: level, stale: stale)
                    .font(.system(size: 11))
                Spacer(minLength: 8)
                Text(Formatters.percent(window.utilization))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(stale ? Ink.secondary : Ink.primary)
                    .fixedSize()
            }
            MeterBar(
                fraction: window.utilization / 100,
                level: stale ? .unknown : level,
                elapsed: window.elapsedFraction(now: now),
                // The pace tick's halo matches whatever is behind the row.
                halo: highlighted ? Palette.rowHover : Palette.canvas
            )
            Text([Formatters.resetText(window.resetsAt, now: now), forecast.map { Formatters.forecastText($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(highlighted ? Ink.secondary : Ink.tertiary(contrast))
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatters.accessibilityLabel(window, level: level, stale: stale, now: now))
    }
}

/// Makes a limit clickable: hover highlight and tooltip, click copies all limits as an image, then a
/// short "Copied" confirmation. The highlight bleeds into the surrounding padding so the row's
/// content doesn't move. Inert in preview renders.
struct CopyableLimit<Content: View>: View {
    /// Vertical bleed; the stacked weekly rows use 4 so neighbouring highlights keep a gap.
    var bleedY: CGFloat = 5
    let copy: (ColorScheme) -> Bool
    @ViewBuilder let content: () -> Content
    @StateObject private var feedback = CopyFeedback()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isPreviewRender) private var isPreviewRender

    /// Same 9 pt label inset as `MenuRowLabel`, so highlights line up with the menu rows.
    private let bleedX: CGFloat = 9

    var body: some View {
        if isPreviewRender {
            content()
        } else {
            Button(action: run) {
                // The confirmation replaces the row for a moment rather than overprinting its text.
                content()
                    .opacity(feedback.copied ? 0 : 1)
                    .overlay {
                        if feedback.copied {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                Text(tr("Copied as image"))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, bleedX).padding(.vertical, bleedY)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CopyableLimitStyle())
            .help(tr("Click to copy as an image"))
            .accessibilityAction(named: Text(tr("Copy as image")), run)
            .padding(.horizontal, -bleedX).padding(.vertical, -bleedY)
        }
    }

    private func run() {
        guard copy(colorScheme) else { NSSound.beep(); return }
        feedback.flash()
        AccessibilityNotification.Announcement(tr("Copied as image")).post()
    }
}

/// Hover and pressed tints of `MenuRowStyle`, without its outer inset (the limit sections
/// already provide it).
struct CopyableLimitStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CopyableLimitBody(configuration: configuration)
    }

    private struct CopyableLimitBody: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var hover = HoverState()
        @Environment(\.isOnGlass) private var isOnGlass

        var body: some View {
            configuration.label
                .environment(\.isRowHighlighted, hover.isOn)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(RowHighlight.fill(hovered: hover.isOn, pressed: configuration.isPressed, onGlass: isOnGlass))
                }
                .onHover { hover.isOn = $0 }
        }
    }
}

/// Drives the "Copied" confirmation; an object for the same reason as `HoverState`.
@MainActor
final class CopyFeedback: ObservableObject {
    @Published var copied = false
    private var reset: Task<Void, Never>?

    func flash() {
        reset?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        reset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.copied = false }
        }
    }
}

/// Explains the tick on the meters.
struct PaceLegend: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(Ink.secondary).frame(width: 2, height: 10)
            Text(tr("Time elapsed in the window"))
        }
        .font(.system(size: 10))
        .foregroundStyle(Ink.tertiary(contrast))
    }
}

// MARK: - Accounts

/// One segment per account (TZ F-2), drawn in SwiftUI so it matches the menu and shows up in
/// preview renders. ⌘1…⌘4 switch too. The menu bar follows the selection.
struct AccountSwitcher: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        SegmentLayout(selected: store.accounts.firstIndex { $0.id == store.selectedID } ?? 0) {
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                let isSelected = account.id == store.selectedID
                let needsAction = store.state(of: account.id).error?.needsUserAction ?? false
                Button { store.select(account.id) } label: {
                    AccountSegmentLabel(title: account.title, needsAction: needsAction)
                }
                .buttonStyle(AccountSegmentStyle(isSelected: isSelected))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help(account.title)
                .accessibilityLabel(needsAction ? tr("%@, needs attention", account.title) : account.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Accounts"))
    }
}

/// The account switcher on glass: the system segmented control, which takes the glass look
/// itself. ⌘1…⌘4 still switch; an account that needs attention gets the warning symbol.
struct GlassAccountSwitcher: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let selection = Binding(get: { store.selectedID }, set: { store.select($0) })
        Picker(tr("Accounts"), selection: selection) {
            ForEach(store.accounts, id: \.id) { account in
                let needsAction = store.state(of: account.id).error?.needsUserAction ?? false
                Group {
                    if needsAction {
                        Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(account.title)")
                    } else {
                        Text(account.title)
                    }
                }
                .help(account.title)
                .accessibilityLabel(needsAction ? tr("%@, needs attention", account.title) : account.title)
                .tag(account.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .background {
            // Invisible buttons that carry the ⌘1…⌘4 shortcuts.
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button("") { store.select(account.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct AccountSegmentLabel: View {
    let title: String
    /// The account's key expired or its login needs the user: a symbol, since the text is
    /// only the name.
    let needsAction: Bool

    var body: some View {
        HStack(spacing: 4) {
            if needsAction {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warningGlyph)
            }
            Text(title).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

/// Each segment as wide as its name, with what's left shared equally. When the names don't
/// fit, the selected one keeps up to `selectedCap` and the longest of the others are cut first.
private struct SegmentLayout: Layout {
    let selected: Int
    var spacing: CGFloat = 2
    var selectedCap: CGFloat = 120

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = ideal.map(\.width).reduce(0, +) + gaps(subviews)
        return CGSize(width: proposal.width ?? natural, height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width - gaps(subviews), subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    private func widths(_ available: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let total = ideal.reduce(0, +)
        guard total > available else {
            let extra = (available - total) / CGFloat(max(ideal.count, 1))
            return ideal.map { $0 + extra }
        }
        var widths = ideal
        var others = Array(ideal.indices)
        var room = available
        if ideal.indices.contains(selected) {
            widths[selected] = min(ideal[selected], selectedCap, available)
            room -= widths[selected]
            others.removeAll { $0 == selected }
        }
        // The widest cap that fits everyone else: shorter names keep their full width.
        var remaining = others.sorted { ideal[$0] < ideal[$1] }
        while let first = remaining.first {
            let share = max(room, 0) / CGFloat(remaining.count)
            if ideal[first] <= share {
                widths[first] = ideal[first]
                room -= ideal[first]
                remaining.removeFirst()
            } else {
                remaining.forEach { widths[$0] = share }
                break
            }
        }
        return widths
    }
}

private struct AccountSegmentStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        AccountSegmentBody(configuration: configuration, isSelected: isSelected)
    }

    private struct AccountSegmentBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @StateObject private var hover = HoverState()

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            let highlighted = !isSelected && (hover.isOn || configuration.isPressed)
            configuration.label
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected || highlighted ? Ink.primary : Ink.secondary)
                .background {
                    // The segments sit on `track`, so they use the track highlight.
                    if isSelected {
                        shape.fill(Palette.surface).overlay(shape.strokeBorder(Palette.border))
                    } else if configuration.isPressed {
                        shape.fill(Palette.trackPressed)
                    } else if hover.isOn {
                        shape.fill(Palette.trackHover)
                    }
                }
                .onHover { hover.isOn = $0 }
        }
    }
}

// MARK: - Menu-style actions

struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }
}

/// Full-width action row like a menu item: soft highlight on hover, shortcut on the right.
struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { MenuRowLabel(title: title, shortcut: shortcut) }
            .buttonStyle(MenuRowStyle())
    }
}

struct MenuRowLabel: View {
    let title: String
    let shortcut: String?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isRowHighlighted) private var highlighted

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(highlighted ? Ink.secondary : Ink.tertiary(contrast)) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .contentShape(Rectangle())
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var hover = HoverState()
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isOnGlass) private var isOnGlass

        var body: some View {
            configuration.label
                .environment(\.isRowHighlighted, hover.isOn && isEnabled)
                .foregroundStyle(Ink.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(RowHighlight.fill(hovered: hover.isOn && isEnabled, pressed: configuration.isPressed, onGlass: isOnGlass))
                }
                .opacity(isEnabled ? 1 : 0.4)
                .padding(.horizontal, 5)
                .onHover { hover.isOn = $0 }
        }
    }
}

/// Download or install in progress: a status line with a bar, not a greyed-out menu row
/// (that read as a broken button at 2.4:1). Aligned with the menu row labels.
struct UpdateProgressRow: View {
    let title: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(Palette.coral)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Formatters.percent(fraction * 100))
    }
}

/// Row highlight fill: the warm palette tint on the opaque menu, a neutral system-style fill
/// on glass (brand colour stays off controls there, HIG Liquid Glass › Color on glass).
enum RowHighlight {
    static func fill(hovered: Bool, pressed: Bool, onGlass: Bool) -> Color {
        guard hovered else { return .clear }
        if onGlass { return pressed ? GlassFill.pressed : GlassFill.hover }
        return pressed ? Palette.rowPressed : Palette.rowHover
    }
}

private struct NoticeBackground: ViewModifier {
    @Environment(\.isOnGlass) private var isOnGlass

    func body(content: Content) -> some View {
        // Glass corners are rounder (macOS 26 concentric shapes); the opaque menu keeps 8.
        content.background(isOnGlass ? GlassFill.inset : Palette.track, in: RoundedRectangle(cornerRadius: isOnGlass ? 12 : 8, style: .continuous))
    }
}

private struct NoticeButton: ViewModifier {
    @Environment(\.isOnGlass) private var isOnGlass
    @Environment(\.isPreviewRender) private var isPreviewRender

    func body(content: Content) -> some View {
        if #available(macOS 26, *), isOnGlass, !isPreviewRender {
            // The system glass button: one material, its own hover and press.
            content.buttonStyle(.glass).controlSize(.small)
        } else {
            content.buttonStyle(NoticeButtonStyle())
        }
    }
}

extension View {
    /// Inset box behind a notice: track on the opaque menu, a light neutral fill on glass.
    func noticeBackground() -> some View { modifier(NoticeBackground()) }
    /// Glass button on macOS 26 glass, the drawn bordered button elsewhere (and in renders).
    func noticeButtonStyle() -> some View { modifier(NoticeButton()) }
}

/// `@State` needs the SwiftUI macro plugin, which the Command Line Tools lack.
final class HoverState: ObservableObject {
    @Published var isOn = false
}

/// Weekly limit used per day. The header shows today's share, or the hovered day's.
struct DailyUseSection: View {
    let days: [UsageHistory.Day]
    let dimmed: Bool
    @StateObject private var hover: HoveredDay

    /// `hovered` seeds the highlighted day; only previews pass it, since `ImageRenderer` never hovers.
    init(days: [UsageHistory.Day], dimmed: Bool = false, hovered: Int? = nil) {
        self.days = days
        self.dimmed = dimmed
        _hover = StateObject(wrappedValue: HoveredDay(index: hovered))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(tr("Weekly Limit by Day"))
                Spacer()
                Text(label)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Ink.secondary)
            }
            DailyBars(days: days, hovered: hover.index, dimmed: dimmed) { hover.index = $0 }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var label: String {
        guard let index = hover.index, days.indices.contains(index), index != days.count - 1 else {
            return tr("Today %@", Formatters.percent(days.last?.percent ?? 0))
        }
        let day = days[index]
        return tr("%@ %@", DailyBars.weekday(day.date).capitalized(with: L10n.locale), Formatters.percent(day.percent))
    }
}

/// Which bar of `DailyBars` is under the pointer; an object for the same reason as `HoverState`.
final class HoveredDay: ObservableObject {
    @Published var index: Int?
    init(index: Int? = nil) { self.index = index }
}

// MARK: - Errors

/// What went wrong, how old the data on screen is, and what to do about it (TZ FR-8, FR-25).
struct ErrorNotice: View {
    let error: AppError
    /// `error.message`, or its variant for a saved session key.
    let message: String
    /// When the data still on screen was fetched; nil if there's none.
    let staleSince: Date?
    let recoveries: [ErrorRecovery]
    let now: Date
    let perform: (ErrorRecovery) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Palette.warningGlyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(md(message))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let staleSince {
                    Text(Formatters.notUpdatedText(staleSince, now: now) + ".")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
                if !recoveries.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(recoveries, id: \.self) { recovery in
                            Button(recovery.title) { perform(recovery) }
                                .noticeButtonStyle()
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noticeBackground()
    }

    private var icon: String {
        switch error {
        case .offline: return "wifi.slash"
        case .notSignedIn, .tokenExpired: return "person.crop.circle.badge.exclamationmark"
        case .keychainDenied: return "key.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

/// Data older than the stale limit with no error to explain it: a neutral notice (clock, grey
/// glyph; nothing is broken) with the age and a way to refresh. Same shape as `ErrorNotice`.
struct StaleNotice: View {
    let fetched: Date
    let now: Date
    let isLoading: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 14))
                .foregroundStyle(Ink.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatters.notUpdatedText(fetched, now: now) + ".")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("Usage may have changed since."))
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                Button(isLoading ? tr("Updating…") : tr("Refresh Now"), action: refresh)
                    .noticeButtonStyle()
                    .disabled(isLoading)
                    .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noticeBackground()
    }
}

/// Small bordered button on the error notice. Drawn in SwiftUI so it matches the menu rows
/// and shows up in preview renders.
struct NoticeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NoticeButtonBody(configuration: configuration)
    }

    private struct NoticeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var hover = HoverState()

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                // The notice is `track`; `rowHover` all but matched it in dark.
                .background(shape.fill(configuration.isPressed ? Palette.trackPressed : hover.isOn ? Palette.trackHover : Palette.surface))
                .overlay(shape.strokeBorder(Palette.border))
                .contentShape(shape)
                .onHover { hover.isOn = $0 }
        }
    }
}

// MARK: - Environment

private struct PreviewRenderKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the row button styles while a row is hovered: tertiary text on `Palette.rowHover`
    /// would fall below 4.5:1, so it steps up to secondary.
    var isRowHighlighted: Bool {
        get { self[RowHighlightedKey.self] }
        set { self[RowHighlightedKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// True while `PreviewRenderer` draws the popover to a PNG.
    var isPreviewRender: Bool {
        get { self[PreviewRenderKey.self] }
        set { self[PreviewRenderKey.self] = newValue }
    }
}
