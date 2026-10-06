import AppKit
import ClaudometerCore
import SwiftUI

/// `Claudometer --render-previews <dir>` writes PNGs of the menu bar icon and popover using
/// the cached usage state, then exits. Used for docs screenshots and visual checks without
/// screen-recording permission.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-previews") else { return }
        let dir = URL(fileURLWithPath: args.count > index + 1 ? args[index + 1] : "previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // `--sample high|stale|signedout` renders made-up states for design review.
        let sample = args.firstIndex(of: "--sample").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        let initial: UsageState?
        switch sample {
        case "high": initial = highSample
        case "stale": initial = UsageState(snapshot: highSample.snapshot, error: .offline)
        case "signedout": initial = UsageState(error: .notSignedIn)
        default: initial = nil
        }
        let store = UsageStore(markCachedStale: false, initialState: initial)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let window = store.state.snapshot?.window(for: AppSettings.current.menuBarMetric)
                let icon = MenuBarIcon.image(
                    utilization: window?.utilization,
                    level: AppSettings.current.level(for: window?.utilization),
                    stale: false,
                    compact: false,
                    resetsAt: window?.resetsAt
                )
                write(icon, scale: 4, to: dir.appendingPathComponent("menubar-\(name)\(suffix(sample)).png"))
            }

            let view = PopoverView()
                .environment(store)
                .background(Palette.canvas)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .environment(\.isPreviewRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage {
                write(image, scale: 1, to: dir.appendingPathComponent("popover-\(name)\(suffix(sample)).png"))
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
                widgetRenderer.scale = 2
                if let image = widgetRenderer.nsImage {
                    write(image, scale: 1, to: dir.appendingPathComponent("widget-\(size.rawValue)-\(name)\(suffix(sample)).png"))
                }
            }
        }
        print("Wrote previews to \(dir.path)")
        exit(0)
    }

    private static func suffix(_ sample: String?) -> String { sample.map { "-\($0)" } ?? "" }

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

    private static func write(_ image: NSImage, scale: CGFloat, to url: URL) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
