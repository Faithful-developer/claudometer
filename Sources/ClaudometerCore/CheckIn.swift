import Foundation

/// The daily check-in that counts active installs (TZ NFR-4). Always on, with no
/// switch in Settings (see `CheckInService` for the Terminal opt-out). Sends a random ID made on this Mac, the app version, the UI
/// language and the macOS version; nothing about the Claude account or its usage.
public struct CheckIn: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let language: String
    public let os: String

    public init(id: String, version: String, language: String, os: String) {
        self.id = id
        self.version = version
        self.language = language
        self.os = os
    }

    /// The counter service (`server/checkin`).
    public static let endpoint = URL(string: "https://claudometer-stats.claudometer.workers.dev/ping")!

    /// "26.0" or "14.6.1".
    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Once per UTC day, matching how the server counts days.
    public static func isDue(lastSent: Date?, now: Date = Date()) -> Bool {
        guard let lastSent else { return true }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return !utc.isDate(lastSent, inSameDayAs: now) && now > lastSent
    }

    public func send(to endpoint: URL = CheckIn.endpoint, session: URLSession = .shared) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(self)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
