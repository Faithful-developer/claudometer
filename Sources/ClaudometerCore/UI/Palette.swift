import AppKit
import SwiftUI

/// Claudometer colour system (docs/palette.html). Light values are the brand palette; dark
/// values are selected steps of the same hues (series steps validated with the data-viz
/// checker: CVD and normal-vision separation pass in both modes).
public enum Palette {
    // Brand
    public static let coral = dynamic(light: 0xE76F51, dark: 0xD76549)
    public static let coralPressed = dynamic(light: 0xD95E43, dark: 0xC85A40)
    /// Light end of the meter fill (palette demo gradient).
    public static let coralLight = dynamic(light: 0xF29A72, dark: 0xE88A68)
    public static let coralSoft = dynamic(light: 0xFCEAE5, dark: 0x3B2520)
    public static let plum = dynamic(light: 0x51405F, dark: 0x7D539D)

    // Surfaces
    public static let canvas = dynamic(light: 0xF7F6F3, dark: 0x1E1D23)
    /// Cards (widgets) sit on white.
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x26252C)
    public static let border = dynamic(light: 0xE8E6E2, dark: 0x36353C)
    /// Unfilled meter/ring track. Under Increase Contrast it steps up to a visible grey.
    public static let track = dynamic(light: 0xF0EEEB, dark: 0x34333A, lightHC: 0xC9C6C0, darkHC: 0x5A5961)
    /// Ring track. Stronger than `track` (dark 2.0:1 vs surface, light 1.45:1): on a ring the
    /// track is the only thing that draws the circle, so the meter track nearly vanished there.
    public static let ringTrack = dynamic(light: 0xD9D6D0, dark: 0x55545C, lightHC: 0xC9C6C0, darkHC: 0x6A6971)
    /// Explicit Increase Contrast track, for views that read `colorSchemeContrast`.
    public static let trackIncreased = dynamic(light: 0xC9C6C0, dark: 0x5A5961)

    // Status (fill + tint)
    public static let teal = dynamic(light: 0x278C82, dark: 0x00A99C)
    public static let tealSoft = dynamic(light: 0xE4F3F0, dark: 0x183330)
    public static let warning = dynamic(light: 0xD59A32, dark: 0xE2A848)
    public static let warningSoft = dynamic(light: 0xFBF2DE, dark: 0x3A2E18)
    public static let critical = dynamic(light: 0xC95656, dark: 0xE06A6A)
    public static let criticalSoft = dynamic(light: 0xF9E9E8, dark: 0x3B2224)
    public static let info = dynamic(light: 0x5577C8, dark: 0x7393DF)
    public static let infoSoft = dynamic(light: 0xE9EEFA, dark: 0x1F2840)

    /// Glyph steps for status symbols and icons (never fills, never text). The amber fill is
    /// only 2.3:1 on canvas in light, so its symbols use a darker step of the same hue.
    /// Ratios vs canvas / surface / soft tint (WCAG 2.x):
    ///   warningGlyph  light #A87412 3.76 / 4.06 / 3.65   dark #E2A848 7.91 / 7.18 / 6.27
    ///   criticalGlyph light #C95656 3.93 / 4.24 / 3.61   dark #E06A6A 5.13 / 4.65 / 4.47
    ///   teal          light #278C82 3.77 / 4.07 / 3.56   dark #00A99C 5.70 / 5.17 / 4.60
    ///   info          light #5577C8 4.00 / 4.32 / 3.72   dark #7393DF 5.55 / 5.04 / 4.85
    public static let warningGlyph = dynamic(light: 0xA87412, dark: 0xE2A848)
    public static let criticalGlyph = critical

    /// Data series in palette order: Usage (coral), Spend (plum), Capacity (teal).
    public static let series: [Color] = [coral, plum, teal]
    public static let seriesOther = dynamic(light: 0x9A9890, dark: 0x6E6D68)

    public static var brand: Color { coral }

    /// Meter fill. Normal usage is the brand coral; status colours take over near limits.
    public static func fill(for level: UsageLevel) -> Color {
        switch level {
        case .ok: return coral
        case .warning: return warning
        case .critical: return critical
        case .unknown: return seriesOther
        }
    }

    /// Colour follows the entity, never its rank: known surfaces keep their slot.
    public static func color(forBreakdownKey key: String, unknownIndex: Int = 0) -> Color {
        switch key {
        case "claude_code": return series[0]
        case "chat": return series[1]
        case "cowork": return series[2]
        default: return seriesOther
        }
    }

    /// Symbol colour for a level (darker step than the fill where the fill is too light).
    public static func glyph(for level: UsageLevel) -> Color {
        switch level {
        case .ok: return coral
        case .warning: return warningGlyph
        case .critical: return criticalGlyph
        case .unknown: return Ink.secondary
        }
    }

    /// Short words that go with the status symbol, so state is never colour alone.
    public static func label(for level: UsageLevel) -> String? {
        switch level {
        case .warning: return "Getting close"
        case .critical: return "Near limit"
        case .ok, .unknown: return nil
        }
    }

    public static func symbol(for level: UsageLevel) -> String? {
        switch level {
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .ok, .unknown: return nil
        }
    }
}

