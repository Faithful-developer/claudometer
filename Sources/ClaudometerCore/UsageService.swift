import Foundation

/// Credentials + API in one call. Re-reads the Keychain on every fetch so a token refreshed
/// by Claude Code is picked up automatically.
///
/// For the Claude Code account, Claude Code's login comes first. When it is missing or expired
/// (Claude Code only refreshes it while running) and a claude.ai session key is saved as its
/// backup, the claude.ai web API is used instead.
public struct UsageService: Sendable {
    private let credentials: CredentialsProvider
    private let client: UsageAPIClient
    private let web: ClaudeWebClient

    public init(
        credentials: CredentialsProvider = CredentialsProvider(),
        client: UsageAPIClient = UsageAPIClient(),
        web: ClaudeWebClient = ClaudeWebClient()
    ) {
        self.credentials = credentials
        self.client = client
        self.web = web
    }

    /// Usage of one account (TZ F-2). An added account reads claude.ai with its own key.
    public func fetch(account: Account) async throws -> UsageSnapshot {
        guard account.isPrimary else {
            let keys = SessionKeyStore(accountID: account.id)
            guard let key = keys.loadForPolling() else {
                throw keys.isPaused ? AppError.keychainDenied : AppError.sessionKeyInvalid
            }
            return try await web.fetchUsage(sessionKey: key, orgUUID: account.orgUUID)
        }
        let backup = SessionKeyStore()
        backup.migrateLegacyKey()
        var plan: String?
        do {
            let creds = try loadCredentials()
            plan = creds.plan
            if creds.isExpired { throw AppError.tokenExpired }
            return try await client.fetchUsage(token: creds.accessToken).withPlan(creds.plan).withSource(.claudeCode)
        } catch let error as AppError where error.allowsWebFallback {
            guard let key = backup.loadForPolling() else { throw error }
            let snapshot = try await web.fetchUsage(sessionKey: key, orgUUID: account.orgUUID)
            return snapshot.plan == nil ? snapshot.withPlan(plan) : snapshot
        }
    }

    /// Settings → "Save & Test": the organizations a key can read, before it is stored.
    public func organizations(sessionKey: String) async throws -> [WebOrganization] {
        try await web.organizations(sessionKey: sessionKey, cache: false)
    }

    /// Settings → "Save & Test": checks a key against one organization before it is stored.
    public func test(sessionKey: String, orgUUID: String?) async throws -> UsageSnapshot {
        try await web.fetchUsage(sessionKey: sessionKey, orgUUID: orgUUID, cache: false)
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
