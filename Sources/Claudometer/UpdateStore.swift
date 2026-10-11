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
    private(set) var installState: InstallState = .idle

    enum InstallState: Equatable {
        case idle
        case downloading(Double)
        /// Verifying, unpacking, then quitting to swap the apps.
        case installing
        case failed(String)
    }

    /// One-click install is offered when the release has a verifiable DMG and this copy of
    /// the app can be replaced where it is; otherwise the release page is the way.
    var canInstall: Bool { available?.download != nil && UpdateInstaller.replaceableApp != nil }

    var isInstalling: Bool {
        switch installState {
        case .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }

    @ObservationIgnored private let checker = UpdateChecker()
    @ObservationIgnored private var task: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            // `--install-update` installs whatever the first check finds, for testing the
            // whole update path from a build with a lower version.
            let installNow = CommandLine.arguments.contains("--install-update")
            while !Task.isCancelled {
                await self?.check(manual: false)
                if installNow, self?.installState == .idle { self?.installUpdate() }
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
            UpdateInstaller.log.info("Checked for updates: \(self.available?.version ?? "up to date", privacy: .public)")
            if let available { announce(available, notify: !manual) }
            if manual { lastResult = available.map { tr("Version %@ is available.", $0.version) } ?? tr("You’re up to date.") }
        } catch {
            UpdateInstaller.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
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

    /// Installs the available update in place and relaunches. On failure the state says why,
    /// and the release page stays available.
    func installUpdate() {
        guard let release = available, canInstall, !isInstalling else {
            UpdateInstaller.log.info("Install not offered: release \(self.available?.version ?? "none", privacy: .public), download \(self.available?.download != nil), replaceable \(UpdateInstaller.replaceableApp != nil)")
            return
        }
        installState = .downloading(0)
        Task {
            do {
                try await UpdateInstaller.install(release) { [weak self] fraction in
                    guard let self else { return }
                    self.installState = fraction < 1 ? .downloading(fraction) : .installing
                }
            } catch let failure as UpdateInstaller.Failure {
                installState = .failed(failure.message)
            } catch {
                installState = .failed(UpdateInstaller.Failure.install.message)
            }
        }
    }

    func openDownload() {
        NSWorkspace.shared.open(available?.pageURL ?? UpdateChecker.releasesPage)
    }
}
