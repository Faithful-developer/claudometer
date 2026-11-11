import Foundation

/// Credentials + API in one call. Re-reads the Keychain on every fetch so a token refreshed
/// by Claude Code is picked up automatically.
///
/// For the Claude Code account, Claude Code's login comes first. When it is missing or expired
/// (Claude Code only refreshes it while running) and a claude.ai session key is saved as its
/// backup, the claude.ai web API is used instead. It also covers a rate limit (HTTP 429) on
/// the Claude Code route, which has its own budget separate from claude.ai's: after a 429 that
/// route rests until its wait is over (`RouteCooldown`) and isn't asked on every poll.
public struct UsageService: Sendable {
    private let loadCredentials: @Sendable () throws -> Credentials
    private let backupKey: @Sendable () -> String?
    private let client: UsageAPIClient
    private let web: ClaudeWebClient
    private let cooldown: RouteCooldown
    private let now: @Sendable () -> Date

    public init(
        credentials: CredentialsProvider = CredentialsProvider(),
        client: UsageAPIClient = UsageAPIClient(),
        web: ClaudeWebClient = ClaudeWebClient()
    ) {
        self.init(
            loadCredentials: {
                do {
                    return try credentials.load()
                } catch let error as AppError {
                    throw error
                } catch {
                    throw AppError.keychainDenied
                }
            },
            backupKey: {
                let backup = SessionKeyStore()
                backup.migrateLegacyKey()
                return backup.loadForPolling()
            },
            client: client,
            web: web
        )
    }

    /// Tests replace the Keychain and the clock.
    init(
        loadCredentials: @escaping @Sendable () throws -> Credentials,
        backupKey: @escaping @Sendable () -> String?,
        client: UsageAPIClient,
        web: ClaudeWebClient,
        cooldown: RouteCooldown = RouteCooldown(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadCredentials = loadCredentials
        self.backupKey = backupKey
        self.client = client
        self.web = web
        self.cooldown = cooldown
        self.now = now
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
        var plan: String?
        let primaryError: AppError
        do {
            let creds = try loadCredentials()
            plan = creds.plan
            return try await fetchClaudeCode(creds)
        } catch let error as AppError where error.allowsWebFallback {
            primaryError = error
        }
        guard let key = backupKey() else { throw primaryError }
        do {
            let snapshot = try await web.fetchUsage(sessionKey: key, orgUUID: account.orgUUID)
            return snapshot.plan == nil ? snapshot.withPlan(plan) : snapshot
        } catch let webError as AppError {
            throw Self.reported(primary: primaryError, backup: webError)
        }
    }

    /// The Claude Code route, unless it is resting after a 429.
    private func fetchClaudeCode(_ creds: Credentials) async throws -> UsageSnapshot {
        if creds.isExpired { throw AppError.tokenExpired }
        if let wait = cooldown.remaining(now: now()) { throw AppError.rateLimited(retryAfter: wait) }
        do {
            let snapshot = try await client.fetchUsage(token: creds.accessToken)
            cooldown.clear()
            return snapshot.withPlan(creds.plan).withSource(.claudeCode)
        } catch AppError.rateLimited(let retryAfter) {
            cooldown.block(retryAfter: retryAfter, now: now())
            throw AppError.rateLimited(retryAfter: cooldown.remaining(now: now()))
        }
    }

    /// Which error to show when both routes failed. While Claude Code is only rate limited, a
    /// backup that needs fixing (expired key) is the actionable one; otherwise the 429 and its
    /// wait. A login problem shows the backup's error, as the backup was the only way.
    static func reported(primary: AppError, backup: AppError) -> AppError {
        guard case .rateLimited(let primaryWait) = primary else { return backup }
        if backup.needsUserAction { return backup }
        if case .rateLimited(let backupWait) = backup {
            let waits = [primaryWait, backupWait].compactMap { $0 }
            return .rateLimited(retryAfter: waits.min())
        }
        return primary
    }

    /// Settings → "Save & Test": the organizations a key can read, before it is stored.
    public func organizations(sessionKey: String) async throws -> [WebOrganization] {
        try await web.organizations(sessionKey: sessionKey, cache: false)
    }

    /// Settings → "Save & Test": checks a key against one organization before it is stored.
    public func test(sessionKey: String, orgUUID: String?) async throws -> UsageSnapshot {
        try await web.fetchUsage(sessionKey: sessionKey, orgUUID: orgUUID, cache: false)
    }
}

extension AppError {
    /// Claude Code login problems, or a rate limit on its endpoint, that the claude.ai session key can stand in for.
    var allowsWebFallback: Bool {
        switch self {
        case .tokenExpired, .notSignedIn, .keychainDenied, .rateLimited: return true
        default: return false
        }
    }
}
