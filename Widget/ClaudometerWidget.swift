import AppIntents
import ClaudometerCore
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let state: UsageState
    let account: Account
    /// Shown on the widget only when there's more than one account.
    let accountName: String?
    /// The account chosen in Edit Widget was removed in the app.
    var accountRemoved = false
}

/// Reads the state the app writes to the shared folder, for the account picked in Edit Widget
/// (TZ F-2). Never touches the network (FR-11).
struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), state: UsageState(snapshot: .placeholder), account: .primary, accountName: nil)
    }

    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> UsageEntry {
        let (account, name, removed) = Self.resolve(configuration)
        let state = SnapshotStore.default(account: account).load()
            ?? UsageState(snapshot: context.isPreview ? .placeholder : nil, error: nil)
        return UsageEntry(date: Date(), state: state, account: account, accountName: name, accountRemoved: removed)
    }

    /// Entries every 15 min for 2 h so countdowns stay roughly right between app reloads (FR-13).
    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<UsageEntry> {
        let (account, name, removed) = Self.resolve(configuration)
        // No shared state yet (app never ran, or the folder is not readable): ask to open the app.
        let state = SnapshotStore.default(account: account).load() ?? UsageState()
        let now = Date()
        // Each entry projects its own time, so a limit that resets while the app can't fetch
        // drops to 0% on schedule instead of showing the old figure.
        let entries = (0..<8).map { step -> UsageEntry in
            let date = now.addingTimeInterval(Double(step) * 15 * 60)
            return UsageEntry(date: date, state: state.projected(at: date), account: account, accountName: name, accountRemoved: removed)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// The chosen account, or Claude Code's when none is chosen (widgets placed before
    /// accounts existed). A chosen account that was removed is reported rather than swapped
    /// for another account's numbers.
    static func resolve(_ configuration: SelectAccountIntent) -> (Account, String?, removed: Bool) {
        let accounts = AccountStore.default().load()
        L10n.resolve(WidgetView.style.language)
        guard let chosen = configuration.account?.id else {
            return (accounts[0], accounts.count > 1 ? accounts[0].title : nil, false)
        }
        guard let account = accounts.first(where: { $0.id == chosen }) else { return (.primary, nil, true) }
        return (account, accounts.count > 1 ? account.title : nil, false)
    }
}

// MARK: - Account choice (Edit Widget)

struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = AccountQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The accounts the app lists in `accounts.json`.
struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AccountEntity] { all() }

    func defaultResult() async -> AccountEntity? { all().first }

    private func all() -> [AccountEntity] {
        L10n.resolve(WidgetView.style.language)
        return AccountStore.default().load().map { AccountEntity(id: $0.id, name: $0.title) }
    }
}

struct SelectAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Account"
    static var description = IntentDescription("Choose the Claude account this widget shows.")

    @Parameter(title: "Account")
    var account: AccountEntity?
}

extension UsageSnapshot {
    static let placeholder = UsageSnapshot(
        windows: [
            LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 42, resetsAt: Date().addingTimeInterval(8040)),
            LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 17, resetsAt: Date().addingTimeInterval(3 * 86400)),
            LimitWindow(id: "weekly_scoped:Opus", group: .weekly, title: "Weekly · Opus", utilization: 5, resetsAt: Date().addingTimeInterval(3 * 86400)),
        ],
        plan: "max"
    )
}

// MARK: - Refresh button

/// Runs in the widget process, which can't fetch (FR-11): it asks the app to, and the app
/// reloads the timelines once the new data is saved.
struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Claude Usage"
    static var description = IntentDescription("Fetches your latest Claude plan usage.")
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        RefreshSignal.post()
        return .result()
    }
}

// MARK: - Widget

@main
struct ClaudometerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ClaudometerWidget", intent: SelectAccountIntent.self, provider: UsageProvider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(Palette.surface, for: .widget)
                .widgetURL(URL(string: "claudometer://open?account=\(entry.account.id)"))
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude plan limits and when they reset.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        let style = Self.style
        // Same language as the app, even when it differs from the macOS one.
        let _ = L10n.resolve(style.language)
        if entry.accountRemoved {
            VStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2).foregroundStyle(Ink.secondary)
                Text(tr("Account removed"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                Text(tr("Edit the widget to choose another."))
                    .font(.caption).foregroundStyle(Ink.secondary)
            }
            .multilineTextAlignment(.center)
        } else {
            content(style)
        }
    }

    private func content(_ style: WidgetStyle) -> some View {
        UsageWidgetContent(
            size: size, state: entry.state, now: entry.date, style: style, forecast: forecast(style),
            refreshControl: AnyView(
                Button(intent: RefreshUsageIntent()) { RefreshGlyph() }
                    .buttonStyle(.plain)
            ),
            account: entry.accountName
        )
    }

    /// Large widget only: when the main limit runs out at its recent pace, from the history the
    /// app writes next to the usage state.
    private func forecast(_ style: WidgetStyle) -> Date? {
        guard family == .systemLarge, let snapshot = entry.state.snapshot, entry.state.error == nil,
              let hero = snapshot.window(for: style.metric) else { return nil }
        return HistoryStore.default(account: entry.account).load().forecast(for: hero, at: snapshot.fetchedAt)
    }

    private var size: WidgetSize {
        switch family {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        default: return .large
        }
    }

    /// Settings written by the app next to the usage state (FR-23).
    static var style: WidgetStyle {
        SnapshotStore.loadStyle() ?? WidgetStyle()
    }
}
