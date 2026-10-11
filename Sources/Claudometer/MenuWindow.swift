import AppKit
import ClaudometerCore
import SwiftUI

/// Native menu background (the same material `NSMenu` uses), with a light wash of the window
/// colour so text keeps its contrast over busy or dark content behind the menu.
struct MenuBackground: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .menu)
            Palette.canvas.opacity(0.6)
        }
        .ignoresSafeArea()
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// `MenuBarExtra(.window)` grows when its content grows but never shrinks, which leaves an
/// empty gap after e.g. an error notice disappears. This keeps the window's height equal to
/// the content height, anchored at the top edge under the menu bar.
struct FitMenuWindowHeight: ViewModifier {
    @StateObject private var holder = WindowHolder()
    @Environment(\.isPreviewRender) private var isPreviewRender

    func body(content: Content) -> some View {
        if isPreviewRender {
            // ImageRenderer cannot draw AppKit-backed views.
            content
        } else {
            fitted(content)
        }
    }

    private func fitted(_ content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onHostingWindow(holder.attach)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                holder.fit(contentHeight: height)
            }
    }
}

extension View {
    func fitsMenuWindowHeight() -> some View { modifier(FitMenuWindowHeight()) }

    /// Calls `action` with the AppKit window hosting this view, once it is in one.
    func onHostingWindow(_ action: @escaping (NSWindow?) -> Void) -> some View {
        background(WindowReader(onWindow: action))
    }
}

/// The menu bar item's menu, i.e. the `MenuBarExtra` panel.
@MainActor
enum MenuBarMenu {
    fileprivate static weak var window: NSWindow?

    /// Closes the menu the way a click on the icon does, so the icon's highlight goes too.
    /// (`NSWindow.close()` alone hides the panel but leaves the icon highlighted.)
    static func close() {
        guard let window, window.isVisible else { return }
        if let button = statusItemButton() {
            button.performClick(nil)
        } else {
            window.close()
        }
    }

    /// SwiftUI doesn't expose the `NSStatusItem` behind `MenuBarExtra`, so look for its
    /// button in the status bar window that hosts it.
    private static func statusItemButton() -> NSStatusBarButton? {
        func find(in view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.lazy
            .filter { $0.className == "NSStatusBarWindow" }
            .compactMap { $0.contentView.flatMap(find) }
            .first
    }
}

@MainActor
final class WindowHolder: ObservableObject {
    weak var window: NSWindow?
    private var pendingHeight: CGFloat?
    private var spaceObserver: NSObjectProtocol?

    /// Like system menus, the menu closes when the user switches desktops. Otherwise an
    /// accessory app's panel never resigns key and stays open on the desktop it was opened on.
    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarMenu.close() }
        }
    }

    deinit {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    func attach(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
        MenuBarMenu.window = window
        if let pendingHeight { fit(contentHeight: pendingHeight) }
    }

    func fit(contentHeight: CGFloat) {
        pendingHeight = contentHeight
        guard let window, contentHeight > 0 else { return }
        DispatchQueue.main.async {
            let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: window.frame.width, height: contentHeight))
            guard abs(target.height - window.frame.height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - target.height
            frame.size.height = target.height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
