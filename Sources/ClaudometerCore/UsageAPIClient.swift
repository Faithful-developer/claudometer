import Foundation

public struct UsageAPIClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession = .shared, version: String = "0.1") {
        self.session = session
        self.userAgent = "Claudometer/\(version)"
    }

    public func fetchUsage(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw AppError.unknown("Invalid response") }

        switch http.statusCode {
        case 200:
            return try UsageDecoder.decode(data)
        case 401, 403:
            throw AppError.tokenExpired
        case 404:
            throw AppError.apiChanged
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AppError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw AppError.server(status: http.statusCode)
        default:
            throw AppError.unknown("Unexpected HTTP \(http.statusCode)")
        }
    }

    static func map(_ error: URLError) -> AppError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
            return .offline
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
