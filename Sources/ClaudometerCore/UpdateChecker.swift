import CryptoKit
import Foundation

/// A newer version published on GitHub Releases.
public struct AppRelease: Codable, Hashable, Sendable {
    public let version: String
    public let pageURL: URL
    /// The release's DMG, for installing from inside the app; nil when the release has none
    /// or GitHub gave no checksum for it.
    public let download: Download?

    public struct Download: Codable, Hashable, Sendable {
        public let url: URL
        /// Lowercase hex SHA-256 that GitHub reports for the asset.
        public let sha256: String

        public init(url: URL, sha256: String) {
            self.url = url
            self.sha256 = sha256
        }
    }

    public init(version: String, pageURL: URL, download: Download? = nil) {
        self.version = version
        self.pageURL = pageURL
        self.download = download
    }
}

/// Looks for a newer release on GitHub. Sends no data about the user; a plain unauthenticated
/// request to the public releases API.
public struct UpdateChecker: Sendable {
    public static let repository = "Faithful-developer/claudometer"
    public static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The latest release if it is newer than `currentVersion`, otherwise nil.
    public func check(currentVersion: String) async throws -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        // 404 = nothing published yet.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.newer(than: currentVersion, in: data)
    }

    static func newer(than current: String, in data: Data) -> AppRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              root["draft"] as? Bool != true, root["prerelease"] as? Bool != true else { return nil }
        let page = (root["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: current) else { return nil }
        return AppRelease(version: version, pageURL: page, download: dmg(in: root["assets"]))
    }

    /// The `.dmg` asset with its checksum (`"digest": "sha256:…"`). Without a checksum the
    /// download can't be verified, so the update is offered as a page link only.
    static func dmg(in assets: Any?) -> AppRelease.Download? {
        for asset in assets as? [[String: Any]] ?? [] {
            guard let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)), url.scheme == "https",
                  let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { continue }
            let hex = String(digest.dropFirst("sha256:".count)).lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { continue }
            return AppRelease.Download(url: url, sha256: hex)
        }
        return nil
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Numeric comparison of dotted versions: 0.10.0 > 0.9.2, 1.0 == 1.0.0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
