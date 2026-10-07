import AppKit
import ClaudometerCore
import Foundation

/// `UserDefaults` keys and defaults (TZ FR-22). Views use `@AppStorage` with these keys;
/// non-view code reads the current values through `AppSettings.current`.
enum SettingsKey {
    static let refreshMinutes = "refreshMinutes"
    static let appearance = "appearance"
    static let menuBarMetric = "menuBarMetric"
    static let compactMenuBar = "compactMenuBar"
    static let warningThreshold = "warningThreshold"
    static let criticalThreshold = "criticalThreshold"
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyLow = "notifyLow"
    static let notifyHigh = "notifyHigh"
    static let notifyReset = "notifyReset"
    /// `ThresholdTracker` as JSON.
    static let notificationCycles = "notificationCycles"
    /// Replaced by `notificationCycles`; read once to migrate, then removed.
    static let legacyFiredNotifications = "firedNotifications"
    static let legacyNearLimitWindows = "nearLimitWindows"
}

struct AppSettings {
    var refreshMinutes: Int
    var menuBarMetric: MenuBarMetric
    var compactMenuBar: Bool
    var warningThreshold: Double
    var criticalThreshold: Double
    var notificationsEnabled: Bool
    var notifyLow: Int
    var notifyHigh: Int
    var notifyReset: Bool

    static let defaults: [String: Any] = [
        SettingsKey.refreshMinutes: 5,
        SettingsKey.appearance: AppAppearance.system.rawValue,
        SettingsKey.menuBarMetric: MenuBarMetric.session.rawValue,
        SettingsKey.compactMenuBar: false,
        SettingsKey.warningThreshold: 60.0,
        SettingsKey.criticalThreshold: 85.0,
        SettingsKey.notificationsEnabled: false,
        SettingsKey.notifyLow: 80,
        SettingsKey.notifyHigh: 95,
        SettingsKey.notifyReset: true,
    ]

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static var current: AppSettings {
        let d = UserDefaults.standard
        return AppSettings(
            refreshMinutes: min(max(d.integer(forKey: SettingsKey.refreshMinutes), 1), 30),
            menuBarMetric: MenuBarMetric(rawValue: d.string(forKey: SettingsKey.menuBarMetric) ?? "") ?? .session,
            compactMenuBar: d.bool(forKey: SettingsKey.compactMenuBar),
            warningThreshold: d.double(forKey: SettingsKey.warningThreshold),
            criticalThreshold: d.double(forKey: SettingsKey.criticalThreshold),
            notificationsEnabled: d.bool(forKey: SettingsKey.notificationsEnabled),
            notifyLow: d.integer(forKey: SettingsKey.notifyLow),
            notifyHigh: d.integer(forKey: SettingsKey.notifyHigh),
            notifyReset: d.bool(forKey: SettingsKey.notifyReset)
        )
    }

    /// True in the Xcode build that embeds the widget (sets `WIDGET_SUPPORT`).
    static var widgetSupport: Bool {
        #if WIDGET_SUPPORT
        return true
        #else
        return false
        #endif
    }

    /// Writes the values the widget needs next to the usage state (FR-23).
    static func saveWidgetStyle() {
        let settings = current
        SnapshotStore.saveStyle(WidgetStyle(
            metric: settings.menuBarMetric,
            warning: settings.warningThreshold,
            critical: settings.criticalThreshold
        ))
    }

    func level(for utilization: Double?) -> UsageLevel {
        UsageLevel.of(utilization, warning: warningThreshold, critical: criticalThreshold)
    }
}

/// Follows the system light/dark setting by default; can be pinned to one.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    static func applyCurrent() {
        let value = AppAppearance(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "") ?? .system
        switch value {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
