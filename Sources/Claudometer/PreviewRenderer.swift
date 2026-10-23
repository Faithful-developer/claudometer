import AppKit
import ClaudometerCore
import SwiftUI

/// `Claudometer --render-previews <dir>` writes PNGs of the menu bar icon, popover, widgets and Settings tabs using
/// the cached usage state, then exits. Used for docs screenshots and visual checks without
/// screen-recording permission.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-previews") else { return }
        let dir = URL(fileURLWithPath: args.count > index + 1 ? args[index + 1] : "previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // `--sample high|rings|pinned|stale|expired|signedout|accounts` renders made-up states for design review.
        let sample = args.firstIndex(of: "--sample").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        // `--language ru` renders in that language, from the repo's strings.
        let language = args.firstIndex(of: "--language").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        if let language {
            L10n.resourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Localization")
            L10n.resolve(language)
        }
        let initial: UsageState?
        switch sample {
        case "high": initial = highSample
        case "rings": initial = ringsSample
        case "pinned":
            initial = pinnedSample
            // The argument domain is volatile, so the user's own settings stay untouched.
            UserDefaults.standard.setVolatileDomain(
                [SettingsKey.menuBarPinnedLimits: MenuBarPins.encode(["weekly_all", "weekly_scoped:Fable"])],
                forName: UserDefaults.argumentDomain)
        case "stale": initial = UsageState(snapshot: highSample.snapshot, error: .offline)
        case "expired": initial = UsageState(snapshot: highSample.snapshot, error: .tokenExpired)
        case "signedout": initial = UsageState(error: .notSignedIn)
        case "accounts": initial = highSample
        default: initial = nil
        }
        let seeds: [UsageStore.Seed]
        if sample == "accounts" {
            seeds = accountsSample
        } else if let initial {
            seeds = [.init(account: .primary, state: initial, history: sampleHistory(initial))]
        } else {
            // The real accounts and their last known data, as saved.
            seeds = AccountStore.default().load().map { account in
                .init(account: account, state: SnapshotStore.default(account: account).load() ?? UsageState(),
                      history: HistoryStore.default(account: account).load())
            }
        }
        let store = UsageStore(seeds: seeds)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let settings = AppSettings.current
                let (window, extras) = settings.menuBarWindows(store.state.snapshot)
                // Plain, compact, and with the update dot.
                for (compact, badge) in [(false, false), (true, false), (false, true)] {
                    let icon = MenuBarIcon.image(
                        primary: MenuBarIcon.Ring(window: window, level: settings.level(for: window?.utilization)),
                        extras: extras.map { MenuBarIcon.Ring(window: $0, level: settings.level(for: $0.utilization), letter: true) },
                        stale: store.state.isStale || store.state.error != nil,
                        compact: compact,
                        updateBadge: badge
                    )
                    let variant = compact ? "-compact" : badge ? "-update" : ""
                    write(icon, scale: 4, to: dir.appendingPathComponent("menubar\(variant)-\(name)\(suffix(sample, language)).png"))
                }
            }

            let view = PopoverView()
                .environment(store)
                .environment(UpdateStore())
                .background(Palette.canvas)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .environment(\.isPreviewRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = pixelScale
            if let image = renderer.nsImage {
                write(image, scale: pixelScale, to: dir.appendingPathComponent("popover-\(name)\(suffix(sample, language)).png"))
            }

            // The weekly chart with a day under the pointer; hover never fires in ImageRenderer.
            let weeklyId = store.state.snapshot?.weekly?.id ?? "weekly_all"
            if store.history.daysWithData(windowId: weeklyId) >= 2 {
                let days = store.history.dailyUse(windowId: weeklyId, now: Date())
                let hoverRenderer = ImageRenderer(content: DailyUseSection(days: days, hovered: max(days.count - 3, 0))
                    .frame(width: 300)
                    .background(Palette.canvas)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light))
                hoverRenderer.scale = pixelScale
                if let image = hoverRenderer.nsImage {
                    write(image, scale: pixelScale, to: dir.appendingPathComponent("daily-hover-\(name)\(suffix(sample, language)).png"))
                }
            }

            // The clipboard card from clicking a limit in the popover.
            if let snapshot = store.state.snapshot,
               let image = LimitImage.image(snapshot: snapshot, account: store.hasManyAccounts ? store.selected.title : nil, stale: store.state.isStale, now: Date(), colorScheme: name == "dark" ? .dark : .light) {
                write(image, scale: LimitImage.scale, to: dir.appendingPathComponent("copy-\(name)\(suffix(sample, language)).png"))
            }

            // Each Settings tab on its own, at the window's width. The TabView chrome is
            // system-drawn and not worth rendering.
            let tabs: [(String, AnyView)] = [
                ("general", AnyView(GeneralSettings())),
                ("notifications", AnyView(NotificationSettings())),
                ("login", AnyView(LoginSettings())),
                ("about", AnyView(AboutSettings())),
            ]
            for (tab, content) in tabs {
                let page = content
                    .environment(store)
                    .environment(UpdateStore())
                    .background(Palette.canvas)
                if let image = snapshot(page, width: 460, appearance: appearance) {
                    write(image, scale: pixelScale, to: dir.appendingPathComponent("settings-\(tab)-\(name)\(suffix(sample, language)).png"))
                }
            }

            let settings = AppSettings.current
            let style = WidgetStyle(metric: settings.menuBarMetric, warning: settings.warningThreshold, critical: settings.criticalThreshold)
            for size in WidgetSize.allCases {
                // Mimics the desktop widget chrome: 16pt content margins, continuous corners.
                let hero = store.state.snapshot?.window(for: style.metric)
                let forecast = size == .large && store.state.error == nil
                    ? hero.flatMap { store.history.forecast(for: $0, at: store.state.snapshot!.fetchedAt) } : nil
                let widget = UsageWidgetContent(size: size, state: store.state, now: Date(), style: style, forecast: forecast, refreshControl: AnyView(RefreshGlyph()),
                                                account: store.hasManyAccounts ? store.selected.title : nil)
                    .padding(16)
                    .frame(width: size.size.width, height: size.size.height)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(12)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                let widgetRenderer = ImageRenderer(content: widget)
                widgetRenderer.scale = pixelScale
                if let image = widgetRenderer.nsImage {
                    write(image, scale: pixelScale, to: dir.appendingPathComponent("widget-\(size.rawValue)-\(name)\(suffix(sample, language)).png"))
                }
            }
        }
        print("Wrote previews to \(dir.path)")
        exit(0)
    }

    /// Output pixels per point. `image.size` is in points, so writing at 1 threw away the
    /// renderer's extra resolution and produced blurry screenshots.
    private static let pixelScale: CGFloat = 3

    private static func suffix(_ sample: String?, _ language: String?) -> String {
        [sample, language].compactMap { $0.map { "-\($0)" } }.joined()
    }

    /// `ImageRenderer` draws only pure SwiftUI; grouped forms, sliders, pickers and buttons are
    /// AppKit-backed and come out blank. Hosting the view in an offscreen window and caching its
    /// display draws them properly, without needing the window on screen.
    private static func snapshot<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name) -> NSImage? {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.sizingOptions = .intrinsicContentSize
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.intrinsicContentSize.height
        window.setContentSize(NSSize(width: width, height: height))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Give SwiftUI a run loop turn to settle layout of the hosted controls.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * pixelScale), pixelsHigh: Int(bounds.height * pixelScale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// A made-up week for samples with data: the weekly limit climbing day by day since its
    /// reset five days ago, and the session rising fast over the last hour, so the usage per
    /// day and the pace forecast both show. Empty for the others (real history isn't read).
    private static func sampleHistory(_ state: UsageState?) -> UsageHistory {
        guard let snapshot = state?.snapshot, let weekly = snapshot.weekly, let session = snapshot.session,
              let weeklyReset = weekly.resetsAt, let sessionReset = session.resetsAt else { return UsageHistory() }
        let fetched = snapshot.fetchedAt
        let weekStart = weeklyReset.addingTimeInterval(-7 * 86400)
        var samples: [UsageHistory.Sample] = []
        // Last week, before the reset.
        for step in 0..<4 {
            let t = weekStart.addingTimeInterval(Double(step - 4) * 4 * 3600)
            samples.append(.init(t: t, u: [weekly.id: 60 + Double(step) * 4], r: [weekly.id: weekStart]))
        }
        // This week: a share of the current figure per day, read every 4 hours.
        let perDay: [Double] = [0.18, 0.12, 0.22, 0.13, 0.19, 0.16]
        var used = 0.0
        for (day, share) in perDay.enumerated() {
            for step in 1...6 {
                let t = weekStart.addingTimeInterval(Double(day) * 86400 + Double(step) * 4 * 3600)
                guard t < fetched.addingTimeInterval(-3600) else { break }
                used += weekly.utilization * share / 6
                samples.append(.init(t: t, u: [weekly.id: min(used, weekly.utilization)], r: [weekly.id: weeklyReset]))
            }
        }
        // The session over the last hour.
        for (minutes, value) in [(60.0, 78.0), (45, 81), (30, 85), (15, 88)] {
            samples.append(.init(t: fetched.addingTimeInterval(-minutes * 60),
                                 u: [session.id: value, weekly.id: weekly.utilization - 1],
                                 r: [session.id: sessionReset, weekly.id: weeklyReset]))
        }
        return UsageHistory(samples: samples.sorted { $0.t < $1.t })
    }

    private static var highSample: UsageState {
        let now = Date()
        return UsageState(snapshot: UsageSnapshot(
            windows: [
                LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 91, resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
                LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 68, resetsAt: now.addingTimeInterval(2 * 86400)),
                LimitWindow(id: "weekly_scoped:Opus", group: .weekly, title: "Weekly · Opus", utilization: 34, resetsAt: now.addingTimeInterval(2 * 86400)),
            ],
            breakdown: [
                BreakdownRow(key: "claude_code", title: "Claude Code", percent: 64),
                BreakdownRow(key: "chat", title: "Chats", percent: 21),
                BreakdownRow(key: "cowork", title: "Cowork", percent: 15),
            ],
            plan: "pro",
            fetchedAt: now.addingTimeInterval(-120)
        ))
    }

    /// Two other limits at 80%: the menu bar shows three rings.
    private static var ringsSample: UsageState {
        let now = Date()
        return UsageState(snapshot: UsageSnapshot(
            windows: [
                LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 50, resetsAt: now.addingTimeInterval(3 * 3600)),
                LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 80, resetsAt: now.addingTimeInterval(2 * 86400)),
                LimitWindow(id: "weekly_scoped:Fable", group: .weekly, title: "Weekly · Fable", utilization: 88, resetsAt: now.addingTimeInterval(2 * 86400)),
            ],
            plan: "max",
            fetchedAt: now.addingTimeInterval(-60)
        ))
    }

    /// Every limit well below the extra-ring threshold, with weekly and Fable added to the menu bar;
    /// Opus shows the disabled checkbox once two are added.
    private static var pinnedSample: UsageState {
        let now = Date()
        return UsageState(snapshot: UsageSnapshot(
            windows: [
                LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 26, resetsAt: now.addingTimeInterval(3 * 3600)),
                LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 41, resetsAt: now.addingTimeInterval(2 * 86400)),
                LimitWindow(id: "weekly_scoped:Fable", group: .weekly, title: "Weekly · Fable", utilization: 57, resetsAt: now.addingTimeInterval(2 * 86400)),
                LimitWindow(id: "weekly_scoped:Opus", group: .weekly, title: "Weekly · Opus", utilization: 12, resetsAt: now.addingTimeInterval(2 * 86400)),
            ],
            plan: "max",
            fetchedAt: now.addingTimeInterval(-60)
        ))
    }

    /// The most accounts there can be: Claude Code (selected), a work account running high,
    /// one whose key has expired and one with a long name.
    private static var accountsSample: [UsageStore.Seed] {
        let work = Account(id: "sample-work", name: "Work", orgUUID: "org-work")
        let side = Account(id: "sample-side", name: "Side project", orgUUID: "org-side")
        let client = Account(id: "sample-client", name: "Client team account", orgUUID: "org-client")
        let workState = UsageState(snapshot: ringsSample.snapshot?.withSource(.claudeWeb))
        let sideState = UsageState(snapshot: pinnedSample.snapshot?.withSource(.claudeWeb), error: .sessionKeyInvalid)
        let clientState = UsageState(snapshot: pinnedSample.snapshot?.withSource(.claudeWeb))
        return [
            .init(account: .primary, state: highSample, history: sampleHistory(highSample)),
            .init(account: work, state: workState, history: sampleHistory(workState)),
            .init(account: side, state: sideState, history: UsageHistory()),
            .init(account: client, state: clientState, history: sampleHistory(clientState)),
        ]
    }

    private static func write(_ image: NSImage, scale: CGFloat, to url: URL) {
        try? LimitImage.pngData(image, scale: scale)?.write(to: url)
    }
}
