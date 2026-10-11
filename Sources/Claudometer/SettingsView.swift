import AppKit
import ClaudometerCore
import ServiceManagement
import SwiftUI

/// Settings window (TZ FR-22), laid out like system apps: toolbar tabs with grouped forms.
struct SettingsView: View {
    @AppStorage(SettingsKey.settingsTab) private var tab = SettingsTab.general
    @AppStorage(SettingsKey.language) private var language = "system"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label(tr("General"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            NotificationSettings()
                .tabItem { Label(tr("Notifications"), systemImage: "bell.badge") }
                .tag(SettingsTab.notifications)
            LoginSettings()
                .tabItem { Label(tr("Login"), systemImage: "person.badge.key") }
                .tag(SettingsTab.login)
            AboutSettings()
                .tabItem { Label(tr("About"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // Rebuilt in a new language; `tr` reads it when the views are created.
        .id(language)
        .frame(width: 460)
        .onHostingWindow(SettingsWindow.attach)
    }
}

enum SettingsTab: String {
    case general, notifications, login, about
}

/// Keeps the Settings window on the user's current desktop and in front of other apps.
/// An accessory app isn't frontmost, so without this the window can open behind them.
@MainActor
enum SettingsWindow {
    private static weak var window: NSWindow?
    /// Kept from the menu bar label (always on screen), so code outside SwiftUI views, like
    /// a widget click, can open Settings too.
    static var openAction: OpenSettingsAction?

    /// Opens Settings without a view at hand; see `openAction`.
    static func open(tab: SettingsTab) {
        guard let openAction else { return }
        open(openAction, tab: tab)
    }

    /// Settings… in the menu: open the window, or reuse the open one, and bring it forward.
    /// With `tab`, switches to that tab (also in a window that's already open).
    static func open(_ openSettings: OpenSettingsAction, tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsKey.settingsTab) }
        activate()
        openSettings()
        // Close the menu first: if focus goes back to the previous app, its windows come up,
        // and Settings has to go on top of them afterwards.
        DispatchQueue.main.async {
            MenuBarMenu.close()
            DispatchQueue.main.async { bringForward() }
        }
    }

    fileprivate static func attach(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
        // Settings… from another desktop brings the window here instead of switching desktops.
        window.collectionBehavior.insert(.moveToActiveSpace)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        bringForward()
    }

    private static func bringForward() {
        guard let window else { return }
        activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// macOS doesn't let an accessory app (no Dock icon) take focus from the frontmost app,
    /// even right after a click in its menu. So while Settings is open Claudometer is a regular
    /// app, with a Dock icon, and goes back to accessory when the window closes.
    private static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct GeneralSettings: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(SettingsKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingsKey.language) private var language = "system"
    @AppStorage(SettingsKey.refreshMinutes) private var refreshMinutes = 5
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @AppStorage(SettingsKey.compactMenuBar) private var compact = false
    @AppStorage(SettingsKey.menuBarPinnedLimits) private var pinned = ""
    @AppStorage(SettingsKey.menuBarExtraRings) private var extraRings = true
    @AppStorage(SettingsKey.menuBarExtraThreshold) private var extraThreshold = 80.0
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0
    @StateObject private var loginItem = LoginItem()

    /// Limits that can be added next to the main one (FR-28). With "Highest" the main limit
    /// changes as usage moves, so every limit is offered and the menu bar skips the duplicate.
    private var addableWindows: [LimitWindow]? {
        guard let snapshot = store.state.snapshot else { return nil }
        let metric = MenuBarMetric(rawValue: metric) ?? .session
        let main = metric == .highest ? nil : snapshot.window(for: metric)
        return snapshot.windows.filter { $0.id != main?.id }
    }

    private func isPinned(_ id: String) -> Binding<Bool> {
        Binding(
            get: { MenuBarPins.decode(pinned).contains(id) },
            set: { on in
                var ids = MenuBarPins.decode(pinned).filter { $0 != id }
                if on { ids.append(id) }
                pinned = MenuBarPins.encode(ids)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(tr("Appearance"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker(tr("Language"), selection: Binding(get: { language }, set: { AppSettings.setLanguage($0) })) {
                    Text(tr("Same as macOS")).tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
                Toggle(tr("Open at Login"), isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if let error = loginItem.error {
                    Label {
                        Text(error).foregroundStyle(Ink.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.criticalGlyph)
                    }
                    .font(.caption)
                }
            }

            Section {
                Picker(tr("Show"), selection: $metric) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if let windows = addableWindows {
                    if !windows.isEmpty {
                        let full = windows.filter { MenuBarPins.decode(pinned).contains($0.id) }.count >= MenuBarPins.maxPinned
                        LabeledContent(tr("Always show")) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(windows) { window in
                                    let ticked = isPinned(window.id)
                                    Toggle(isOn: ticked) {
                                        Label {
                                            Text(window.settingsTitle)
                                        } icon: {
                                            BadgeGlyph(letter: window.badgeLetter, enabled: ticked.wrappedValue || !full)
                                        }
                                    }
                                    .disabled(full && !ticked.wrappedValue)
                                }
                            }
                        }
                    }
                } else {
                    LabeledContent(tr("Always show")) {
                        Text(store.state.error == .notSignedIn ? tr("Sign in on the Login tab first.") : tr("Available after the first update."))
                            .font(.callout)
                            .foregroundStyle(Ink.secondary)
                    }
                }
                Toggle(tr("Show percentage"), isOn: Binding(get: { !compact }, set: { compact = !$0 }))
                Toggle(tr("Show other limits when high"), isOn: $extraRings)
                ThresholdSlider(title: tr("At or above"), symbol: "circle.dotted", tint: Ink.secondary, value: $extraThreshold, range: 50...100)
                    .disabled(!extraRings)
            } header: {
                Text(tr("Menu Bar"))
            } footer: {
                FormNote(tr("Always show up to two limits. Other limits get a ring when they reach this level, up to three rings in all."))
            }

            Section {
                ThresholdSlider(title: tr("Warning"), symbol: "exclamationmark.triangle.fill", tint: Palette.warningGlyph, value: $warning, range: 10...95)
                ThresholdSlider(title: tr("Critical"), symbol: "exclamationmark.octagon.fill", tint: Palette.criticalGlyph, value: $critical, range: 15...100)
            } header: {
                Text(tr("Highlight Levels"))
            } footer: {
                FormNote(tr("Meters and the menu bar icon change colour above these levels."))
            }

            Section(tr("Updates")) {
                Picker(tr("Check usage"), selection: $refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                        Text(minutes == 1 ? tr("Every minute") : tr("Every %lld minutes", minutes)).tag(minutes)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance) { AppAppearance.applyCurrent() }
        .onChange(of: refreshMinutes) { store.restartPolling() }
        .onChange(of: metric) { AppSettings.saveWidgetStyle() }
        .onChange(of: warning) {
            if critical < warning { critical = warning }
            AppSettings.saveWidgetStyle()
        }
        .onChange(of: critical) {
            if warning > critical { warning = critical }
            AppSettings.saveWidgetStyle()
        }
    }
}

struct NotificationSettings: View {
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = false
    @AppStorage(SettingsKey.notifyLow) private var notifyLow = 80
    @AppStorage(SettingsKey.notifyHigh) private var notifyHigh = 95
    @AppStorage(SettingsKey.notifyReset) private var notifyReset = true
    @AppStorage(SettingsKey.notifyOutage) private var notifyOutage = true
    @AppStorage(SettingsKey.notifyUpdates) private var notifyUpdates = true

    var body: some View {
        Form {
            // Limit alerts with the settings they control, so it's clear why those dim when off.
            Section {
                Toggle(isOn: $notificationsEnabled) {
                    Text(tr("Notify when a limit gets close"))
                    Text(tr("At the levels below, once per limit until it resets."))
                }
                Group {
                    ThresholdSlider(title: tr("First alert"), symbol: "bell.fill", tint: Palette.warningGlyph, value: percent($notifyLow), range: 50...95)
                    ThresholdSlider(title: tr("Second alert"), symbol: "bell.badge.fill", tint: Palette.criticalGlyph, value: percent($notifyHigh), range: 50...100)
                    Toggle(tr("Notify when a limit resets"), isOn: $notifyReset)
                }
                .disabled(!notificationsEnabled)
            } header: {
                Text(tr("Limits"))
            }
            Section {
                Toggle(isOn: $notifyOutage) {
                    Text(tr("Notify when usage stops updating"))
                    Text(tr("Right away when the login needs attention; after 30 minutes for other problems, such as being offline."))
                }
                Toggle(isOn: $notifyUpdates) {
                    Text(tr("Notify when an update is available"))
                    Text(tr("Once per new version."))
                }
            } header: {
                Text(tr("App"))
            } footer: {
                // Only in development builds run without the app bundle.
                if !NotificationManager.isAvailable {
                    FormNote(tr("Available when running the bundled Claudometer.app."))
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // Older builds allowed a first alert up to 99%; pull it back into the slider's range.
        .onAppear { notifyLow = min(notifyLow, 95) }
        .onChange(of: notifyLow) { if notifyHigh < notifyLow { notifyHigh = notifyLow } }
        .onChange(of: notifyHigh) { if notifyLow > notifyHigh { notifyLow = notifyHigh } }
        .onChange(of: notificationsEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                if !(await NotificationManager.requestAuthorization()) { notificationsEnabled = false }
            }
        }
        .onChange(of: notifyOutage) { _, enabled in
            guard enabled else { return }
            Task {
                if !(await NotificationManager.requestAuthorization()) { notifyOutage = false }
            }
        }
        .onChange(of: notifyUpdates) { _, enabled in
            guard enabled else { return }
            Task {
                if !(await NotificationManager.requestAuthorization()) { notifyUpdates = false }
            }
        }
    }

    /// Alert levels are stored as whole percents; the slider works in `Double`.
    private func percent(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }
}

/// Data source and the claude.ai session key backup (TZ §2.3).
struct LoginSettings: View {
    @Environment(UsageStore.self) private var store
    @StateObject private var model = SessionKeyModel()

    var body: some View {
        Form {
            Section(tr("Data Source")) {
                LabeledContent(tr("Using")) {
                    Text(sourceText).foregroundStyle(Ink.secondary)
                }
            }

            Section {
                if model.hasKey {
                    LabeledContent(tr("Session key")) {
                        HStack(spacing: 8) {
                            Text(tr("Saved in Keychain")).foregroundStyle(Ink.secondary)
                            Button(tr("Remove")) { model.remove(store: store) }
                        }
                    }
                    if model.isPaused {
                        HStack(spacing: 8) {
                            Label {
                                Text(tr("Keychain access was denied, so the backup is paused.")).foregroundStyle(Ink.secondary)
                            } icon: {
                                Image(systemName: "key.fill").foregroundStyle(Palette.warningGlyph)
                            }
                            Spacer(minLength: 8)
                            Button(tr("Try Again")) { model.resume(store: store) }
                                .help(tr("Asks for Keychain access once more."))
                        }
                        .font(.callout)
                    }
                }
                SecureField(model.hasKey ? tr("Replace key") : tr("Session key"), text: $model.draft, prompt: Text(verbatim: "sk-ant-sid…"))
                HStack(spacing: 8) {
                    if model.isTesting {
                        ProgressView().controlSize(.small)
                        Text(tr("Checking with claude.ai…")).foregroundStyle(Ink.secondary)
                    } else if let result = model.result {
                        Label {
                            Text(md(result.text)).foregroundStyle(Ink.secondary)
                        } icon: {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                                .foregroundStyle(result.ok ? Palette.teal : Palette.criticalGlyph)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(tr("Save & Test")) { model.save(store: store) }
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTesting)
                        .keyboardShortcut(.defaultAction)
                }
                .font(.callout)
            } header: {
                Text(tr("claude.ai Backup"))
            } footer: {
                // Steps rather than a paragraph: for someone without Claude Code this is the way in.
                VStack(alignment: .leading, spacing: 6) {
                    FormNote(tr("Used only when the Claude Code login has expired, so usage stays live while Claude Code is closed."))
                    VStack(alignment: .leading, spacing: 3) {
                        FormNote(tr("1. Open claude.ai in your browser and sign in."))
                        FormNote(tr("2. Open Developer Tools (⌥⌘I), then Storage (Safari) or Application (Chrome) → Cookies."))
                        FormNote(tr("3. Copy the value of `sessionKey` and paste it above."))
                    }
                    Link(tr("Open claude.ai"), destination: URL(string: "https://claude.ai")!)
                    FormNote(tr("Stored in your Keychain and sent only to claude.ai."))
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // A fetch in the background may have just paused the backup.
        .onChange(of: store.state) { model.reload() }
    }

    private var sourceText: String {
        guard let snapshot = store.state.snapshot else { return tr("Not connected") }
        let title = snapshot.source?.title ?? UsageSource.claudeCode.title
        return store.state.error == nil ? title : tr("%@ (last known)", title)
    }
}

@MainActor
final class SessionKeyModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var hasKey = SessionKeyStore().hasKey
    @Published private(set) var isPaused = SessionKeyStore().isPaused
    @Published private(set) var isTesting = false
    @Published private(set) var result: (ok: Bool, text: String)?

    func save(store: UsageStore) {
        let key = SessionKeyStore.normalize(draft)
        guard !key.isEmpty else { return }
        isTesting = true
        result = nil
        Task {
            defer { isTesting = false }
            do {
                let snapshot = try await store.saveSessionKey(key)
                draft = ""
                hasKey = true
                isPaused = false
                let session = snapshot.session.map { tr(" · Session %@", Formatters.percent($0.utilization)) } ?? ""
                let plan = Formatters.planName(snapshot.plan).map { " · " + tr("%@ plan", $0) } ?? ""
                result = (true, tr("Works") + plan + session)
            } catch {
                result = (false, Self.message(for: error))
            }
        }
    }

    /// Wording for a key that was just pasted, rather than the background-poll messages.
    static func message(for error: Error) -> String {
        switch error as? AppError {
        case .sessionKeyInvalid?: return tr("claude.ai didn’t accept this key. Copy it again from a signed-in browser.")
        case .webBlocked?: return tr("claude.ai’s bot check blocked the request, so this backup can’t work right now.")
        case let appError?: return appError.message
        case nil: return error.localizedDescription
        }
    }

    func remove(store: UsageStore) {
        store.removeSessionKey()
        hasKey = false
        isPaused = false
        result = nil
    }

    func resume(store: UsageStore) {
        store.resumeSessionKey()
        isPaused = false
    }

    func reload() {
        let keys = SessionKeyStore()
        hasKey = keys.hasKey
        isPaused = keys.isPaused
    }
}

struct AboutSettings: View {
    @Environment(UpdateStore.self) private var updates

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: "Claudometer").font(.title2.weight(.semibold))
            Text(tr("Version %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                .foregroundStyle(.secondary)
            Text(tr("Unofficial. Not affiliated with Anthropic."))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(tr("Your Claude plan limits in the menu bar.\nReads your Claude Code login, or your claude.ai session key if you add one; nothing leaves your Mac except the usage requests to Anthropic."))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let release = updates.available {
                    if updates.canInstall {
                        Button(tr("Install %@", release.version)) { updates.installUpdate() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(updates.isInstalling)
                        Button(tr("Release Notes…")) { updates.openDownload() }
                    } else {
                        Button(tr("Download %@…", release.version)) { updates.openDownload() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button(tr("Check for Updates")) { Task { await updates.check(manual: true) } }
                        .disabled(updates.isChecking)
                }
                if updates.isChecking { ProgressView().controlSize(.small) }
            }
            .padding(.top, 6)
            switch updates.installState {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 220)
                Text(tr("Downloading the update…")).font(.callout).foregroundStyle(.secondary)
            case .installing:
                ProgressView().controlSize(.small)
                Text(tr("Installing. Claudometer will restart.")).font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .idle:
                if let result = updates.lastResult {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

struct ThresholdSlider: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: $value, in: range, step: 5)
                Text(verbatim: "\(Int(value))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        } label: {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
        }
    }
}

/// Launch at login through `SMAppService` (TZ FR-22).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// On by default: registers once on the first launch of the bundled `.app`, so the widget
    /// keeps getting data after a restart. Later launches leave the user's choice alone.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleURL.pathExtension == "app",
              !defaults.bool(forKey: SettingsKey.loginItemOffered) else { return }
        defaults.set(true, forKey: SettingsKey.loginItemOffered)
        try? SMAppService.mainApp.register()
    }
}

/// Secondary note under a settings group, aligned with the group's leading edge.
/// Inline Markdown (`code`) is rendered.
struct FormNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(md(text))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
