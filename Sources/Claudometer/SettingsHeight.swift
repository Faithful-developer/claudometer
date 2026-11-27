import AppKit
import SwiftUI

/// Settings tabs are as tall as their content, up to what fits on the window's screen; past
/// that the grouped `Form` scrolls in its own scroll view, so sections and scroll bars stay
/// native and the tab bar stays put.
///
/// A `Layout` in place of `.fixedSize(horizontal: false, vertical: true)`: it asks the content
/// for its ideal height (a nil height, as `.fixedSize` does), then reports and places it at
/// `min(ideal, maxHeight)`. Content that fits gets exactly the size it had before; taller
/// content gets a shorter frame and the Form scrolls. Nothing is measured into state, so a
/// tab that grows (an added account, a key check result) is re-fitted on the next layout pass.
/// The cap comes from `SettingsHeight`; without it (preview renders) it is unlimited.
private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SettingsMaxHeightKey: EnvironmentKey {
    static let defaultValue = CGFloat.infinity
}

extension EnvironmentValues {
    /// The tallest a Settings tab's content may be before it scrolls; see `SettingsHeight`.
    var settingsMaxHeight: CGFloat {
        get { self[SettingsMaxHeightKey.self] }
        set { self[SettingsMaxHeightKey.self] = newValue }
    }
}

private struct SettingsTabHeight: ViewModifier {
    @Environment(\.settingsMaxHeight) private var maxHeight

    func body(content: Content) -> some View {
        CappedHeightLayout(maxHeight: maxHeight) { content }
    }
}

extension View {
    /// A Settings tab's height: its content's, scrolling past `settingsMaxHeight`.
    func settingsTabHeight() -> some View { modifier(SettingsTabHeight()) }
}

/// How tall a Settings tab can be on the window's screen: the visible frame (no menu bar or
/// Dock) less the title bar and tab toolbar and a small margin above the Dock. Re-checked when
/// the window resizes (tab switch, content change), becomes key, or moves to another display,
/// and when screens change (Dock, resolution, scaling). Also keeps the window's bottom above
/// the Dock, since a window that grows keeps its top edge where it was.
@MainActor
final class SettingsHeight: ObservableObject {
    static let shared = SettingsHeight()

    /// Unlimited until the window is known.
    @Published private(set) var available = CGFloat.infinity

    /// Gap kept between the window and the Dock (or the screen's bottom edge).
    private static let margin: CGFloat = 12

    /// `--settings-max-height <points>` replaces the screen's height, to test scrolling on a
    /// large display.
    private static let override: CGFloat? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--settings-max-height"), args.count > index + 1,
              let points = Double(args[index + 1]), points > 0 else { return nil }
        return CGFloat(points)
    }()

    private weak var window: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    private init() {
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SettingsHeight.shared.update() }
        }
    }

    func attach(_ window: NSWindow) {
        if self.window !== window {
            self.window = window
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
            windowObservers = [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification,
                               NSWindow.didBecomeKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { SettingsHeight.shared.update() }
                }
            }
        }
        update()
    }

    private func update() {
        guard let window, let screen = window.screen else { return }
        let visible = screen.visibleFrame
        // Title bar and tab toolbar: they sit outside the content layout rect.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = Self.override ?? max(visible.height - chrome - Self.margin, 100)
        if height != available { available = height }

        // Move up, keeping x, so the bottom clears the Dock; never above the menu bar.
        let frame = window.frame
        if frame.minY < visible.minY {
            let y = min(visible.minY + Self.margin, visible.maxY - frame.height)
            if y > frame.minY { window.setFrameOrigin(NSPoint(x: frame.minX, y: y)) }
        }
    }
}
