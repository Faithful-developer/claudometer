import Foundation

/// Persists the latest `UsageState` as JSON so it survives restarts and can be read by the widget.
///
/// Never stores the access token.
public struct SnapshotStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Claudometer/` in the user's real home folder.
    ///
    /// Shared with the widget without an App Group (App Groups need a signing team): the
    /// sandboxed widget has a read-only sandbox exception for exactly this folder. Inside the
    /// sandbox `homeDirectoryForCurrentUser` points at the container, so resolve the real
    /// home from the password database.
    public static var sharedDirectory: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Claudometer", isDirectory: true)
    }

    public static func `default`(account: Account = .primary) -> SnapshotStore {
        SnapshotStore(fileURL: sharedDirectory.appendingPathComponent(account.fileName("usage-state")))
    }

    // MARK: Widget style (menu bar metric + thresholds), written by the app

    static var styleURL: URL { sharedDirectory.appendingPathComponent("widget-style.json") }

    public static func saveStyle(_ style: WidgetStyle) {
        try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(style) {
            try? data.write(to: styleURL, options: .atomic)
        }
    }

    public static func loadStyle() -> WidgetStyle? {
        guard let data = try? Data(contentsOf: styleURL) else { return nil }
        return try? JSONDecoder().decode(WidgetStyle.self, from: data)
    }

    public func load() -> UsageState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(UsageState.self, from: data)
    }

    /// Removes the file, for an account that was removed.
    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func save(_ state: UsageState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
