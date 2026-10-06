import SwiftUI
import WidgetKit

/// Linear capacity meter in the style of macOS progress bars: a thin capsule on a
/// system-fill track. The fill carries severity; an optional tick marks how much of the
/// window's time has passed, which turns the bar into a pace check.
public struct MeterBar: View {
    let fraction: Double
    let level: UsageLevel
    let elapsed: Double?
    let height: CGFloat
    let halo: Color
    @Environment(\.colorSchemeContrast) private var contrast

    /// `halo` is the colour behind the meter (canvas in the popover, surface on widgets); it
    /// outlines the pace tick so the tick reads over both the track and the fill.
    public init(fraction: Double, level: UsageLevel, elapsed: Double? = nil, height: CGFloat = 6, halo: Color = Palette.surface) {
        self.fraction = fraction
        self.level = level
        self.elapsed = elapsed
        self.height = height
        self.halo = halo
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.track(contrast))
                Capsule()
                    // The value end is the strongest coral; the gradient lightens towards zero.
                    .fill(level == .ok
                        ? AnyShapeStyle(LinearGradient(colors: [Palette.coralLight, Palette.coral], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Palette.fill(for: level)))
                    .frame(width: clamped > 0 ? max(width * clamped, height) : 0)
                    .widgetAccentable()
                if let elapsed {
                    let x = min(max(width * elapsed - 1, 1), width - 3)
                    Capsule()
                        .fill(halo)
                        .frame(width: 4, height: height + 8)
                        .offset(x: x - 1)
                    Capsule()
                        .fill(Ink.secondary)
                        .frame(width: 2, height: height + 6)
                        .offset(x: x)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: elapsed == nil ? height : height + 8)
    }
}

/// Circular capacity gauge, like the Batteries widget.
public struct RingGauge<Label: View>: View {
    let fraction: Double
    let level: UsageLevel
    let lineWidth: CGFloat
    let label: Label
    @Environment(\.widgetRenderingMode) private var renderingMode

    public init(fraction: Double, level: UsageLevel, lineWidth: CGFloat = 6, @ViewBuilder label: () -> Label) {
        self.fraction = fraction
        self.level = level
        self.lineWidth = lineWidth
        self.label = label()
    }

    public var body: some View {
        ZStack {
            Circle().stroke(renderingMode == .fullColor ? Palette.ringTrack : Ink.trackVibrant, lineWidth: lineWidth)
            GeometryReader { proxy in
                Circle()
                    .trim(from: 0, to: drawnFraction(diameter: min(proxy.size.width, proxy.size.height)))
                    .stroke(fillColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            label
        }
        .padding(lineWidth / 2)
    }

    /// Stale rings use secondary ink: the grey series colour was under 3:1 on the track and
    /// read as a faint blob at low values. The "Last known" label says why it is grey.
    private var fillColor: Color {
        level == .unknown ? Ink.secondary : Palette.fill(for: level)
    }

    /// Any value above zero draws at least one stroke width of arc, so 1% reads as the start
    /// of an arc rather than a round-cap dot. 0% draws nothing and the track shows the scale.
    private func drawnFraction(diameter: CGFloat) -> CGFloat {
        let value = min(max(fraction, 0), 1)
        guard value > 0, diameter > 0 else { return 0 }
        return max(value, lineWidth / (.pi * diameter))
    }
}

/// Percent figure: proportional digits, smaller "%" sign. Over 100 reads "100%+".
/// `dimmed` (stale data) moves the figure to secondary ink, which still passes 4.5:1.
public struct PercentText: View {
    let value: Double?
    let size: CGFloat
    let weight: Font.Weight
    let dimmed: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ value: Double?, size: CGFloat, weight: Font.Weight = .semibold, dimmed: Bool = false) {
        self.value = value
        self.size = size
        self.weight = weight
        self.dimmed = dimmed
    }

    public var body: some View {
        if let value {
            Text("\(Int(min(max(value, 0), 100).rounded()))")
                .font(.system(size: size, weight: weight, design: .rounded))
                .foregroundStyle(dimmed ? Ink.secondary : Ink.primary)
            + Text(value > 100 ? "%+" : "%")
                .font(.system(size: size * 0.55, weight: weight, design: .rounded))
                .foregroundStyle(Ink.secondary)
        } else {
            Text("—").font(.system(size: size, weight: weight, design: .rounded)).foregroundStyle(Ink.tertiary(contrast))
        }
    }
}

/// Status pill: symbol + label on a soft tint of the status colour, so state never relies
/// on colour alone. `On track` / `Ahead of pace` when usage is normal. With `stale`, the
/// last known warning stays visible but is worded as such on a neutral tint, and pace
/// (which needs live data) is hidden.
public struct StatusLabel: View {
    let level: UsageLevel
    let pace: Pace?
    let stale: Bool

