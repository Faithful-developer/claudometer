import Foundation

/// Fallback usage source: the claude.ai web API with the user's own session key (TZ §2.3).
///
/// `GET /api/organizations` gives the organization, then `GET /api/organizations/{uuid}/usage`
/// returns the same shape as the OAuth endpoint, so `UsageDecoder` handles it. The key is sent
/// only to claude.ai and never logged.
public actor ClaudeWebClient {
    public static let base = URL(string: "https://claude.ai/api/")!

    private let session: URLSession
    /// Organizations of each key used, so each poll is one request instead of two.
    private var cachedOrgs: [String: [WebOrganization]] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Usage of `orgUUID`, or of the personal chat organization when it's nil (the Claude
    /// Code account's backup key).
    /// `cache` false for a key that's only being checked, so a rejected key isn't kept.
    public func fetchUsage(sessionKey: String, orgUUID: String? = nil, cache: Bool = true) async throws -> UsageSnapshot {
        defer { if !cache { cachedOrgs[sessionKey] = nil } }
        let org = try await organization(sessionKey: sessionKey, uuid: orgUUID)
        do {
            let data = try await get("organizations/\(org.uuid)/usage", sessionKey: sessionKey)
            return try UsageDecoder.decode(data).withPlan(org.plan).withSource(.claudeWeb)
        } catch AppError.apiChanged {
            // The organization may have changed (e.g. switched account); look it up again next time.
            cachedOrgs[sessionKey] = nil
            throw AppError.apiChanged
        }
    }

    /// The organizations with usage limits that `sessionKey` can read, personal first.
    public func organizations(sessionKey: String, cache: Bool = true) async throws -> [WebOrganization] {
        defer { if !cache { cachedOrgs[sessionKey] = nil } }
        if let cached = cachedOrgs[sessionKey] { return cached }
        let data = try await get("organizations", sessionKey: sessionKey)
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AppError.apiChanged
        }
        let found = Self.chatOrganizations(orgs)
        guard !found.isEmpty else { throw AppError.apiChanged }
        cachedOrgs[sessionKey] = found
        return found
    }

    private func organization(sessionKey: String, uuid: String?) async throws -> WebOrganization {
        guard let uuid else {
            guard let first = try await organizations(sessionKey: sessionKey).first else { throw AppError.apiChanged }
            return first
        }
        if let org = try await organizations(sessionKey: sessionKey).first(where: { $0.uuid == uuid }) { return org }
        // Joined or left since the list was cached: look once more before giving up.
        cachedOrgs[sessionKey] = nil
        if let org = try await organizations(sessionKey: sessionKey).first(where: { $0.uuid == uuid }) { return org }
        // The key now belongs to a login without this organization.
        throw AppError.sessionKeyInvalid
    }

    /// Organizations with chat, in the server's order (personal first); API-only ones have no
    /// usage limits. Every organization if none says so.
    static func chatOrganizations(_ orgs: [[String: Any]]) -> [WebOrganization] {
        let chat = orgs.filter { (($0["capabilities"] as? [String]) ?? []).contains("chat") }
        return (chat.isEmpty ? orgs : chat).compactMap { org in
            guard let uuid = org["uuid"] as? String, !uuid.isEmpty else { return nil }
            return WebOrganization(uuid: uuid, name: org["name"] as? String ?? "", plan: plan(from: org))
        }
    }

    static func plan(from org: [String: Any]) -> String? {
        let capabilities = (org["capabilities"] as? [String]) ?? []
        if capabilities.contains("claude_max") { return "max" }
        if capabilities.contains("claude_pro") { return "pro" }
        return nil
    }

    private func get(_ path: String, sessionKey: String) async throws -> Data {
        var request = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: 15)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UsageAPIClient.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw AppError.unknown("Invalid response") }

        switch http.statusCode {
        case 200:
            return data
        case 401:
            throw AppError.sessionKeyInvalid
        case 403:
            throw Self.isBotCheck(http) ? AppError.webBlocked : AppError.sessionKeyInvalid
        case 404:
            throw AppError.apiChanged
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AppError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw AppError.server(status: http.statusCode)
        default:
            throw AppError.unknown("Unexpected HTTP \(http.statusCode) from claude.ai")
        }
    }

    /// Cloudflare challenges come back as HTML (often with `cf-mitigated`), real auth
    /// failures as JSON.
    static func isBotCheck(_ response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        return type.contains("text/html")
    }
}

/// A claude.ai organization a session key can read.
public struct WebOrganization: Hashable, Identifiable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    public let plan: String?

    public init(uuid: String, name: String, plan: String?) {
        self.uuid = uuid
        self.name = name
        self.plan = plan
    }

    /// A starting name for the account: "Acme" stays, a personal "ann@example.com's
    /// Organization" becomes "ann@example.com".
    public var suggestedName: String {
        for suffix in ["'s Organization", "’s Organization"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
