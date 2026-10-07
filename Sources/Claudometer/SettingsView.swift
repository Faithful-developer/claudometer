import AppKit
import ClaudometerCore
import ServiceManagement
import SwiftUI

/// Settings window (TZ FR-22), laid out like system apps: toolbar tabs with grouped forms.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            LoginSettings()
                .tabItem { Label("Login", systemImage: "person.badge.key") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
        .onAppear { NSApp.activate() }
    }
}

private struct GeneralSettings: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(SettingsKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingsKey.refreshMinutes) private var refreshMinutes = 5
    @AppStorage(SettingsKey.menuBarMetric) private var metric = MenuBarMetric.session.rawValue
    @AppStorage(SettingsKey.compactMenuBar) private var compact = false
    @AppStorage(SettingsKey.warningThreshold) private var warning = 60.0
    @AppStorage(SettingsKey.criticalThreshold) private var critical = 85.0
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if let error = loginItem.error {
                    Label {
                        Text(error).foregroundStyle(Ink.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.criticalGlyph)
                    }
                    .font(.caption)
                }
            }

            Section("Menu Bar") {
                Picker("Show", selection: $metric) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show percentage", isOn: Binding(get: { !compact }, set: { compact = !$0 }))
            }

            Section {
                ThresholdSlider(title: "Warning", symbol: "exclamationmark.triangle.fill", tint: Palette.warningGlyph, value: $warning, range: 10...95)
                ThresholdSlider(title: "Critical", symbol: "exclamationmark.octagon.fill", tint: Palette.criticalGlyph, value: $critical, range: 15...100)
            } header: {
                Text("Highlight Levels")
            } footer: {
                Text("Meters and the menu bar icon change colour above these levels.")
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Picker("Check usage", selection: $refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                        Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(minutes)
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

private struct NotificationSettings: View {
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = false
    @AppStorage(SettingsKey.notifyLow) private var notifyLow = 80
    @AppStorage(SettingsKey.notifyHigh) private var notifyHigh = 95
    @AppStorage(SettingsKey.notifyReset) private var notifyReset = true

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a limit gets close", isOn: $notificationsEnabled)
            } footer: {
                if !NotificationManager.isAvailable {
                    Text("Available when running the bundled Claudometer.app.").foregroundStyle(.secondary)
                }
            }
            Section {
                ThresholdSlider(title: "First alert", symbol: "bell.fill", tint: Palette.warningGlyph, value: percent($notifyLow), range: 50...95)
                ThresholdSlider(title: "Second alert", symbol: "bell.badge.fill", tint: Palette.criticalGlyph, value: percent($notifyHigh), range: 50...100)
                Toggle("Notify when a limit resets", isOn: $notifyReset)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Each alert fires at most once per limit until that limit resets.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!notificationsEnabled)
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
    }

    /// Alert levels are stored as whole percents; the slider works in `Double`.
    private func percent(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }
}

/// Data source and the claude.ai session key backup (TZ §2.3).
private struct LoginSettings: View {
    @Environment(UsageStore.self) private var store
    @StateObject private var model = SessionKeyModel()

    var body: some View {
        Form {
            Section("Data Source") {
                LabeledContent("Using") {
                    Text(sourceText).foregroundStyle(Ink.secondary)
                }
            }

            Section {
                if model.hasKey {
                    LabeledContent("Session key") {
                        HStack(spacing: 8) {
                            Text("Saved in Keychain").foregroundStyle(Ink.secondary)
                            Button("Remove") { model.remove(store: store) }
                        }
                    }
                }
                SecureField(model.hasKey ? "Replace key" : "Session key", text: $model.draft, prompt: Text("sk-ant-sid…"))
                HStack(spacing: 8) {
                    if model.isTesting {
                        ProgressView().controlSize(.small)
                        Text("Checking with claude.ai…").foregroundStyle(Ink.secondary)
                    } else if let result = model.result {
                        Label {
                            Text(LocalizedStringKey(result.text)).foregroundStyle(Ink.secondary)
                        } icon: {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                                .foregroundStyle(result.ok ? Palette.teal : Palette.criticalGlyph)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Save & Test") { model.save(store: store) }
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTesting)
                        .keyboardShortcut(.defaultAction)
                }
                .font(.callout)
            } header: {
                Text("claude.ai Backup")
            } footer: {
                Text("Used only when the Claude Code login has expired, so usage stays live while Claude Code is closed. In your browser, open claude.ai, then Developer Tools → Storage (Safari) or Application (Chrome) → Cookies, and copy the value of `sessionKey`. It's stored in your Keychain and sent only to claude.ai.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceText: String {
        guard let snapshot = store.state.snapshot else { return "Not connected" }
        let title = snapshot.source?.title ?? UsageSource.claudeCode.title
        return store.state.error == nil ? title : "\(title) (last known)"
    }
}

@MainActor
final class SessionKeyModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var hasKey = SessionKeyStore().hasKey
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
                let session = snapshot.session.map { " · Session \(Formatters.percent($0.utilization))" } ?? ""
                let plan = Formatters.planName(snapshot.plan).map { " · \($0) plan" } ?? ""
                result = (true, "Works\(plan)\(session)")
            } catch {
                result = (false, Self.message(for: error))
            }
        }
    }

    /// Wording for a key that was just pasted, rather than the background-poll messages.
    static func message(for error: Error) -> String {
        switch error as? AppError {
        case .sessionKeyInvalid?: return "claude.ai didn't accept this key. Copy it again from a signed-in browser."
        case .webBlocked?: return "claude.ai's bot check blocked the request, so this backup can't work right now."
        case let appError?: return appError.message
        case nil: return error.localizedDescription
        }
    }

    func remove(store: UsageStore) {
        store.removeSessionKey()
        hasKey = false
        result = nil
    }
}

private struct AboutSettings: View {
    @Environment(UpdateStore.self) private var updates

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Claudometer").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Unofficial. Not affiliated with Anthropic.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Your Claude plan limits in the menu bar.\nReads your Claude Code login, or your claude.ai session key if you add one; nothing leaves your Mac except the usage requests to Anthropic.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let release = updates.available {
                    Button("Download \(release.version)…") { updates.openDownload() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Check for Updates") { Task { await updates.check(manual: true) } }
                        .disabled(updates.isChecking)
                }
                if updates.isChecking { ProgressView().controlSize(.small) }
            }
            .padding(.top, 6)
            if let result = updates.lastResult {
                Text(result).font(.callout).foregroundStyle(.secondary)
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
                Text("\(Int(value))%").monospacedDigit().frame(width: 40, alignment: .trailing)
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
}
