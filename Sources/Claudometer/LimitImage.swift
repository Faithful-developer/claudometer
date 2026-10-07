import AppKit
import ClaudometerCore
import SwiftUI

/// Renders all plan limits as one shareable card and puts it on the clipboard (click any limit
/// in the popover).
@MainActor
enum LimitImage {
    /// Output pixels per point, matching the preview renders.
    static let scale: CGFloat = 3

    /// App name, "Plan Usage Limits · <plan>", one row per limit (title, "x% · resets …", meter),
    /// and the time the card was made, since the countdowns are relative.
    static func card(snapshot: UsageSnapshot, stale: Bool, now: Date, colorScheme: ColorScheme) -> some View {
        let settings = AppSettings.current
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // From the bundle's resources: `NSApp` is nil while the preview renderer runs, and an
                // unbundled dev binary would otherwise show the generic folder icon.
                if let icon = Bundle.main.image(forResource: "AppIcon") {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                }
                Text("Claudometer").font(.system(size: 17, weight: .bold)).foregroundStyle(Ink.primary)
            }
            SectionHeader(Formatters.planName(snapshot.plan).map { "Plan Usage Limits · \($0)" } ?? "Plan Usage Limits")
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.windows) { window in
                    CardRow(window: window, level: settings.level(for: window.utilization), stale: stale, now: now)
                }
            }
            .padding(.top, 10)
            Text(footer(snapshot: snapshot, stale: stale, now: now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 320)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, colorScheme)
    }

    private static func footer(snapshot: UsageSnapshot, stale: Bool, now: Date) -> String {
        stale
            ? "Last known · \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
            : now.formatted(date: .abbreviated, time: .shortened)
    }

    /// One limit: title on the left, "68% · resets Fri 21:53" on the right, meter below.
    private struct CardRow: View {
        let window: LimitWindow
        let level: UsageLevel
        let stale: Bool
        let now: Date

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(window.group == .session ? "Current Session" : window.title)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text("\(Formatters.percent(window.utilization)) · resets \(Formatters.shortReset(window.resetsAt, now: now))")
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                        .fixedSize()
                }
                .font(.system(size: 13))
                MeterBar(fraction: window.utilization / 100, level: stale ? .unknown : level, halo: Palette.canvas)
            }
        }
    }

    /// Draws the card in the given appearance; dynamic palette colours resolve against it.
    static func image(snapshot: UsageSnapshot, stale: Bool, now: Date, colorScheme: ColorScheme) -> NSImage? {
        var result: NSImage?
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: card(snapshot: snapshot, stale: stale, now: now, colorScheme: colorScheme))
            renderer.scale = scale
            result = renderer.nsImage
        }
        return result
    }

    /// Returns true when the image reached the clipboard.
    @discardableResult
    static func copy(snapshot: UsageSnapshot?, stale: Bool, now: Date, colorScheme: ColorScheme) -> Bool {
        guard let snapshot,
              let image = image(snapshot: snapshot, stale: stale, now: now, colorScheme: colorScheme),
              let png = pngData(image, scale: scale) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // PNG for apps that prefer it, TIFF for the rest (Notes, Preview's "New from Clipboard").
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        return true
    }

    /// Redraws `image` (sized in points) into a bitmap at `scale` pixels per point and encodes it as PNG.
    static func pngData(_ image: NSImage, scale: CGFloat) -> Data? {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
