import AppKit
import ClaudometerCore
import Foundation
import Observation

/// Checks GitHub Releases at launch and once a day; the popover, About tab and a dot on the
/// menu bar icon show the result, and each new version is announced once in a notification.
@MainActor
@Observable
final class UpdateStore {
    private(set) var available: AppRelease?
    private(set) var isChecking = false
    /// Result of the last manual check, for the About tab.
    private(set) var lastResult: String?

    @ObservationIgnored private let checker = UpdateChecker()
    @ObservationIgnored private var task: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(manual: false)
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check(manual: Bool) async {
        // `swift run` has no bundle version; don't offer every release as an update.
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil else {
            if manual { lastResult = tr("Update checks need the bundled app.") }
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            available = try await checker.check(currentVersion: Self.currentVersion)
            if let available { announce(available, notify: !manual) }
            if manual { lastResult = available.map { tr("Version %@ is available.", $0.version) } ?? tr("You’re up to date.") }
        } catch {
            // Background checks fail quietly (offline etc.); only a manual check reports it.
            if manual { lastResult = tr("Couldn’t check for updates.") }
        }
    }

    /// Once per version: a relaunch, restart or the next daily check doesn't repeat it. A
    /// manual check counts as seen, since About already shows the result.
    private func announce(_ release: AppRelease, notify: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: SettingsKey.notifiedUpdateVersion) != release.version else { return }
        defaults.set(release.version, forKey: SettingsKey.notifiedUpdateVersion)
        guard notify, AppSettings.current.notifyUpdates, NotificationManager.isAvailable else { return }
        NotificationManager.sendUpdate(release)
    }

    func openDownload() {
        NSWorkspace.shared.open(available?.pageURL ?? UpdateChecker.releasesPage)
    }
}
