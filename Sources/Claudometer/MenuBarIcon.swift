import AppKit
import ClaudometerCore

/// Draws the menu bar item: a coloured progress ring plus the percent (TZ FR-2…FR-5), then a
/// lettered ring for each other limit that is running high (FR-27), e.g. `◔ 42%  Ⓦ 80%  Ⓕ 80%`.
///
/// Rendered as one non-template `NSImage` so the rings keep their colour; the text uses
/// `labelColor`, which is resolved at draw time and follows the menu bar appearance.
enum MenuBarIcon {
    struct Ring {
        var utilization: Double?
        var level: UsageLevel
        var resetsAt: Date?
        /// Spoken name, e.g. "Weekly · Fable".
        var title: String
        /// Drawn inside the ring; extra rings only.
        var letter: String?

        init(window: LimitWindow?, level: UsageLevel, letter: Bool = false) {
            utilization = window?.utilization
            self.level = level
            resetsAt = window?.resetsAt
            title = window?.title ?? ""
            self.letter = letter ? window?.badgeLetter : nil
        }
    }

    private static let height: CGFloat = 18
    private static let ringSize: CGFloat = 14
    /// Clearly wider than the ring-to-percent space, so each ring reads with its own percent.
    private static let ringGap: CGFloat = 12
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let letterFont = NSFont.systemFont(ofSize: 7, weight: .bold)

    static func image(primary: Ring, extras: [Ring], stale: Bool, compact: Bool, now: Date = Date()) -> NSImage {
        let rings = [primary] + extras
        let width = rings.map { ringWidth($0, compact: compact) }.reduce(0, +) + ringGap * CGFloat(extras.count)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for ring in rings {
                draw(ring, at: x, stale: stale, compact: compact)
                x += ringWidth(ring, compact: compact) + ringGap
            }
            return true
        }
        // Template (monochrome, tinted by the system like other menu bar icons) unless there
        // is a warning to show in colour.
        image.isTemplate = stale || rings.allSatisfy { $0.level == .ok || $0.level == .unknown }
        image.accessibilityDescription = ([accessibilityDescription(utilization: primary.utilization, level: primary.level, stale: stale, resetsAt: primary.resetsAt, now: now)]
            + extras.map { extraDescription($0, stale: stale, now: now) }).joined(separator: ". ")
        return image
    }

    private static func text(_ ring: Ring) -> String { ring.utilization.map(Formatters.percent) ?? "—" }

    private static func ringWidth(_ ring: Ring, compact: Bool) -> CGFloat {
        let textWidth = compact ? 0 : ceil((text(ring) as NSString).size(withAttributes: [.font: font]).width)
        return ringSize + 2 + (compact ? 0 : 4 + textWidth)
    }

    private static func draw(_ ring: Ring, at x: CGFloat, stale: Bool, compact: Bool) {
        let ringRect = NSRect(x: x + 1, y: (height - ringSize) / 2, width: ringSize, height: ringSize).insetBy(dx: 1.25, dy: 1.25)
        let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
        let radius = ringRect.width / 2
        let tint = color(for: stale ? .ok : ring.level)

        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = 2.5
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        track.stroke()

        if let utilization = ring.utilization {
            let fraction = min(max(utilization, 0), 100) / 100
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            tint.setStroke()
            if fraction > 0 { arc.stroke() }
        }

        // Which limit an extra ring is. Plain ink: the arc carries the status colour, and 7 pt
        // amber or red text on a light bar would fall below text contrast.
        if let letter = ring.letter {
            let attributes: [NSAttributedString.Key: Any] = [.font: letterFont, .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        }

        if !compact {
            let color = stale ? NSColor.secondaryLabelColor : NSColor.labelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text(ring) as NSString).size(withAttributes: attributes)
            (text(ring) as NSString).draw(at: NSPoint(x: x + ringSize + 6, y: (height - size.height) / 2), withAttributes: attributes)
        }
    }

    /// "Claude usage 91 percent, near limit, Resets in 2h 40m".
    static func accessibilityDescription(utilization: Double?, level: UsageLevel, stale: Bool, resetsAt: Date?, now: Date) -> String {
        guard let utilization else { return "Claude usage unavailable" }
        var parts = ["Claude usage \(Int(max(utilization, 0).rounded())) percent"]
        if let label = Formatters.levelLabel(level) { parts.append(stale ? "last known \(label)" : label) }
        parts.append(stale ? "out of date" : Formatters.resetText(resetsAt, now: now))
        return parts.joined(separator: ", ")
    }

    /// "Weekly Fable 80 percent, near limit, Resets Sat 10:59".
    private static func extraDescription(_ ring: Ring, stale: Bool, now: Date) -> String {
        var parts = ["\(ring.title.replacingOccurrences(of: " · ", with: " ")) \(Int(max(ring.utilization ?? 0, 0).rounded())) percent"]
        if let label = Formatters.levelLabel(ring.level) { parts.append(stale ? "last known \(label)" : label) }
        if !stale { parts.append(Formatters.resetText(ring.resetsAt, now: now)) }
        return parts.joined(separator: ", ")
    }

    /// Calm by default: plain ink while usage is fine; status colours only when it isn't.
    /// Status colours are palette tokens resolved against the menu bar's appearance at draw
    /// time; light uses the darker amber glyph step so warning stays ≥3:1 on a light bar.
    static func color(for level: UsageLevel) -> NSColor {
        PaletteNS.glyph(for: level)
    }
}
