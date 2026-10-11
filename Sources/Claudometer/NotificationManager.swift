import ClaudometerCore
import Foundation
import UserNotifications

/// Local alerts when a limit crosses a threshold or resets (TZ FR-19…FR-21), and when usage
/// stops updating.
@MainActor
final class NotificationManager {
    private var tracker: ThresholdTracker
    private var outage: OutageTracker
    nonisolated static let outageIdentifier = "outage"
    nonisolated static let updateIdentifier = "update"
    nonisolated static let installAction = "install"

    /// "Install Update" button on the update notification.
    static func registerCategories() {
        guard isAvailable else { return }
        let install = UNNotificationAction(identifier: installAction, title: tr("Install Update"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: updateIdentifier, actions: [install], intentIdentifiers: [])
        ])
    }

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
        outage = d.data(forKey: SettingsKey.outageTracker)
            .flatMap { try? JSONDecoder().decode(OutageTracker.self, from: $0) } ?? OutageTracker()
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

    /// After every fetch: `error` is nil on success. `fetchedAt` is the last known data's time.
    func processOutage(error: AppError?, fetchedAt: Date?, settings: AppSettings) {
        // Always evaluate, so an outage that began while alerts were off doesn't fire later.
        let previous = outage
        let event = outage.record(error: error)
        if outage != previous, let data = try? JSONEncoder().encode(outage) {
            UserDefaults.standard.set(data, forKey: SettingsKey.outageTracker)
        }
        guard let event, Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        switch event {
        case .recovered:
            center.removeDeliveredNotifications(withIdentifiers: [Self.outageIdentifier])
        case .stopped(let error):
            guard settings.notifyOutage else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("Claudometer can’t update usage")
            content.body = [error.message.replacingOccurrences(of: "`", with: ""),
                            fetchedAt.map { Formatters.dataFromText($0) + "." }]
                .compactMap { $0 }.joined(separator: " ")
            let request = UNNotificationRequest(identifier: Self.outageIdentifier, content: content, trigger: nil)
            // On by default, so permission may not have been asked yet; the system asks only once.
            Task {
                guard await Self.requestAuthorization() else { return }
                try? await center.add(request)
            }
        }
    }

    /// A newer release; clicking it opens the download page (see `AppDelegate`).
    static func sendUpdate(_ release: AppRelease) {
        let content = UNMutableNotificationContent()
        content.title = tr("Claudometer %@ is available", release.version)
        content.body = tr("Click Install Update to update in place, or click here for the release notes.")
        content.categoryIdentifier = updateIdentifier
        content.userInfo = ["url": release.pageURL.absoluteString]
        let request = UNNotificationRequest(identifier: updateIdentifier, content: content, trigger: nil)
        Task {
            guard await requestAuthorization() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Identifiers are per window and threshold, so a repeat replaces the banner instead of
    /// stacking a second one.
    private func send(_ event: ThresholdTracker.Event, lowerThreshold: Int) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        let identifier: String
        switch event {
        case .crossed(let window, let threshold):
            content.title = tr("%@: %@ used", window.title, Formatters.percent(window.utilization))
            content.body = tr("Passed %lld%%. %@.", threshold, Formatters.resetText(window.resetsAt))
            content.sound = threshold >= 95 ? .default : nil
            identifier = "\(window.id)|\(threshold)"
            // The second alert supersedes the first one still sitting in Notification Center.
            if threshold > lowerThreshold { center.removeDeliveredNotifications(withIdentifiers: ["\(window.id)|\(lowerThreshold)"]) }
        case .reset(let window):
            content.title = tr("%@ has reset", window.title)
            content.body = tr("You’re back to %@ used.", Formatters.percent(window.utilization))
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
