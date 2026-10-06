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
            .background(WindowReader(holder: holder))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                holder.fit(contentHeight: height)
            }
    }
}

extension View {
    func fitsMenuWindowHeight() -> some View { modifier(FitMenuWindowHeight()) }
}

@MainActor
final class WindowHolder: ObservableObject {
    weak var window: NSWindow?
    private var pendingHeight: CGFloat?

    func attach(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
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
    let holder: WindowHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { holder.attach(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { holder.attach(view.window) }
    }
}
