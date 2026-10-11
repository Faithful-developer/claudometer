import AppKit
import ClaudometerCore
import Foundation
#if WIDGET_SUPPORT
import WidgetKit
#endif

/// `UserDefaults` keys and defaults (TZ FR-22). Views use `@AppStorage` with these keys;
/// non-view code reads the current values through `AppSettings.current`.
enum SettingsKey {
    static let refreshMinutes = "refreshMinutes"
    static let appearance = "appearance"
    static let menuBarMetric = "menuBarMetric"
    static let compactMenuBar = "compactMenuBar"
    static let menuBarPinnedLimits = "menuBarPinnedLimits"
    static let menuBarExtraRings = "menuBarExtraRings"
    static let menuBarExtraThreshold = "menuBarExtraThreshold"
    static let warningThreshold = "warningThreshold"
    static let criticalThreshold = "criticalThreshold"
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyLow = "notifyLow"
    static let notifyHigh = "notifyHigh"
    static let notifyReset = "notifyReset"
    static let notifyOutage = "notifyOutage"
    /// "system", "en" or "ru".
    static let language = "language"
    static let notifyUpdates = "notifyUpdates"
    /// Last release version announced in a notification, so each version alerts once.
    static let notifiedUpdateVersion = "notifiedUpdateVersion"
    /// Selected Settings tab, so other views can open Settings on a given tab.
    static let settingsTab = "settingsTab"
    /// Set once Open at Login has been turned on by default, so a later "off" sticks.
    static let loginItemOffered = "loginItemOffered"
    /// `ThresholdTracker` as JSON.
    static let notificationCycles = "notificationCycles"
    /// `OutageTracker` as JSON.
    static let outageTracker = "outageTracker"
    /// Replaced by `notificationCycles`; read once to migrate, then removed.
    static let legacyFiredNotifications = "firedNotifications"
    static let legacyNearLimitWindows = "nearLimitWindows"
}

struct AppSettings {
    var refreshMinutes: Int
    var menuBarMetric: MenuBarMetric
    var compactMenuBar: Bool
    var menuBarPinnedLimits: [String]
    var menuBarExtraRings: Bool
    var menuBarExtraThreshold: Double
    var warningThreshold: Double
    var criticalThreshold: Double
    var notificationsEnabled: Bool
    var notifyLow: Int
    var notifyHigh: Int
    var notifyReset: Bool
    var notifyOutage: Bool
    var notifyUpdates: Bool

    static let defaults: [String: Any] = [
        SettingsKey.refreshMinutes: 5,
        SettingsKey.appearance: AppAppearance.system.rawValue,
        SettingsKey.menuBarMetric: MenuBarMetric.session.rawValue,
        SettingsKey.compactMenuBar: false,
        SettingsKey.menuBarPinnedLimits: "",
        SettingsKey.menuBarExtraRings: true,
        SettingsKey.menuBarExtraThreshold: 80.0,
        SettingsKey.warningThreshold: 60.0,
        SettingsKey.criticalThreshold: 85.0,
        SettingsKey.notificationsEnabled: false,
        SettingsKey.notifyLow: 80,
        SettingsKey.notifyHigh: 95,
        SettingsKey.notifyReset: true,
        SettingsKey.notifyOutage: true,
        SettingsKey.language: "system",
        SettingsKey.notifyUpdates: true,
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
            menuBarPinnedLimits: MenuBarPins.decode(d.string(forKey: SettingsKey.menuBarPinnedLimits) ?? ""),
            menuBarExtraRings: d.bool(forKey: SettingsKey.menuBarExtraRings),
            menuBarExtraThreshold: d.double(forKey: SettingsKey.menuBarExtraThreshold),
            warningThreshold: d.double(forKey: SettingsKey.warningThreshold),
            criticalThreshold: d.double(forKey: SettingsKey.criticalThreshold),
            notificationsEnabled: d.bool(forKey: SettingsKey.notificationsEnabled),
            notifyLow: d.integer(forKey: SettingsKey.notifyLow),
            notifyHigh: d.integer(forKey: SettingsKey.notifyHigh),
            notifyReset: d.bool(forKey: SettingsKey.notifyReset),
            notifyOutage: d.bool(forKey: SettingsKey.notifyOutage),
            notifyUpdates: d.bool(forKey: SettingsKey.notifyUpdates)
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
            critical: settings.criticalThreshold,
            language: L10n.language
        ))
    }

    /// Switches the UI language right away; the widget follows on its next reload.
    static func setLanguage(_ preference: String) {
        L10n.resolve(preference)
        UserDefaults.standard.set(preference, forKey: SettingsKey.language)
        saveWidgetStyle()
        #if WIDGET_SUPPORT
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// The menu bar's rings for `snapshot` (FR-3, FR-27, FR-28).
    func menuBarWindows(_ snapshot: UsageSnapshot?) -> (primary: LimitWindow?, extras: [LimitWindow]) {
        snapshot?.menuBarWindows(metric: menuBarMetric, pinned: menuBarPinnedLimits,
                                 extraThreshold: menuBarExtraRings ? menuBarExtraThreshold : nil) ?? (nil, [])
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
        case .system: return tr("System")
        case .light: return tr("Light")
        case .dark: return tr("Dark")
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
