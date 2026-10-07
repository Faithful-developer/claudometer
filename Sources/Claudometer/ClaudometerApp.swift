import AppKit
import ClaudometerCore
import SwiftUI

@main
struct ClaudometerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // `App.init` runs once per launch, so a plain stored instance is enough here.
    private let store: UsageStore
    private let updates = UpdateStore()

    init() {
        AppSettings.register()
        PreviewRenderer.runIfRequested()
        // Agent app: no Dock icon even when launched without an Info.plist (`swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
        AppAppearance.applyCurrent()
        store = UsageStore()
        store.start()
        updates.start()
        AppDelegate.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
                .environment(updates)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(updates)
        }
    }
}

struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @AppStorage(SettingsKey.compactMenuBar) private var compact = false
    @AppStorage(SettingsKey.menuBarExtraRings) private var extraRings = true
    @AppStorage(SettingsKey.menuBarExtraThreshold) private var extraThreshold = 80.0
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0

    var body: some View {
        let snapshot = store.state.snapshot
        let window = snapshot?.window(for: MenuBarMetric(rawValue: metric) ?? .session)
        let extras = extraRings ? snapshot?.highWindows(excluding: window, from: extraThreshold) ?? [] : []
        Image(nsImage: MenuBarIcon.image(
            primary: MenuBarIcon.Ring(window: window, level: level(window)),
            extras: extras.map { MenuBarIcon.Ring(window: $0, level: level($0), letter: true) },
            stale: store.state.isStale || store.state.error != nil,
            compact: compact
        ))
    }

    private func level(_ window: LimitWindow?) -> UsageLevel {
        UsageLevel.of(window?.utilization, warning: warning, critical: critical)
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
