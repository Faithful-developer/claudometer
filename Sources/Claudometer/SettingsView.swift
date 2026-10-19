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
                .tabItem { Label(tr("Accounts"), systemImage: "person.2") }
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
                        Text(store.state.error == .notSignedIn ? tr("Sign in on the Accounts tab first.") : tr("Available after the first update."))
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

/// Accounts (TZ F-2): the Claude Code account with its claude.ai backup key (TZ §2.3), then
/// the accounts added with a session key, then a form to add one.
struct LoginSettings: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        Form {
            ClaudeCodeAccountSections(keySaved: store.isPreview ? false : nil)
            ForEach(store.accounts.filter { !$0.isPrimary }) { account in
                AddedAccountSection(account: account, keySaved: store.isPreview ? true : nil)
            }
            AddAccountSection()
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Data source, name and the claude.ai backup of the Claude Code account.
private struct ClaudeCodeAccountSections: View {
    @Environment(UsageStore.self) private var store
    @StateObject private var model: SessionKeyModel

    /// Previews pass what to show instead of reading the Keychain.
    init(keySaved: Bool?) {
        _model = StateObject(wrappedValue: SessionKeyModel(accountID: Account.primaryID, keySaved: keySaved))
    }

    var body: some View {
        let account = store.accounts.first(where: \.isPrimary) ?? .primary
        Section(store.hasManyAccounts ? account.title : tr("Data Source")) {
            if store.hasManyAccounts {
                AccountNameField(account: account)
            }
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
                    PausedKeyRow(text: tr("Keychain access was denied, so the backup is paused.")) { model.resume(store: store) }
                }
            }
            SecureField(model.hasKey ? tr("Replace key") : tr("Session key"), text: $model.draft, prompt: Text(verbatim: "sk-ant-sid…"))
                .onSubmit { model.save(store: store) }
            KeyTestRow(isTesting: model.isTesting, result: model.result, action: tr("Save & Test"), disabled: model.draft.isBlank) {
                model.save(store: store)
            }
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
        // A fetch in the background may have just paused the backup.
        .onChange(of: store.state(of: Account.primaryID)) { model.reload() }
    }

    private var sourceText: String {
        let state = store.state(of: Account.primaryID)
        guard let snapshot = state.snapshot else { return tr("Not connected") }
        let title = snapshot.source?.title ?? UsageSource.claudeCode.title
        return state.error == nil ? title : tr("%@ (last known)", title)
    }
}

/// An account added with a session key: its name, how it's doing, a new key and removal.
private struct AddedAccountSection: View {
    let account: Account
    @Environment(UsageStore.self) private var store
    @StateObject private var model: SessionKeyModel

    init(account: Account, keySaved: Bool?) {
        self.account = account
        _model = StateObject(wrappedValue: SessionKeyModel(accountID: account.id, keySaved: keySaved))
    }

    var body: some View {
        let state = store.state(of: account.id)
        Section(account.title) {
            AccountNameField(account: account)
            LabeledContent(tr("Status")) {
                if state.error?.needsUserAction == true {
                    Label {
                        Text(Self.status(state)).foregroundStyle(Ink.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warningGlyph)
                    }
                } else {
                    Text(Self.status(state)).foregroundStyle(Ink.secondary)
                }
            }
            if model.isPaused {
                PausedKeyRow(text: tr("Keychain access was denied, so this account is paused.")) { model.resume(store: store) }
            }
            if model.isReplacing || !model.hasKey || state.error == .sessionKeyInvalid {
                SecureField(tr("New key"), text: $model.draft, prompt: Text(verbatim: "sk-ant-sid…"))
                    .onSubmit { model.save(store: store) }
                KeyTestRow(isTesting: model.isTesting, result: model.result, action: tr("Save & Test"), disabled: model.draft.isBlank) {
                    model.save(store: store)
                }
            } else if let result = model.result {
                KeyTestRow(isTesting: false, result: result, action: nil, disabled: true) {}
            }
            HStack(spacing: 8) {
                Spacer()
                if model.hasKey, !model.isReplacing, state.error != .sessionKeyInvalid {
                    Button(tr("Replace Key…")) { model.isReplacing = true }
                }
                Button(tr("Remove Account…"), role: .destructive) { model.confirmRemove = true }
                    .disabled(model.isTesting)
            }
            .confirmationDialog(tr("Remove “%@”?", account.title), isPresented: $model.confirmRemove) {
                Button(tr("Remove Account"), role: .destructive) { store.removeAccount(account.id) }
            } message: {
                Text(tr("Its session key is deleted from your Keychain, and its usage history from this Mac."))
            }
        }
        .onChange(of: state) { model.reload() }
    }

