import AppKit
import ClaudometerCore

/// Draws the menu bar item: a coloured progress ring plus the percent (TZ FR-2…FR-5).
///
/// Rendered as one non-template `NSImage` so the ring keeps its colour; the text uses
/// `labelColor`, which is resolved at draw time and follows the menu bar appearance.
enum MenuBarIcon {
    static func image(utilization: Double?, level: UsageLevel, stale: Bool, compact: Bool, resetsAt: Date? = nil, now: Date = Date()) -> NSImage {
        let height: CGFloat = 18
        let ringSize: CGFloat = 14
        let text = utilization.map(Formatters.percent) ?? "—"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textWidth = compact ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let width = ringSize + 2 + (compact ? 0 : 4 + textWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let ringRect = NSRect(x: 1, y: (height - ringSize) / 2, width: ringSize, height: ringSize).insetBy(dx: 1.25, dy: 1.25)
            let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
            let radius = ringRect.width / 2

            let track = NSBezierPath(ovalIn: ringRect)
            track.lineWidth = 2.5
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()

            if let utilization {
                let fraction = min(max(utilization, 0), 100) / 100
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = 2.5
                arc.lineCapStyle = .round
                color(for: stale ? .ok : level).setStroke()
                if fraction > 0 { arc.stroke() }
            }

            if !compact {
                let color = stale ? NSColor.secondaryLabelColor : NSColor.labelColor
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: NSPoint(x: ringSize + 6, y: (height - size.height) / 2), withAttributes: attributes)
            }
            return true
        }
        // Template (monochrome, tinted by the system like other menu bar icons) unless there
        // is a warning to show in colour.
        image.isTemplate = stale || level == .ok || level == .unknown
        image.accessibilityDescription = accessibilityDescription(utilization: utilization, level: level, stale: stale, resetsAt: resetsAt, now: now)
        return image
    }

    /// "Claude usage 91 percent, near limit, Resets in 2h 40m".
    static func accessibilityDescription(utilization: Double?, level: UsageLevel, stale: Bool, resetsAt: Date?, now: Date) -> String {
        guard let utilization else { return "Claude usage unavailable" }
        var parts = ["Claude usage \(Int(max(utilization, 0).rounded())) percent"]
        if let label = Formatters.levelLabel(level) { parts.append(stale ? "last known \(label)" : label) }
        parts.append(stale ? "out of date" : Formatters.resetText(resetsAt, now: now))
        return parts.joined(separator: ", ")
    }

    /// Calm by default: plain ink while usage is fine; status colours only when it isn't.
    /// Status colours are palette tokens resolved against the menu bar's appearance at draw
    /// time; light uses the darker amber glyph step so warning stays ≥3:1 on a light bar.
    static func color(for level: UsageLevel) -> NSColor {
        PaletteNS.glyph(for: level)
    }
}
