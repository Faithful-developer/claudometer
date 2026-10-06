import Foundation

/// Credentials + API in one call. Re-reads the Keychain on every fetch so a token refreshed
/// by Claude Code is picked up automatically.
///
/// Claude Code's login comes first. When it is missing or expired (Claude Code only refreshes
/// it while running) and a claude.ai session key is saved, the claude.ai web API is used instead.
public struct UsageService: Sendable {
    private let credentials: CredentialsProvider
    private let client: UsageAPIClient
    private let sessionKeys: SessionKeyStore
    private let web: ClaudeWebClient

    public init(
        credentials: CredentialsProvider = CredentialsProvider(),
        client: UsageAPIClient = UsageAPIClient(),
        sessionKeys: SessionKeyStore = SessionKeyStore(),
        web: ClaudeWebClient = ClaudeWebClient()
    ) {
        self.credentials = credentials
        self.client = client
        self.sessionKeys = sessionKeys
        self.web = web
    }

    public func fetch() async throws -> UsageSnapshot {
        var plan: String?
        do {
            let creds = try loadCredentials()
            plan = creds.plan
            if creds.isExpired { throw AppError.tokenExpired }
            return try await client.fetchUsage(token: creds.accessToken).withPlan(creds.plan).withSource(.claudeCode)
        } catch let error as AppError where error.allowsWebFallback {
            guard let key = sessionKeys.load() else { throw error }
            let snapshot = try await web.fetchUsage(sessionKey: key)
            return snapshot.plan == nil ? snapshot.withPlan(plan) : snapshot
        }
    }

    /// Settings → "Save & Test": checks a key before it is stored.
    public func test(sessionKey: String) async throws -> UsageSnapshot {
        try await web.fetchUsage(sessionKey: sessionKey)
    }

    private func loadCredentials() throws -> Credentials {
        do {
            return try credentials.load()
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.keychainDenied
        }
    }
}

extension AppError {
    /// Claude Code login problems that the claude.ai session key can stand in for.
    var allowsWebFallback: Bool {
        switch self {
        case .tokenExpired, .notSignedIn, .keychainDenied: return true
        default: return false
        }
    }
}