    /// "Max plan · Session 42%", or what's wrong.
    static func status(_ state: UsageState) -> String {
        if let error = state.error {
            return state.snapshot == nil ? error.shortReason : tr("%@ (last known)", error.shortReason)
        }
        guard let snapshot = state.snapshot else { return tr("Connecting…") }
        return [Formatters.planName(snapshot.plan).map { tr("%@ plan", $0) },
                snapshot.session.map { tr("Session %@", Formatters.percent($0.utilization)) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Paste a key for another account; picks the organization when the login has several.
private struct AddAccountSection: View {
    @Environment(UsageStore.self) private var store
    @StateObject private var model = AddAccountModel()

    var body: some View {
        Section {
            if store.accountsLocked {
                Text(UsageStore.lockedMessage).foregroundStyle(Ink.secondary)
            } else if store.canAddAccount {
                TextField(tr("Name"), text: $model.name, prompt: Text(tr("Work")))
                SecureField(tr("Session key"), text: $model.draft, prompt: Text(verbatim: "sk-ant-sid…"))
                    .onSubmit { model.add(store: store) }
                if model.organizations.count > 1 {
                    Picker(tr("Organization"), selection: $model.orgUUID) {
                        ForEach(model.organizations) { org in
                            Text(org.name.isEmpty ? org.uuid : org.name).tag(Optional(org.uuid))
                        }
                    }
                }
                KeyTestRow(isTesting: model.isTesting, result: model.result, action: tr("Add Account"), disabled: model.draft.isBlank) {
                    model.add(store: store)
                }
            } else {
                // The account that just reached the limit keeps its "Works" line.
                if model.isTesting || model.result != nil {
                    KeyTestRow(isTesting: model.isTesting, result: model.result, action: nil, disabled: true) {}
                }
                Text(tr("You can add up to %lld accounts.", AccountStore.maxExtra)).foregroundStyle(Ink.secondary)
            }
        } header: {
            Text(tr("Add Account"))
        } footer: {
            FormNote(tr("Track another Claude account, such as a work Team plan, with the session key of a browser signed in to it. The steps are the same as above."))
        }
    }
}

/// Edits an account's name; saved on Return or when the field loses focus.
private struct AccountNameField: View {
    let account: Account
    @Environment(UsageStore.self) private var store
    @StateObject private var draft: TextDraft
    @FocusState private var focused: Bool

    init(account: Account) {
        self.account = account
        _draft = StateObject(wrappedValue: TextDraft(account.name))
    }

    var body: some View {
        TextField(tr("Name"), text: $draft.text, prompt: Text(Account(id: account.id).title))
            .focused($focused)
            .disabled(store.accountsLocked)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        if draft.text != account.name { store.rename(account.id, to: draft.text) }
    }
}

/// `@State` needs the SwiftUI macro plugin, which the Command Line Tools lack.
final class TextDraft: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

/// A paused key (denied Keychain prompt) with Try Again.
private struct PausedKeyRow: View {
    let text: String
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(text).foregroundStyle(Ink.secondary)
            } icon: {
                Image(systemName: "key.fill").foregroundStyle(Palette.warningGlyph)
            }
            Spacer(minLength: 8)
            Button(tr("Try Again"), action: resume)
                .help(tr("Asks for Keychain access once more."))
        }
        .font(.callout)
    }
}

/// The outcome of checking a key with claude.ai, and the button that does it.
struct KeyResult: Equatable {
    enum Tone { case ok, failed, info }
    var tone: Tone
    var text: String
}

private struct KeyTestRow: View {
    let isTesting: Bool
    let result: KeyResult?
    /// Button title; nil shows only the result.
    let action: String?
    let disabled: Bool
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isTesting {
                ProgressView().controlSize(.small)
                Text(tr("Checking with claude.ai…")).foregroundStyle(Ink.secondary)
            } else if let result {
                Label {
                    Text(md(result.text)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    switch result.tone {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.teal)
                    case .failed: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.criticalGlyph)
                    case .info: Image(systemName: "info.circle.fill").foregroundStyle(Ink.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform).disabled(disabled || isTesting)
            }
        }
        .font(.callout)
    }
}

