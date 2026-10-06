import AppIntents
import ClaudometerCore
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let state: UsageState
}

/// Reads the state the app writes to the App Group container. Never touches the network (FR-11).
struct UsageProvider: TimelineProvider {
    private let store = SnapshotStore.default()

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), state: UsageState(snapshot: .placeholder))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let state = store.load() ?? UsageState(snapshot: context.isPreview ? .placeholder : nil, error: nil)
        completion(UsageEntry(date: Date(), state: state))
    }

    /// Entries every 15 min for 2 h so countdowns stay roughly right between app reloads (FR-13).
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // No shared state yet (app never ran, or the App Group is not readable): ask to open the app.
        let state = store.load() ?? UsageState()
        let now = Date()
        // Each entry projects its own time, so a limit that resets while the app can't fetch
        // drops to 0% on schedule instead of showing the old figure.
        let entries = (0..<8).map { step -> UsageEntry in
            let date = now.addingTimeInterval(Double(step) * 15 * 60)
            return UsageEntry(date: date, state: state.projected(at: date))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
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
        StaticConfiguration(kind: "ClaudometerWidget", provider: UsageProvider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(Palette.surface, for: .widget)
                .widgetURL(URL(string: "claudometer://open"))
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
        UsageWidgetContent(
            size: size, state: entry.state, now: entry.date, style: Self.style,
            refreshControl: AnyView(
                Button(intent: RefreshUsageIntent()) { RefreshGlyph() }
                    .buttonStyle(.plain)
            )
        )
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
