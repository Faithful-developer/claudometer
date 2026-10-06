import AppKit
import ClaudometerCore
import SwiftUI

@main
struct ClaudometerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // `App.init` runs once per launch, so a plain stored instance is enough here.
    private let store: UsageStore

    init() {
        AppSettings.register()
        PreviewRenderer.runIfRequested()
        // Agent app: no Dock icon even when launched without an Info.plist (`swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
        AppAppearance.applyCurrent()
        store = UsageStore()
        store.start()
        AppDelegate.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @AppStorage(SettingsKey.compactMenuBar) private var compact = false
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0

    var body: some View {
        let window = store.state.snapshot?.window(for: MenuBarMetric(rawValue: metric) ?? .session)
        let utilization = window?.utilization
        Image(nsImage: MenuBarIcon.image(
            utilization: utilization,
            level: UsageLevel.of(utilization, warning: warning, critical: critical),
            stale: store.state.isStale || store.state.error != nil,
            compact: compact,
            resetsAt: window?.resetsAt
        ))
    }
}

/// Handles `claudometer://` links, e.g. a click on the desktop widget (FR-14).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var store: UsageStore?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "claudometer" }) else { return }
        Task { @MainActor in Self.store?.refresh() }
    }
}