@MainActor
final class SessionKeyModel: ObservableObject {
    let accountID: String
    @Published var draft = ""
    @Published private(set) var hasKey: Bool
    @Published private(set) var isPaused: Bool
    @Published private(set) var isTesting = false
    @Published private(set) var result: KeyResult?
    /// Added accounts show the key field only on request.
    @Published var isReplacing = false
    @Published var confirmRemove = false
    /// Set for previews, which don't read the Keychain.
    private let keySaved: Bool?

    init(accountID: String, keySaved: Bool? = nil) {
        self.accountID = accountID
        self.keySaved = keySaved
        let keys = SessionKeyStore(accountID: accountID)
        hasKey = keySaved ?? keys.hasKey
        isPaused = keySaved == nil ? keys.isPaused : false
    }

    func save(store: UsageStore) {
        let key = SessionKeyStore.normalize(draft)
        guard !key.isEmpty, !isTesting else { return }
        isTesting = true
        result = nil
        Task {
            defer { isTesting = false }
            do {
                let snapshot = try await store.replaceKey(key, for: accountID)
                draft = ""
                hasKey = true
                isPaused = false
                isReplacing = false
                result = KeyResult(tone: .ok, text: Self.works(snapshot))
            } catch {
                result = KeyResult(tone: .failed, text: Self.message(for: error))
            }
        }
    }

    /// "Works · Max plan · Session 42%".
    static func works(_ snapshot: UsageSnapshot) -> String {
        let session = snapshot.session.map { tr(" · Session %@", Formatters.percent($0.utilization)) } ?? ""
        let plan = Formatters.planName(snapshot.plan).map { " · " + tr("%@ plan", $0) } ?? ""
        return tr("Works") + plan + session
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
        store.resumeSessionKey(for: accountID)
        isPaused = false
    }

    func reload() {
        guard keySaved == nil else { return }
        let keys = SessionKeyStore(accountID: accountID)
        hasKey = keys.hasKey
        isPaused = keys.isPaused
    }
}

@MainActor
final class AddAccountModel: ObservableObject {
    @Published var name = ""
    /// A different key drops the previous key's organizations.
    @Published var draft = "" {
        didSet { if draft != oldValue, !organizations.isEmpty { organizations = []; orgUUID = nil } }
    }
    /// Shown as a picker when the key's login has several organizations not added yet.
    @Published private(set) var organizations: [WebOrganization] = []
    @Published var orgUUID: String?
    @Published private(set) var isTesting = false
    @Published private(set) var result: KeyResult?

    func add(store: UsageStore) {
        let key = SessionKeyStore.normalize(draft)
        guard !key.isEmpty, !isTesting else { return }
        isTesting = true
        result = nil
        Task {
            defer { isTesting = false }
            do {
                let check = try await store.check(sessionKey: key)
                let available = check.available
                guard let org = pick(from: available) else {
                    if available.count > 1 {
                        organizations = available
                        orgUUID = available[0].uuid
                        result = KeyResult(tone: .info, text: tr("This login has several organizations. Pick one, then click Add Account."))
                    } else if check.isClaudeCode {
                        // The same account as Claude Code's: it backs that one up instead (TZ §2.3).
                        _ = try await store.saveSessionKey(key)
                        reset()
                        result = KeyResult(tone: .ok, text: tr("This is your Claude Code account, so the key was saved as its backup."))
                    } else if let existing = check.added.first {
                        result = KeyResult(tone: .failed, text: tr("Already added as “%@”.", existing.title))
                    } else {
                        result = KeyResult(tone: .failed, text: AppError.apiChanged.message)
                    }
                    return
                }
                let snapshot = try await store.addAccount(key: key, org: org, name: name)
                reset()
                result = KeyResult(tone: .ok, text: SessionKeyModel.works(snapshot))
            } catch {
                result = KeyResult(tone: .failed, text: SessionKeyModel.message(for: error))
            }
        }
    }

    /// The only organization left, or the one picked once the picker is showing.
    private func pick(from available: [WebOrganization]) -> WebOrganization? {
        if available.count == 1 { return available[0] }
        guard organizations == available else { return nil }
        return available.first { $0.uuid == orgUUID }
    }

    private func reset() {
        name = ""
        draft = ""
        organizations = []
        orgUUID = nil
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
            Text(tr("Your Claude plan limits in the menu bar.\nReads your Claude Code login, or your claude.ai session key if you add one."))
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
