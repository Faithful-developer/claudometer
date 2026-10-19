import ClaudometerCore
import Foundation
import UserNotifications

/// Local alerts when a limit crosses a threshold or resets (TZ FR-19…FR-21), and when usage
/// stops updating.
@MainActor
final class NotificationManager {
    /// Per account (TZ F-2), loaded on first use.
    private var trackers: [String: ThresholdTracker] = [:]
    private var outages: [String: OutageTracker] = [:]
    /// The shared "no connection" alert is out; cleared when any account recovers.
    private var offlineAlerted = false
    nonisolated static let outageIdentifier = "outage"
    nonisolated static let offlineIdentifier = "outage|offline"
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

    init() {}

    /// Defaults keys: the Claude Code account keeps the ones used before accounts existed.
    private static func key(_ base: String, account: String) -> String {
        account == Account.primaryID ? base : "\(base).\(account)"
    }

    private func tracker(for account: String) -> ThresholdTracker {
        if let tracker = trackers[account] { return tracker }
        let d = UserDefaults.standard
        let tracker: ThresholdTracker
        if let data = d.data(forKey: Self.key(SettingsKey.notificationCycles, account: account)),
           let saved = try? JSONDecoder().decode(ThresholdTracker.self, from: data) {
            tracker = saved
        } else if account == Account.primaryID {
            // State of builds before per-cycle tracking; carried over so nothing fires again.
            tracker = ThresholdTracker(
                legacyFired: Set(d.stringArray(forKey: SettingsKey.legacyFiredNotifications) ?? []),
                nearLimit: Set(d.stringArray(forKey: SettingsKey.legacyNearLimitWindows) ?? [])
            )
        } else {
            tracker = ThresholdTracker()
        }
        trackers[account] = tracker
        return tracker
    }

    private func outage(for account: String) -> OutageTracker {
        if let outage = outages[account] { return outage }
        let outage = UserDefaults.standard.data(forKey: Self.key(SettingsKey.outageTracker, account: account))
            .flatMap { try? JSONDecoder().decode(OutageTracker.self, from: $0) } ?? OutageTracker()
        outages[account] = outage
        return outage
    }

    /// A removed account: drops its saved state and its alerts still on screen.
    func forget(account: String) {
        trackers[account] = nil
        outages[account] = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.key(SettingsKey.notificationCycles, account: account))
        d.removeObject(forKey: Self.key(SettingsKey.outageTracker, account: account))
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let prefix = NotificationID.make(account: account, "")
            let ids = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// `label` names the account in the alert's title; nil while there's only one.
    func process(_ snapshot: UsageSnapshot, account: String, label: String?, settings: AppSettings) {
        // Always evaluate so thresholds already passed before enabling do not fire later in bulk.
        var tracker = tracker(for: account)
        let events = tracker.evaluate(
            snapshot,
            thresholds: [settings.notifyLow, settings.notifyHigh],
            notifyReset: settings.notifyReset
        )
        trackers[account] = tracker
        persist(tracker, account: account)
        guard settings.notificationsEnabled, Self.isAvailable else { return }
        for event in events { send(event, account: account, label: label, lowerThreshold: settings.notifyLow) }
    }

    /// After every fetch: `error` is nil on success. `fetchedAt` is the last known data's time.
    func processOutage(error: AppError?, fetchedAt: Date?, account: String, label: String?, settings: AppSettings) {
        // Always evaluate, so an outage that began while alerts were off doesn't fire later.
        let previous = outage(for: account)
        var outage = previous
        let event = outage.record(error: error)
        outages[account] = outage
        if outage != previous, let data = try? JSONEncoder().encode(outage) {
            UserDefaults.standard.set(data, forKey: Self.key(SettingsKey.outageTracker, account: account))
        }
        guard let event, Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        var identifier = NotificationID.make(account: account, Self.outageIdentifier)
        var label = label
        switch event {
        case .recovered:
            // Back online is back for every account.
            offlineAlerted = false
            center.removeDeliveredNotifications(withIdentifiers: [identifier, Self.offlineIdentifier])
        case .stopped(let error):
            guard settings.notifyOutage else { return }
            // No connection stops every account at once: one alert, without an account name.
            if error == .offline {
                guard !offlineAlerted else { return }
                offlineAlerted = true
                identifier = Self.offlineIdentifier
                label = nil
            }
            let content = UNMutableNotificationContent()
            content.title = Self.titled(tr("Claudometer can’t update usage"), label: label)
            content.body = [error.message.replacingOccurrences(of: "`", with: ""),
                            fetchedAt.map { Formatters.dataFromText($0) + "." }]
                .compactMap { $0 }.joined(separator: " ")
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
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
    private func send(_ event: ThresholdTracker.Event, account: String, label: String?, lowerThreshold: Int) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        let identifier: String
        switch event {
        case .crossed(let window, let threshold):
            content.title = Self.titled(tr("%@: %@ used", window.title, Formatters.percent(window.utilization)), label: label)
            content.body = tr("Passed %lld%%. %@.", threshold, Formatters.resetText(window.resetsAt))
            content.sound = threshold >= 95 ? .default : nil
            identifier = NotificationID.make(account: account, "\(window.id)|\(threshold)")
            // The second alert supersedes the first one still sitting in Notification Center.
            if threshold > lowerThreshold {
                center.removeDeliveredNotifications(withIdentifiers: [NotificationID.make(account: account, "\(window.id)|\(lowerThreshold)")])
            }
        case .reset(let window):
            content.title = Self.titled(tr("%@ has reset", window.title), label: label)
            content.body = tr("You’re back to %@ used.", Formatters.percent(window.utilization))
            identifier = NotificationID.make(account: account, "\(window.id)|reset")
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// "Work · Session (5h): 82% used" once there's more than one account.
    private static func titled(_ title: String, label: String?) -> String {
        label.map { "\($0) · \(title)" } ?? title
    }

    private func persist(_ tracker: ThresholdTracker, account: String) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(tracker) {
            d.set(data, forKey: Self.key(SettingsKey.notificationCycles, account: account))
        }
        guard account == Account.primaryID else { return }
        d.removeObject(forKey: SettingsKey.legacyFiredNotifications)
        d.removeObject(forKey: SettingsKey.legacyNearLimitWindows)
    }
}
