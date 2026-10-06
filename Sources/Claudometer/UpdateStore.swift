import AppKit
import ClaudometerCore
import Foundation
import Observation

/// Checks GitHub Releases at launch and once a day; the popover and About tab show the result.
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
            if manual { lastResult = "Update checks need the bundled app." }
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            available = try await checker.check(currentVersion: Self.currentVersion)
            if manual { lastResult = available.map { "Version \($0.version) is available." } ?? "You're up to date." }
        } catch {
            // Background checks fail quietly (offline etc.); only a manual check reports it.
            if manual { lastResult = "Couldn't check for updates." }
        }
    }

    func openDownload() {
        NSWorkspace.shared.open(available?.pageURL ?? UpdateChecker.releasesPage)
    }
}
