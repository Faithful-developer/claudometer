import ClaudometerCore
import Foundation
import UserNotifications

/// Local alerts when a limit crosses a threshold or resets (TZ FR-19…FR-21).
@MainActor
final class NotificationManager {
    private var tracker: ThresholdTracker

    /// `UNUserNotificationCenter` crashes in a process without a bundle (e.g. `swift run`).
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: SettingsKey.notificationCycles),
           let saved = try? JSONDecoder().decode(ThresholdTracker.self, from: data) {
            tracker = saved
        } else {
            // State of builds before per-cycle tracking; carried over so nothing fires again.
            tracker = ThresholdTracker(
                legacyFired: Set(d.stringArray(forKey: SettingsKey.legacyFiredNotifications) ?? []),
                nearLimit: Set(d.stringArray(forKey: SettingsKey.legacyNearLimitWindows) ?? [])
            )
        }
    }

    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func process(_ snapshot: UsageSnapshot, settings: AppSettings) {
        // Always evaluate so thresholds already passed before enabling do not fire later in bulk.
        let events = tracker.evaluate(
            snapshot,
            thresholds: [settings.notifyLow, settings.notifyHigh],
            notifyReset: settings.notifyReset
        )
        persist()
        guard settings.notificationsEnabled, Self.isAvailable else { return }
        for event in events { send(event, lowerThreshold: settings.notifyLow) }
    }

    /// Identifiers are per window and threshold, so a repeat replaces the banner instead of
    /// stacking a second one.
    private func send(_ event: ThresholdTracker.Event, lowerThreshold: Int) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        let identifier: String
        switch event {
        case .crossed(let window, let threshold):
            content.title = "\(window.title): \(Formatters.percent(window.utilization)) used"
            content.body = "Passed \(threshold)%. \(Formatters.resetText(window.resetsAt))."
            content.sound = threshold >= 95 ? .default : nil
            identifier = "\(window.id)|\(threshold)"
            // The second alert supersedes the first one still sitting in Notification Center.
            if threshold > lowerThreshold { center.removeDeliveredNotifications(withIdentifiers: ["\(window.id)|\(lowerThreshold)"]) }
        case .reset(let window):
            content.title = "\(window.title) has reset"
            content.body = "You're back to \(Formatters.percent(window.utilization)) used."
            identifier = "\(window.id)|reset"
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func persist() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(tracker) { d.set(data, forKey: SettingsKey.notificationCycles) }
        d.removeObject(forKey: SettingsKey.legacyFiredNotifications)
        d.removeObject(forKey: SettingsKey.legacyNearLimitWindows)
    }
}
