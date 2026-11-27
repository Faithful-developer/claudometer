import AppKit
import ClaudometerCore
import SwiftUI

/// First-launch welcome (TZ FR-24, R-2): what Claudometer reads, the Keychain prompt that may
/// appear, and how to sign in. Shown once, on a fresh install, before the first Keychain
/// read: usage polling starts only when it closes, so any prompt comes after it's explained.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    /// Started when the welcome closes; set while it's waiting.
    private static var store: UsageStore?
    private static var finished = false
    /// Set when the app quits: AppKit then closes the window, which isn't a Continue.
    private static var isTerminating = false

    /// Decided once per launch, before Open at Login is turned on (that marks an install as
    /// not new). Fresh means the bundled app, with no welcome seen, Open at Login never set up
    /// and no usage saved: every earlier install has one of those, so upgraders never see it.
    /// Anything else marks it as not needed, so it can't appear later. `--show-welcome` forces
    /// it, for testing.
    static func isNeeded() -> Bool {
        if CommandLine.arguments.contains("--show-welcome") { return true }
        let defaults = UserDefaults.standard
        let fresh = NotificationManager.isAvailable
            && !defaults.bool(forKey: SettingsKey.welcomeShown)
            && !defaults.bool(forKey: SettingsKey.loginItemOffered)
            && !FileManager.default.fileExists(atPath: SnapshotStore.default().fileURL.path)
        if !fresh { defaults.set(true, forKey: SettingsKey.welcomeShown) }
        return fresh
    }

    /// Holds `store` back until the welcome closes; `show()` puts it on screen.
    static func wait(for store: UsageStore) {
        self.store = store
    }

    /// From `applicationDidFinishLaunching`: `App.init` is too early for windows.
    static func show() {
        guard store != nil, !finished, window == nil else { return }
        let content = NSHostingView(rootView: WelcomeView { finish() }
            // Same text colours as Settings, on the same system window background.
            .environment(\.isOnGlass, Glass.isAvailable))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = content
        // The heading says it; like system welcome panels, the title bar stays empty.
        window.title = tr("Welcome to Claudometer")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        // The close button and ⌘W count as Continue.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { finish(closeWindow: false) }
        }
        self.window = window
        SettingsWindow.bringForward(window)
    }

    /// Asked by Settings before it drops the Dock icon.
    static var isOpen: Bool { !finished && window?.isVisible == true }

    /// Opening the app again from Finder while the welcome waits: bring it back to the front.
    static func reopen() -> Bool {
        guard isOpen, let window else { return false }
        SettingsWindow.bringForward(window)
        return true
    }

    /// Continue, or the window closed any other way. Starts usage polling (and so any Keychain
    /// prompt). Quitting before either leaves the welcome for the next launch: the close that
    /// quitting causes is ignored (`willTerminate()`).
    static func finish() {
        finish(closeWindow: true)
    }

    /// From `applicationShouldTerminate`, before AppKit closes the windows.
    static func willTerminate() {
        isTerminating = true
    }

    private static func finish(closeWindow: Bool) {
        guard !isTerminating, !finished else { return }
        finished = true
        UserDefaults.standard.set(true, forKey: SettingsKey.welcomeShown)
        // Held back from `App.init`, so quitting at the welcome keeps the install fresh.
        LoginItem.enableOnFirstLaunch()
        if let window {
            if !SettingsWindow.isOpen { SettingsWindow.deactivate() }
            if closeWindow { window.close() }
            // Released after AppKit is done closing it.
            DispatchQueue.main.async { self.window = nil }
        }
        store?.start()
        store = nil
    }
}

/// The welcome's content, laid out like Settings: system window background, 13 pt text.
struct WelcomeView: View {
    static let width: CGFloat = 420
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text(tr("Welcome to Claudometer"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
            }
            // TZ FR-24's three points.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(Ink.secondary)
                        Text(md(point))
                            .foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("No Claude Code? Add a claude.ai session key in Settings › Accounts."))
                Text(tr("Claudometer opens at login so the widget stays up to date. You can turn this off in Settings › General."))
            }
            .font(.callout)
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Continue"), action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: Self.width, alignment: .leading)
    }

    private var points: [String] {
        [
            tr("Claudometer reads your Claude Code login to show your usage limits. The login is sent only to Anthropic."),
            // A no-break space keeps the button name on one line.
            tr("macOS may ask for Keychain access. If it does, choose “Always Allow” so it doesn’t ask again."),
            tr("Not signed in to Claude Code? Run `claude` in Terminal, then `/login`."),
        ]
    }
}
