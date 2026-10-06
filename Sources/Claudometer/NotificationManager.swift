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
        tracker = ThresholdTracker(
            fired: Set(d.stringArray(forKey: SettingsKey.firedNotifications) ?? []),
            nearLimit: Set(d.stringArray(forKey: SettingsKey.nearLimitWindows) ?? [])
        )
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
        for event in events { send(event) }
    }

    private func send(_ event: ThresholdTracker.Event) {
        let content = UNMutableNotificationContent()
        switch event {
        case .crossed(let window, let threshold):
            content.title = "\(window.title): \(Formatters.percent(window.utilization)) used"
            content.body = "Passed \(threshold)%. \(Formatters.resetText(window.resetsAt))."
            content.sound = threshold >= 95 ? .default : nil
        case .reset(let window):
            content.title = "\(window.title) has reset"
            content.body = "You're back to \(Formatters.percent(window.utilization)) used."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Array(tracker.fired), forKey: SettingsKey.firedNotifications)
        d.set(Array(tracker.nearLimit), forKey: SettingsKey.nearLimitWindows)
    }
}
