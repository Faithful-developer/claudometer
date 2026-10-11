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
    @AppStorage(SettingsKey.language) private var language = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
        .background { if !isPreviewRender { MenuBackground() } }
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
        let stale = store.state.isStale
        let hero = snapshot?.window(for: MenuBarMetric(rawValue: metric) ?? .session)
        let others = snapshot?.windows.filter { $0.id != hero?.id } ?? []
        // Pace forecast from the history, measured up to the reading itself; never on old data.
        let forecast: (LimitWindow) -> Date? = { window in
            guard !stale, let fetched = snapshot?.fetchedAt else { return nil }
            return store.history.forecast(for: window, at: fetched)
        }
        let weeklyId = snapshot?.weekly?.id ?? "weekly_all"

        VStack(alignment: .leading, spacing: 0) {
            if let error = store.state.error {
                ErrorNotice(
                    error: error,
                    staleSince: stale ? snapshot?.fetchedAt : nil,
                    recoveries: error.recoveries(hasSessionKey: SessionKeyStore().hasKey),
                    now: now,
                    perform: recover
                )
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            if let hero {
                CopyableLimit { scheme in
                    LimitImage.copy(snapshot: snapshot, stale: stale, now: now, colorScheme: scheme)
                } content: {
                    HeroRow(window: hero, level: level(hero), stale: stale, now: now, forecast: forecast(hero))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
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
                            LimitImage.copy(snapshot: snapshot, stale: stale, now: now, colorScheme: scheme)
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
                let days = store.history.dailyUse(windowId: weeklyId, now: now)
                MenuDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(tr("Weekly Limit by Day"))
                        Spacer()
                        Text(tr("Today %@", Formatters.percent(days.last?.percent ?? 0)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Ink.secondary)
                    }
                    DailyBars(days: days)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
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
            MenuRow(title: tr("Downloading Update… %lld%%", Int(fraction * 100)), shortcut: nil) {}
                .disabled(true)
        case .installing:
            MenuRow(title: tr("Installing Update…"), shortcut: nil) {}
                .disabled(true)
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
                    if store.isLoading {
                        Text(tr("Updating…"))
                    } else if let fetched = store.state.snapshot?.fetchedAt {
                        Text(Formatters.updatedText(fetched, now: context.date))
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

    var body: some View {
        HStack(spacing: 14) {
            RingGauge(fraction: window.utilization / 100, level: stale ? .unknown : level, lineWidth: 7) {
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
                halo: Palette.canvas
            )
            Text([Formatters.resetText(window.resetsAt, now: now), forecast.map { Formatters.forecastText($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(Ink.tertiary(contrast))
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

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isOn ? (configuration.isPressed ? Palette.coral.opacity(0.25) : Palette.coralSoft) : Color.clear)
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

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(Ink.tertiary(contrast)) }
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

        var body: some View {
            configuration.label
                .foregroundStyle(Ink.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isOn && isEnabled ? (configuration.isPressed ? Palette.coral.opacity(0.25) : Palette.coralSoft) : Color.clear)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .padding(.horizontal, 5)
                .onHover { hover.isOn = $0 }
        }
    }
}

/// `@State` needs the SwiftUI macro plugin, which the Command Line Tools lack.
final class HoverState: ObservableObject {
    @Published var isOn = false
}

// MARK: - Errors

/// What went wrong, how old the data on screen is, and what to do about it (TZ FR-8, FR-25).
struct ErrorNotice: View {
    let error: AppError
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
                Text(md(error.message))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let staleSince {
                    Text(Formatters.dataFromText(staleSince, now: now) + ".")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
                if !recoveries.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(recoveries, id: \.self) { recovery in
                            Button(recovery.title) { perform(recovery) }
                                .buttonStyle(NoticeButtonStyle())
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .background(shape.fill(configuration.isPressed ? Palette.coral.opacity(0.25) : hover.isOn ? Palette.coralSoft : Palette.surface))
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

extension EnvironmentValues {
    /// True while `PreviewRenderer` draws the popover to a PNG.
    var isPreviewRender: Bool {
        get { self[PreviewRenderKey.self] }
        set { self[PreviewRenderKey.self] = newValue }
    }
}