    public init(level: UsageLevel, pace: Pace? = nil, stale: Bool = false) {
        self.level = level
        self.pace = pace
        self.stale = stale
    }

    public var body: some View {
        if let (symbol, text, color, tint) = content {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(text).foregroundStyle(Ink.primary)
            }
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint, in: Capsule())
        }
    }

    private var content: (String, String, Color, Color)? {
        if stale {
            guard let symbol = Palette.symbol(for: level), let label = Formatters.levelLabel(level) else { return nil }
            return (symbol, "Last known: \(label)", Palette.glyph(for: level), Palette.track)
        }
        switch level {
        case .critical: return ("exclamationmark.octagon.fill", "Near limit", Palette.criticalGlyph, Palette.criticalSoft)
        case .warning: return ("exclamationmark.triangle.fill", "Getting close", Palette.warningGlyph, Palette.warningSoft)
        case .ok:
            switch pace {
            case .ahead: return ("speedometer", "Ahead of pace", Palette.info, Palette.infoSoft)
            case .under, .on: return ("checkmark.circle.fill", "On track", Palette.teal, Palette.tealSoft)
            case nil: return nil
            }
        case .unknown: return nil
        }
    }
}

/// Compact status cue for rows: the level symbol plus its short label in secondary ink.
public struct LevelTag: View {
    let level: UsageLevel
    let stale: Bool
    let showsText: Bool

    public init(level: UsageLevel, stale: Bool = false, showsText: Bool = true) {
        self.level = level
        self.stale = stale
        self.showsText = showsText
    }

    public var body: some View {
        if let symbol = Palette.symbol(for: level) {
            HStack(spacing: 3) {
                Image(systemName: symbol).foregroundStyle(stale ? Ink.secondary : Palette.glyph(for: level))
                if showsText, let label = Palette.label(for: level) {
                    Text(label).foregroundStyle(Ink.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

/// Part-to-whole: one stacked bar with 2pt gaps, plus a legend that doubles as the
/// table view (swatch, name, value), so identity is never colour alone.
public struct BreakdownChart: View {
    public enum Legend: Sendable { case table, inline }

    let rows: [BreakdownRow]
    let legend: Legend
    let dimmed: Bool

    /// `dimmed` (stale data): grey fills and swatches, values in secondary ink; the names
    /// still identify each surface.
    public init(rows: [BreakdownRow], legend: Legend = .table, dimmed: Bool = false) {
        self.rows = rows.filter { $0.percent > 0 }
        self.legend = legend
        self.dimmed = dimmed
    }

    private func color(_ row: BreakdownRow) -> Color {
        dimmed ? Palette.seriesOther : Palette.color(forBreakdownKey: row.key)
    }

    private var valueInk: Color { dimmed ? Ink.secondary : Ink.primary }

    public var body: some View {
        let total = max(rows.reduce(0) { $0 + $1.percent }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let available = proxy.size.width - CGFloat(max(rows.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(rows) { row in
                        Rectangle()
                            .fill(color(row))
                            .frame(width: max(available * row.percent / total, 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            switch legend {
            case .table:
                VStack(spacing: 3) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            Circle().fill(color(row)).frame(width: 7, height: 7)
                            Text(row.title).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text("\(Int(row.percent.rounded()))%").monospacedDigit().fontWeight(.medium).foregroundStyle(valueInk)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            case .inline:
                // At most three entries; anything past the second folds into "Other".
                HStack(spacing: 10) {
                    ForEach(Self.folded(rows)) { row in
                        HStack(spacing: 4) {
                            Circle().fill(color(row)).frame(width: 6, height: 6)
                            Text(row.title).foregroundStyle(Ink.secondary).truncationMode(.tail)
                            Text("\(Int(row.percent.rounded()))%").fontWeight(.semibold).foregroundStyle(valueInk)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.caption2)
            }
        }
    }

    static func folded(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        guard rows.count > 3 else { return rows }
        let rest = rows.dropFirst(2).reduce(0) { $0 + $1.percent }
        return Array(rows.prefix(2)) + [BreakdownRow(key: "other", title: "Other", percent: rest)]
    }
}

/// Section header as in macOS menus and Control Center: small, bold, secondary, Title Case.
public struct SectionHeader: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ink.secondary)
    }
}
