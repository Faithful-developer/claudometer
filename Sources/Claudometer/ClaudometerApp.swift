import AppKit
import ClaudometerCore
import SwiftUI
import UserNotifications

@main
struct ClaudometerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // `App.init` runs once per launch, so a plain stored instance is enough here.
    private let store: UsageStore
    private let updates = UpdateStore()

    init() {
        AppSettings.register()
        L10n.resolve(UserDefaults.standard.string(forKey: SettingsKey.language))
        PreviewRenderer.runIfRequested()
        // Agent app: no Dock icon even when launched without an Info.plist (`swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
        AppAppearance.applyCurrent()
        LoginItem.enableOnFirstLaunch()
        store = UsageStore()
        store.start()
        updates.start()
        CheckInService.start()
        AppDelegate.store = store
        AppDelegate.updates = updates
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
                .environment(updates)
        } label: {
            MenuBarLabel(store: store, updates: updates)
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
    let updates: UpdateStore
    // Redraws the icon's VoiceOver text in a new language.
    @AppStorage(SettingsKey.language) private var language = "system"
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @AppStorage(SettingsKey.compactMenuBar) private var compact = false
    @AppStorage(SettingsKey.menuBarPinnedLimits) private var pinned = ""
    @AppStorage(SettingsKey.menuBarExtraRings) private var extraRings = true
    @AppStorage(SettingsKey.menuBarExtraThreshold) private var extraThreshold = 80.0
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0

    var body: some View {
        let snapshot = store.state.snapshot
        let rings = snapshot?.menuBarWindows(metric: MenuBarMetric(rawValue: metric) ?? .session,
                                             pinned: MenuBarPins.decode(pinned),
                                             extraThreshold: extraRings ? extraThreshold : nil)
        Image(nsImage: MenuBarIcon.image(
            primary: MenuBarIcon.Ring(window: rings?.primary, level: level(rings?.primary)),
            extras: (rings?.extras ?? []).map { MenuBarIcon.Ring(window: $0, level: level($0), letter: true) },
            stale: store.state.isStale || store.state.error != nil,
            compact: compact,
            updateBadge: updates.available != nil
        ))
        .onAppear { SettingsWindow.openAction = openSettings }
    }

    private func level(_ window: LimitWindow?) -> UsageLevel {
        UsageLevel.of(window?.utilization, warning: warning, critical: critical)
    }
}

/// Handles `claudometer://` links, e.g. a click on the desktop widget (FR-14), and clicks on
/// the update notification.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var store: UsageStore?
    @MainActor static var updates: UpdateStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if NotificationManager.isAvailable { UNUserNotificationCenter.current().delegate = self }
            NotificationManager.registerCategories()
        }
    }

    /// Without a delegate, alerts are hidden while the app is active (e.g. Settings is open).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard response.notification.request.identifier == NotificationManager.updateIdentifier else { return }
        let url = (content.userInfo["url"] as? String).flatMap(URL.init(string:)) ?? UpdateChecker.releasesPage
        let install = response.actionIdentifier == NotificationManager.installAction
        await MainActor.run {
            if install, let updates = Self.updates, updates.canInstall {
                updates.installUpdate()
            } else {
                _ = NSWorkspace.shared.open(url)
            }
        }
    }

    /// A widget click refreshes, and when the problem needs the user (login expired, signed
    /// out, …) also opens Settings where it's fixed: the menu bar popover can't be opened from
    /// code, and an accessory app would otherwise show nothing.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "claudometer" }) else { return }
        Task { @MainActor in
            guard let store = Self.store else { return }
            store.refresh()
            switch store.state.error {
            case .notSignedIn?, .tokenExpired?, .sessionKeyInvalid?, .keychainDenied?: SettingsWindow.open(tab: .login)
            case .apiChanged?: SettingsWindow.open(tab: .about)
            default: break
            }
        }
    }
}
