import ClaudometerCore
import Foundation
import os

/// Sends the daily check-in (`CheckIn`) at most once a UTC day. Settings › General › Privacy
/// turns it off (as does `defaults write dev.claudometer.app sendCheckIn -bool false`), which
/// also forgets the ID.
@MainActor
enum CheckInService {
    /// The Settings switch changed: turned off, the ID is forgotten right away, not at the next hourly pass.
    static func settingChanged() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKey.sendCheckIn) else { return }
        defaults.removeObject(forKey: SettingsKey.checkInID)
        defaults.removeObject(forKey: SettingsKey.checkInLastSent)
    }

    private static var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "dev.claudometer.app", category: "checkin")

    static func start() {
        // `swift run` and preview renders aren't real installs.
        guard task == nil, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil else { return }
        task = Task {
            while !Task.isCancelled {
                await sendIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private static func sendIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.sendCheckIn) else {
            defaults.removeObject(forKey: SettingsKey.checkInID)
            defaults.removeObject(forKey: SettingsKey.checkInLastSent)
            return
        }
        guard CheckIn.isDue(lastSent: defaults.object(forKey: SettingsKey.checkInLastSent) as? Date) else { return }
        let id = defaults.string(forKey: SettingsKey.checkInID) ?? {
            let new = UUID().uuidString.lowercased()
            defaults.set(new, forKey: SettingsKey.checkInID)
            return new
        }()
        let checkIn = CheckIn(id: id, version: UpdateStore.currentVersion, language: L10n.language, os: CheckIn.osVersion)
        do {
            try await checkIn.send()
            // Switched off while sending: don't bring the ID back.
            guard defaults.bool(forKey: SettingsKey.sendCheckIn) else { return }
            defaults.set(Date(), forKey: SettingsKey.checkInLastSent)
            log.info("Check-in sent")
        } catch {
            // Offline etc.: try again next hour.
            log.info("Check-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