/// Text colours from the palette (Ink, Muted), with their dark steps.
///
/// Contrast (WCAG 2.x) against canvas / surface:
///   primary   light #20202B 14.91 / 16.12   dark #F1EFEA ≥13 / ≥12
///   secondary light #5A5A66  6.29 /  6.80   dark #AEAEB8  7.61 /  6.90
///   tertiary  light #6E6E79  4.66 /  5.04   dark #8D8D97  5.09 /  4.62
/// Every step passes 4.5:1 and each stays visibly lighter (dark: dimmer) than the one above.
/// Under Increase Contrast tertiary takes the secondary value.
public enum Ink {
    public static let primary = Palette.dynamic(light: 0x20202B, dark: 0xF1EFEA)
    public static let secondary = Palette.dynamic(light: 0x5A5A66, dark: 0xAEAEB8)
    public static let tertiary = Palette.dynamic(light: 0x6E6E79, dark: 0x8D8D97, lightHC: 0x5A5A66, darkHC: 0xAEAEB8)
    /// Track behind meters and rings.
    public static var track: Color { Palette.track }
    /// Ring track in accented/vibrant widget rendering, where the system replaces our
    /// background and flattens colours: a translucent system primary stays visible on any tint.
    public static let trackVibrant = Color.primary.opacity(0.25)

    /// Environment-aware helpers for views that read `\.colorSchemeContrast`.
    public static func tertiary(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? secondary : tertiary
    }
    public static func track(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Palette.trackIncreased : Palette.track
    }
}

extension Palette {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: light, dark: dark, lightHC: light, darkHC: dark)
    }

    /// Light/dark plus the Increase Contrast appearances.
    static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> Color {
        Color(nsColor: nsDynamic(light: light, dark: dark, lightHC: lightHC, darkHC: darkHC))
    }

    static func nsDynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return NSColor(hex: dark)
            case .accessibilityHighContrastDarkAqua?: return NSColor(hex: darkHC ?? dark)
            case .accessibilityHighContrastAqua?: return NSColor(hex: lightHC ?? light)
            default: return NSColor(hex: light)
            }
        }
    }
}

/// AppKit versions of the status tokens, resolved at draw time against the current drawing
/// appearance (used by the menu bar icon, which follows the menu bar, not the app).
public enum PaletteNS {
    /// Darker amber in light so the glyph stays ≥3:1 on a light menu bar (#A87412 ≈ 3.6:1 on #F2F2F2).
    public static let warning = Palette.nsDynamic(light: 0xA87412, dark: 0xE2A848)
    public static let critical = Palette.nsDynamic(light: 0xC95656, dark: 0xE06A6A)

    public static func glyph(for level: UsageLevel) -> NSColor {
        switch level {
        case .ok: return .labelColor
        case .warning: return warning
        case .critical: return critical
        case .unknown: return .secondaryLabelColor
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
