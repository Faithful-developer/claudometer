import AppKit
import ClaudometerCore
import Foundation
import Network
import Observation
#if WIDGET_SUPPORT
import WidgetKit
#endif

/// Main app state: polling, backoff, sleep/wake and network handling (TZ FR-15…FR-18).
@MainActor
@Observable
final class UsageStore {
    private(set) var state: UsageState
    private(set) var isLoading = false
    private(set) var lastAttempt: Date?

    @ObservationIgnored private let service: UsageService
    @ObservationIgnored private let snapshotStore: SnapshotStore
    @ObservationIgnored private let notifications: NotificationManager
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastManualRefresh: Date = .distantPast
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasDown = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var widgetRefresh: RefreshSignal.Observation?

    init(
        service: UsageService = UsageService(),
        snapshotStore: SnapshotStore = .default(),
        notifications: NotificationManager? = nil,
        markCachedStale: Bool = true,
        initialState: UsageState? = nil
    ) {
        self.service = service
        self.snapshotStore = snapshotStore
        self.notifications = notifications ?? NotificationManager()
        // Show the last known data immediately, greyed out until the first fetch finishes.
        if let initialState {
            self.state = initialState
        } else if var cached = snapshotStore.load() {
            if markCachedStale, cached.error == nil, cached.snapshot != nil { cached.error = .offline }
            self.state = cached.projected(at: Date())
        } else {
            self.state = UsageState()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        observeSystemEvents()
        restartPolling()
    }

    /// Cancels the current wait and fetches immediately, then continues polling.
    func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetch()
                var delay = Backoff.nextDelay(
                    interval: TimeInterval(AppSettings.current.refreshMinutes * 60),
                    failures: self.failures,
                    error: self.state.error
                )
                // Also while failing: the attempt right after a reset updates the last known
                // data to 0% even if the fetch itself fails.
                // Never sooner than a server's Retry-After, though.
                if case .rateLimited = self.state.error {} else {
                    delay = Backoff.untilNextReset(delay, resets: self.state.snapshot?.windows.compactMap(\.resetsAt) ?? [])
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Refresh button. Debounced to one fetch every 10 s (FR-18).
    func refresh() {
        guard Date().timeIntervalSince(lastManualRefresh) >= 10 else { return }
        lastManualRefresh = Date()
        restartPolling()
    }

    /// Settings → Save & Test. Checks the key against claude.ai, stores it only if it works,
    /// then fetches right away so the new source shows up.
    func saveSessionKey(_ key: String) async throws -> UsageSnapshot {
        let snapshot = try await service.test(sessionKey: key)
        try SessionKeyStore().save(key)
        restartPolling()
        return snapshot
    }

    func removeSessionKey() {
        SessionKeyStore().delete()
        restartPolling()
    }

    // MARK: - Fetch

    private func fetch() async {
        isLoading = true
        lastAttempt = Date()
        defer { isLoading = false }

        do {
            let snapshot = try await service.fetch()
            failures = 0
            apply(UsageState(snapshot: snapshot, error: nil))
            notifications.process(snapshot, settings: AppSettings.current)
        } catch {
            failures += 1
            let appError = (error as? AppError) ?? .unknown(error.localizedDescription)
            let keep = appError.keepsStaleData ? state.snapshot?.projected(at: Date()) : nil
            apply(UsageState(snapshot: keep, error: appError))
        }
    }

    private func apply(_ newState: UsageState) {
        state = newState
        try? snapshotStore.save(newState)
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
            Task { @MainActor in
                self?.pollTask?.cancel()
                self?.pollTask = nil
            }
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

    // MARK: - Derived values for views

    var primaryWindow: LimitWindow? {
        state.snapshot?.window(for: AppSettings.current.menuBarMetric)
    }
}
