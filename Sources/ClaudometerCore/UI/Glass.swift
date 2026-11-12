import AppKit
import SwiftUI
import WidgetKit

/// Liquid Glass support (macOS 26+). Glass sits only on the functional layer (the menu window,
/// its buttons and the account switcher), never on rings, meters or charts (HIG Materials).
/// Older systems keep the palette look.
public enum Glass {
    /// The system draws Liquid Glass (macOS 26 and later).
    public static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

private struct OnGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a view drawn on a system surface: the menu's Liquid Glass and the widget's
    /// system background on macOS 26. Text tokens then resolve to the system label colours,
    /// which adapt to whatever is behind; hover and track fills turn neutral. The brand colour
    /// stays on data and status only.
    public var isOnGlass: Bool {
        get { self[OnGlassKey.self] }
        set { self[OnGlassKey.self] = newValue }
    }
}

/// A text colour token. On opaque surfaces (widgets, copy card, older macOS) it is the palette
/// value; on glass it is the matching system label colour. `color` is the palette value for
/// the places that need a plain `Color`.
public struct InkStyle: ShapeStyle {
    public enum Level: Sendable { case primary, secondary, tertiary }

    public let level: Level
    public let color: Color

    public func resolve(in environment: EnvironmentValues) -> Color {
        // Vibrant widgets (the desktop behind windows) keep only brightness: dark palette text
        // went faint there, so they take the system label colours too.
        guard environment.isOnGlass || environment.widgetRenderingMode != .fullColor else { return color }
        switch level {
        case .primary: return Color(nsColor: .labelColor)
        // Tertiary takes the secondary label colour: the system tertiary is about 2.5:1, under
        // the 4.5:1 every text step here keeps (context/style-guide.md).
        case .secondary, .tertiary: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// Neutral fills for glass: the system's hierarchical fills instead of the warm palette tints,
/// which would tint the glass and fight the content behind it.
public enum GlassFill {
    /// Row hover, like the system menu highlight without the accent colour.
    public static let hover = Color.primary.opacity(0.09)
    public static let pressed = Color.primary.opacity(0.15)
    /// Inset areas such as the notice box and the grey status pill.
    public static let inset = Color.primary.opacity(0.06)
    /// Unfilled part of meters and the daily bars: see-through, like the system gauges, so it
    /// reads on any glass. Stronger under Increase Contrast.
    public static func track(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.22 : 0.10)
    }
    /// Ring track: the track is all that draws the circle, so it is stronger than a meter's,
    /// and stronger again on a hovered row.
    public static func ringTrack(highlighted: Bool) -> Color {
        Color.primary.opacity(highlighted ? 0.24 : 0.16)
    }
}

/// The widget's background: the system widget background on macOS 26, where the text uses the
/// system label colours with it (`isOnGlass`); the palette surface on older systems. In the
/// vibrant (desktop) mode the system removes it either way.
public struct WidgetBackground: View {
    public init() {}

    public var body: some View {
        if Glass.isAvailable {
            Rectangle().fill(.background)
        } else {
            Palette.surface
        }
    }
}
