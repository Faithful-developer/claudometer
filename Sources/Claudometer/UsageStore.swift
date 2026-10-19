import AppKit
import ClaudometerCore
import Foundation
import Network
import Observation
#if WIDGET_SUPPORT
import WidgetKit
#endif

/// Main app state: polling, backoff, sleep/wake and network handling (TZ FR-15…FR-18), for
/// each account (TZ F-2). Views read `state` and `history`, which follow the account selected
/// in the popover.
@MainActor
@Observable
final class UsageStore {
    /// The Claude Code account first, then the ones added with a session key.
    private(set) var accounts: [Account]
    private(set) var selectedID: String
    private(set) var states: [String: UsageState] = [:]
    /// A week of successful readings per account, for usage per day and the pace forecast.
    private(set) var histories: [String: UsageHistory] = [:]
    /// Fetches running, per account; a token so a cancelled fetch doesn't end a newer one's.
    private var loading: [String: UUID] = [:]

    /// A preview's made-up account: nothing is read from or written to disk.
    struct Seed {
        var account: Account
        var state: UsageState
        var history: UsageHistory
    }

    @ObservationIgnored private let service: UsageService
    @ObservationIgnored private let accountStore: AccountStore
    /// False for previews, which never write files.
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let notifications: NotificationManager
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    /// `accounts.json` exists but couldn't be read (damaged, or from a newer version): it's
    /// left alone rather than overwritten, so the accounts in it and their keys aren't lost.
    /// Settings then offers no Add Account or renaming, since neither could be saved.
    @ObservationIgnored private(set) var accountsLocked = false
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var lastManualRefresh: Date = .distantPast
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasDown = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var widgetRefresh: RefreshSignal.Observation?

    init(
        service: UsageService = UsageService(),
        accountStore: AccountStore = .default(),
        notifications: NotificationManager? = nil,
        seeds: [Seed]? = nil,
        selectedID: String? = nil
    ) {
        self.service = service
        self.accountStore = accountStore
        self.persists = seeds == nil
        self.notifications = notifications ?? NotificationManager()
        var accounts: [Account] = [.primary]
        var states: [String: UsageState] = [:]
        var histories: [String: UsageHistory] = [:]
        if let seeds {
            if !seeds.isEmpty { accounts = seeds.map(\.account) }
            for seed in seeds {
                states[seed.account.id] = seed.state
                histories[seed.account.id] = seed.history
            }
        } else {
            accounts = accountStore.load()
            accountsLocked = accountStore.isUnreadable
            for account in accounts {
                // Show the last known data immediately, greyed out until the first fetch finishes.
                if var cached = SnapshotStore.default(account: account).load() {
                    if cached.error == nil, cached.snapshot != nil { cached.error = .offline }
                    states[account.id] = cached.projected(at: Date())
                }
                histories[account.id] = HistoryStore.default(account: account).load()
            }
        }
        let wanted = selectedID ?? UserDefaults.standard.string(forKey: SettingsKey.selectedAccount)
        self.accounts = accounts
        self.states = states
        self.histories = histories
        self.selectedID = accounts.first { $0.id == wanted }?.id ?? Account.primaryID
    }

    // MARK: - Selected account

    var selected: Account { accounts.first { $0.id == selectedID } ?? accounts[0] }
    var state: UsageState { states[selectedID] ?? UsageState() }
    var history: UsageHistory { histories[selectedID] ?? UsageHistory() }
    var isLoading: Bool { loading[selectedID] != nil }
    var hasManyAccounts: Bool { accounts.count > 1 }
    var canAddAccount: Bool { !accountsLocked && accounts.count - 1 < AccountStore.maxExtra }
    var isAtAccountLimit: Bool { accounts.count - 1 >= AccountStore.maxExtra }
    /// Drawn by `PreviewRenderer`: Settings shows saved keys without reading the Keychain.
    var isPreview: Bool { !persists }

    func state(of id: String) -> UsageState { states[id] ?? UsageState() }

