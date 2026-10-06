import Foundation

/// Fallback usage source: the claude.ai web API with the user's own session key (TZ §2.3).
///
/// `GET /api/organizations` gives the organization, then `GET /api/organizations/{uuid}/usage`
/// returns the same shape as the OAuth endpoint, so `UsageDecoder` handles it. The key is sent
/// only to claude.ai and never logged.
public actor ClaudeWebClient {
    public static let base = URL(string: "https://claude.ai/api/")!

    private let session: URLSession
    /// Organization of the last key used, so each poll is one request instead of two.
    private var cachedOrg: (key: String, uuid: String, plan: String?)?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(sessionKey: String) async throws -> UsageSnapshot {
        let org = try await organization(sessionKey: sessionKey)
        do {
            let data = try await get("organizations/\(org.uuid)/usage", sessionKey: sessionKey)
            return try UsageDecoder.decode(data).withPlan(org.plan).withSource(.claudeWeb)
        } catch AppError.apiChanged {
            // The organization may have changed (e.g. switched account); look it up again next time.
            cachedOrg = nil
            throw AppError.apiChanged
        }
    }

    private func organization(sessionKey: String) async throws -> (uuid: String, plan: String?) {
        if let cachedOrg, cachedOrg.key == sessionKey { return (cachedOrg.uuid, cachedOrg.plan) }
        let data = try await get("organizations", sessionKey: sessionKey)
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let org = Self.pickOrganization(orgs),
              let uuid = org["uuid"] as? String else {
            throw AppError.apiChanged
        }
        let plan = Self.plan(from: org)
        cachedOrg = (sessionKey, uuid, plan)
        return (uuid, plan)
    }

    /// The personal chat organization if there are several (API-only orgs have no usage limits).
    static func pickOrganization(_ orgs: [[String: Any]]) -> [String: Any]? {
        orgs.first { (($0["capabilities"] as? [String]) ?? []).contains("chat") } ?? orgs.first
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
