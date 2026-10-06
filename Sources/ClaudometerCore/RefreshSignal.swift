import CoreFoundation
import Foundation

/// Lets the sandboxed widget ask the running app to fetch now.
///
/// The widget can't read the Keychain or call the API itself (FR-11), so its refresh button
/// posts a Darwin notification and the app does the fetch, then reloads the widget timelines.
/// Darwin notifications carry no payload, so nothing sensitive crosses the process boundary.
public enum RefreshSignal {
    public static let name = "dev.claudometer.refresh-request"

    /// Called from the widget's refresh intent.
    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Calls `handler` on the main queue each time the widget posts. Keep the returned token
    /// alive for as long as the observation should last.
    public static func observe(_ handler: @escaping @Sendable () -> Void) -> Observation {
        Observation(handler: handler)
    }

    public final class Observation: @unchecked Sendable {
        private let handler: @Sendable () -> Void

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let me = Unmanaged<Observation>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async { me.handler() }
                },
                RefreshSignal.name as CFString,
                nil,
                .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }
}