    /// Popover switcher and `claudometer://open?account=`. The menu bar follows.
    func select(_ id: String) {
        guard id != selectedID, accounts.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if persists { UserDefaults.standard.set(id, forKey: SettingsKey.selectedAccount) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        observeSystemEvents()
        for account in accounts where !account.isPrimary { restartPolling(account.id) }
        // The Claude Code account starts once its backup's organization is settled, so a
        // first reading through the backup comes from the right one.
        Task {
            await followClaudeCodeOrganization()
            restartPolling(Account.primaryID)
        }
    }

    /// The Claude Code account's backup key reads the organization Claude Code is signed in
    /// to, also when that changed or the key was saved before 0.3.0 (TZ §2.4). Only if the key
    /// can read it: a key from another login keeps the one Save & Test picked. The file can be
    /// large, so it's read off the main actor.
    private func followClaudeCodeOrganization() async {
        guard let org = await Self.claudeCodeOrganization(),
              accounts.first(where: \.isPrimary)?.orgUUID != org,
              SessionKeyStore().hasKey,
              let key = await Self.backupKey(),
              let orgs = try? await service.organizations(sessionKey: key),
              orgs.contains(where: { $0.uuid == org }) else { return }
        update(Account.primaryID) { $0.orgUUID = org }
    }

    private nonisolated static func claudeCodeOrganization() async -> String? {
        await Task.detached { ClaudeCodeProfile.load()?.orgUUID }.value
    }

    private nonisolated static func backupKey() async -> String? {
        await Task.detached { SessionKeyStore().loadForPolling() }.value
    }

    /// Cancels the current waits and fetches every account immediately, then continues polling.
    func restartPolling() {
        for account in accounts { restartPolling(account.id) }
    }

    /// `fetchNow` false waits a full interval first, for an account whose data just came in.
    private func restartPolling(_ id: String, fetchNow: Bool = true) {
        pollTasks[id]?.cancel()
        pollTasks[id] = Task { [weak self] in
            var fetchNow = fetchNow
            while !Task.isCancelled {
                guard let self, let account = self.accounts.first(where: { $0.id == id }) else { return }
                if fetchNow { await self.fetch(account) }
                fetchNow = true
                let state = self.state(of: id)
                var delay = Backoff.nextDelay(
                    interval: TimeInterval(AppSettings.current.refreshMinutes * 60),
                    failures: self.failures[id] ?? 0,
                    error: state.error
                )
                // Also while failing: the attempt right after a reset updates the last known
                // data to 0% even if the fetch itself fails.
                // Never sooner than a server's Retry-After, though.
                if case .rateLimited = state.error {} else {
                    delay = Backoff.untilNextReset(delay, resets: state.snapshot?.windows.compactMap(\.resetsAt) ?? [])
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func stopPolling() {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks = [:]
    }

    /// Refresh button. Debounced to one fetch every 10 s (FR-18).
    func refresh() {
        guard Date().timeIntervalSince(lastManualRefresh) >= 10 else { return }
        lastManualRefresh = Date()
        restartPolling()
    }

    /// Try Again in the popover. Also lifts a paused session key: for the Claude Code account
    /// that pause hides behind the Claude Code error, so this may be the only Try Again the
    /// user sees.
    func retry() {
        let keys = SessionKeyStore(accountID: selectedID)
        if keys.isPaused { keys.isPaused = false }
        refresh()
    }

    // MARK: - Session keys and accounts (Settings › Accounts)

    /// What a pasted key can be used for: each organization it reads, and whether that is the
    /// Claude Code account or one already added.
    struct KeyCheck {
        enum Use { case claudeCode, added(Account), available }
        var organizations: [(org: WebOrganization, use: Use)]

        var available: [WebOrganization] {
            organizations.compactMap { if case .available = $0.use { return $0.org } else { return nil } }
        }
        var isClaudeCode: Bool {
            organizations.contains { if case .claudeCode = $0.use { return true } else { return false } }
        }
        var added: [Account] {
            organizations.compactMap { if case .added(let account) = $0.use { return account } else { return nil } }
        }
    }

    func check(sessionKey key: String) async throws -> KeyCheck {
        let orgs = try await service.organizations(sessionKey: key)
        // Claude Code's organization, and the one its backup key already reads (the only one
        // known when Claude Code isn't signed in on this Mac).
        let claudeCode = Set([await Self.claudeCodeOrganization(), accounts.first(where: \.isPrimary)?.orgUUID].compactMap { $0 })
        return KeyCheck(organizations: orgs.map { org in
            if claudeCode.contains(org.uuid) { return (org, .claudeCode) }
            if let account = accounts.first(where: { !$0.isPrimary && $0.orgUUID == org.uuid }) { return (org, .added(account)) }
            return (org, .available)
        })
    }

    /// Claude Code account's backup (Settings › Save & Test). Checks the key against claude.ai,
    /// stores it only if it works, then fetches right away so the new source shows up. Reads
    /// Claude Code's own organization when the key has several.
    func saveSessionKey(_ key: String) async throws -> UsageSnapshot {
        let orgs = try await service.organizations(sessionKey: key)
        let claudeCode = await Self.claudeCodeOrganization()
        let current = accounts.first(where: \.isPrimary)?.orgUUID
        // Recorded either way, so a later Add Account recognises this organization. Without
        // Claude Code's, the one the backup already reads, so it can't move onto an added one.
        let org = (orgs.first { $0.uuid == claudeCode } ?? orgs.first { $0.uuid == current } ?? orgs.first)?.uuid
        let snapshot = try await service.test(sessionKey: key, orgUUID: org)
        try SessionKeyStore().save(key)
        update(Account.primaryID) { $0.orgUUID = org }
        restartPolling(Account.primaryID)
        return snapshot
    }

    /// A new account reading `org` with `key`.
    func addAccount(key: String, org: WebOrganization, name: String) async throws -> UsageSnapshot {
        try checkCanAddAccount()
        let snapshot = try await service.test(sessionKey: key, orgUUID: org.uuid)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account.added(name: trimmed.isEmpty ? org.suggestedName : trimmed, orgUUID: org.uuid)
        try checkCanAddAccount()
        try SessionKeyStore(accountID: account.id).save(key)
        accounts.append(account)
        saveAccounts()
        // The test's reading is the first one; the next comes after a regular interval.
        record(snapshot, for: account)
        restartPolling(account.id, fetchNow: false)
        return snapshot
    }

    private func checkCanAddAccount() throws {
        if accountsLocked { throw AppError.unknown(Self.lockedMessage) }
        if isAtAccountLimit { throw AppError.unknown(tr("You can add up to %lld accounts.", AccountStore.maxExtra)) }
    }

    static var lockedMessage: String {
        tr("Claudometer can’t read its list of accounts, so accounts can’t be added or renamed.")
    }

    /// A fresh key for an added account, checked against the same organization.
    func replaceKey(_ key: String, for id: String) async throws -> UsageSnapshot {
        guard let account = accounts.first(where: { $0.id == id }), !account.isPrimary else { return try await saveSessionKey(key) }
        let snapshot = try await service.test(sessionKey: key, orgUUID: account.orgUUID)
        // Removed while the key was being checked: don't leave its key behind.
        guard accounts.contains(where: { $0.id == id }) else { throw CancellationError() }
        try SessionKeyStore(accountID: id).save(key)
        restartPolling(id)
        return snapshot
    }

    func rename(_ id: String, to name: String) {
        guard !accountsLocked else { return }
        update(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Forgets an added account: its key, its files and its notification state.
    func removeAccount(_ id: String) {
        guard id != Account.primaryID, accounts.contains(where: { $0.id == id }) else { return }
        let account = accounts.first { $0.id == id }!
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        accounts.removeAll { $0.id == id }
        states[id] = nil
        histories[id] = nil
        failures[id] = nil
        if selectedID == id { select(Account.primaryID) }
        guard persists else { return }
        SessionKeyStore(accountID: id).delete()
        SnapshotStore.default(account: account).delete()
        HistoryStore.default(account: account).delete()
        notifications.forget(account: id)
        saveAccounts()
    }

    /// Settings → Try Again after a denied Keychain prompt: asks once more on the next fetch.
    func resumeSessionKey(for id: String = Account.primaryID) {
        SessionKeyStore(accountID: id).isPaused = false
        restartPolling(id)
    }

    /// Removes the Claude Code account's backup key.
    func removeSessionKey() {
        SessionKeyStore().delete()
        update(Account.primaryID) { $0.orgUUID = nil }
        restartPolling(Account.primaryID)
    }

    private func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
        saveAccounts()
    }

    private func saveAccounts() {
        guard persists, !accountsLocked else { return }
        accountStore.save(accounts)
        reloadWidgets()
    }

    // MARK: - Fetch

    private func fetch(_ account: Account) async {
        let id = account.id
        let token = UUID()
        loading[id] = token
        defer { if loading[id] == token { loading[id] = nil } }

        do {
            let snapshot = try await service.fetch(account: account)
            // Removed while the request was running.
            guard let account = accounts.first(where: { $0.id == id }) else { return }
            record(snapshot, for: account)
        } catch {
            // Restarted (Refresh, wake, a new key): the next fetch reports instead.
            if Task.isCancelled { return }
            guard let account = accounts.first(where: { $0.id == id }) else { return }
            failures[id, default: 0] += 1
            let appError = (error as? AppError) ?? .unknown(error.localizedDescription)
            let keep = appError.keepsStaleData ? state(of: id).snapshot?.projected(at: Date()) : nil
            apply(UsageState(snapshot: keep, error: appError), to: account)
            notifications.processOutage(error: appError, fetchedAt: keep?.fetchedAt, account: id,
                                        label: notificationLabel(account), settings: AppSettings.current)
        }
    }

    /// A successful reading: state, history, widgets and alerts.
    private func record(_ snapshot: UsageSnapshot, for account: Account) {
        let id = account.id
        failures[id] = 0
        // Only fresh data goes into the history, never the projected last known state.
        histories[id, default: UsageHistory()].record(snapshot)
        if persists, let history = histories[id] { HistoryStore.default(account: account).save(history) }
        apply(UsageState(snapshot: snapshot, error: nil), to: account)
        let settings = AppSettings.current
        let label = notificationLabel(account)
        notifications.process(snapshot, account: id, label: label, settings: settings)
        notifications.processOutage(error: nil, fetchedAt: snapshot.fetchedAt, account: id, label: label, settings: settings)
    }

    /// Alerts name the account only when there's more than one.
    private func notificationLabel(_ account: Account) -> String? {
        hasManyAccounts ? account.title : nil
    }

    private func apply(_ newState: UsageState, to account: Account) {
        states[account.id] = newState
        guard persists else { return }
        try? SnapshotStore.default(account: account).save(newState)
        reloadWidgets()
    }

    private func reloadWidgets() {
        #if WIDGET_SUPPORT
        AppSettings.saveWidgetStyle()
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopPolling() }
        })

        // Refresh button on the desktop widget.
        widgetRefresh = RefreshSignal.observe { [weak self] in
            Task { @MainActor in self?.refresh() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied, self.networkWasDown {
                    self.networkWasDown = false
                    self.restartPolling()
                } else if !satisfied {
                    self.networkWasDown = true
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "claudometer.network"))
    }
}
