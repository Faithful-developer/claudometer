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
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @Environment(\.isPreviewRender) private var isPreviewRender
    @Environment(\.colorSchemeContrast) private var contrast

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
        .frame(width: 300)
        .background { if !isPreviewRender { MenuBackground() } }
        .fitsMenuWindowHeight()
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claudometer").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.primary)
            Spacer()
            if let plan = Formatters.planName(store.state.snapshot?.plan) {
                Text("\(plan) plan").font(.system(size: 12)).foregroundStyle(Ink.secondary)
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

        VStack(alignment: .leading, spacing: 0) {
            if let error = store.state.error {
                ErrorNotice(error: error, stale: stale).padding(.horizontal, 14).padding(.vertical, 6)
            }

            if let hero {
                HeroRow(window: hero, level: level(hero), stale: stale, now: now)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            } else if store.state.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").foregroundStyle(Ink.secondary)
                }
                .font(.system(size: 13))
                .padding(14)
            }

            if !others.isEmpty {
                MenuDivider()
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(others.allSatisfy { $0.group == .weekly } ? "Weekly Limits" : "Limits")
                    ForEach(others) { window in
                        LimitRow(window: window, level: level(window), stale: stale, now: now)
                    }
                    if (snapshot?.windows ?? []).contains(where: { $0.elapsedFraction(now: now) != nil }) {
                        PaceLegend()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if let breakdown = snapshot?.breakdown, breakdown.contains(where: { $0.percent > 0 }) {
                MenuDivider()
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Usage by Surface This Week")
                    // Stale: series fills go grey; the text keeps its full-contrast ink.
                    BreakdownChart(rows: breakdown, dimmed: stale)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    if store.isLoading {
                        Text("Updating…")
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
            MenuRow(title: "Refresh Now", shortcut: "⌘R") { store.refresh() }
                .keyboardShortcut("r")
                .disabled(store.isLoading)
            if isPreviewRender {
                MenuRowLabel(title: "Settings…", shortcut: "⌘,").padding(.horizontal, 5)
            } else {
                SettingsLink { MenuRowLabel(title: "Settings…", shortcut: "⌘,") }
                    .buttonStyle(MenuRowStyle())
                    .keyboardShortcut(",")
            }
            MenuRow(title: "Quit Claudometer", shortcut: "⌘Q") { NSApp.terminate(nil) }
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

    var body: some View {
        HStack(spacing: 14) {
            RingGauge(fraction: window.utilization / 100, level: stale ? .unknown : level, lineWidth: 7) {
                PercentText(window.utilization, size: 18, dimmed: stale)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(window.group == .session ? "Current Session" : window.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Formatters.resetText(window.resetsAt, now: now))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
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
            Text(Formatters.resetText(window.resetsAt, now: now))
                .font(.system(size: 11))
                .foregroundStyle(Ink.tertiary(contrast))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatters.accessibilityLabel(window, level: level, stale: stale, now: now))
    }
}

/// Explains the tick on the meters.
struct PaceLegend: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(Ink.secondary).frame(width: 2, height: 10)
            Text("Time elapsed in the window")
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

struct ErrorNotice: View {
    let error: AppError
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Palette.warningGlyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(error.message))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if stale {
                    Text("Showing last known data.").font(.system(size: 11)).foregroundStyle(Ink.secondary)
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
