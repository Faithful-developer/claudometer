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

        // `--sample high|rings|pinned|stale|signedout` renders made-up states for design review.
        let sample = args.firstIndex(of: "--sample").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
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
        case "signedout": initial = UsageState(error: .notSignedIn)
        default: initial = nil
        }
        let store = UsageStore(markCachedStale: false, initialState: initial)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let settings = AppSettings.current
                let (window, extras) = settings.menuBarWindows(store.state.snapshot)
                for compact in [false, true] {
                    let icon = MenuBarIcon.image(
                        primary: MenuBarIcon.Ring(window: window, level: settings.level(for: window?.utilization)),
                        extras: extras.map { MenuBarIcon.Ring(window: $0, level: settings.level(for: $0.utilization), letter: true) },
                        stale: false,
                        compact: compact
                    )
                    write(icon, scale: 4, to: dir.appendingPathComponent("menubar\(compact ? "-compact" : "")-\(name)\(suffix(sample)).png"))
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
                write(image, scale: pixelScale, to: dir.appendingPathComponent("popover-\(name)\(suffix(sample)).png"))
            }

            // The clipboard card from clicking a limit in the popover.
            if let snapshot = store.state.snapshot,
               let image = LimitImage.image(snapshot: snapshot, stale: store.state.isStale, now: Date(), colorScheme: name == "dark" ? .dark : .light) {
                write(image, scale: LimitImage.scale, to: dir.appendingPathComponent("copy-\(name)\(suffix(sample)).png"))
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
                    write(image, scale: pixelScale, to: dir.appendingPathComponent("settings-\(tab)-\(name)\(suffix(sample)).png"))
                }
            }

            let settings = AppSettings.current
            let style = WidgetStyle(metric: settings.menuBarMetric, warning: settings.warningThreshold, critical: settings.criticalThreshold)
            for size in WidgetSize.allCases {
                // Mimics the desktop widget chrome: 16pt content margins, continuous corners.
                let widget = UsageWidgetContent(size: size, state: store.state, now: Date(), style: style, refreshControl: AnyView(RefreshGlyph()))
                    .padding(16)
                    .frame(width: size.size.width, height: size.size.height)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(12)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                let widgetRenderer = ImageRenderer(content: widget)
                widgetRenderer.scale = pixelScale
                if let image = widgetRenderer.nsImage {
                    write(image, scale: pixelScale, to: dir.appendingPathComponent("widget-\(size.rawValue)-\(name)\(suffix(sample)).png"))
                }
            }
        }
        print("Wrote previews to \(dir.path)")
        exit(0)
    }

    /// Output pixels per point. `image.size` is in points, so writing at 1 threw away the
    /// renderer's extra resolution and produced blurry screenshots.
    private static let pixelScale: CGFloat = 3

    private static func suffix(_ sample: String?) -> String { sample.map { "-\($0)" } ?? "" }

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

    private static func write(_ image: NSImage, scale: CGFloat, to url: URL) {
        try? LimitImage.pngData(image, scale: scale)?.write(to: url)
    }
}
