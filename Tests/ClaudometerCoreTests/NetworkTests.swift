import Foundation
import os
import Testing
@testable import ClaudometerCore

// MARK: - Stubbed network

/// Answers every request of a stubbed `URLSession` from a handler, and records the URLs asked.
/// One handler at a time, so the suites using it are serialized.
final class StubURLProtocol: URLProtocol {
    enum Reply {
        case http(Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError.Code)
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private struct State {
        var handler: Handler?
        var requests: [URL] = []
    }

    private static let state = OSAllocatedUnfairLock(uncheckedState: State())

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0 = State(handler: handler) }
    }

    static var requests: [URL] { state.withLock { $0.requests } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let handler = Self.state.withLock { state -> Handler? in
            state.requests.append(url)
            return state.handler
        }
        switch handler?(request) ?? .failure(.unknown) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}

private func usageJSON() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "sample-usage", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let orgsJSON = Data(#"[{"uuid":"org-1","name":"Me","capabilities":["chat","claude_max"]}]"#.utf8)

private func isClaudeCode(_ request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }

/// A clock tests can move.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

private func service(
    credentials: Credentials? = Credentials(accessToken: "token", expiresAt: nil, plan: "max"),
    backupKey: String? = "sk-ant-sid-test",
    cooldown: RouteCooldown = RouteCooldown(),
    clock: Clock = Clock()
) -> UsageService {
    let session = StubURLProtocol.session
    return UsageService(
        loadCredentials: {
            guard let credentials else { throw AppError.notSignedIn }
            return credentials
        },
        backupKey: { backupKey },
        client: UsageAPIClient(session: session, version: "test"),
        web: ClaudeWebClient(session: session),
        cooldown: cooldown,
        now: { clock.now }
    )
}

// MARK: - Tests

@Suite(.serialized) struct NetworkTests {
    // MARK: HTTP status mapping

    @Test(arguments: [
        (200, AppError?.none),
        (401, .tokenExpired),
        (403, .tokenExpired),
        (404, .apiChanged),
        (503, .server(status: 503)),
    ])
    func claudeCodeStatus(status: Int, expected: AppError?) async throws {
        let body = try usageJSON()
        StubURLProtocol.install { _ in .http(status, body: status == 200 ? body : Data()) }
        let client = UsageAPIClient(session: StubURLProtocol.session, version: "test")
        do {
            _ = try await client.fetchUsage(token: "t")
            #expect(expected == nil)
        } catch let error as AppError {
            #expect(error == expected)
        }
    }

    @Test func claudeCodeRateLimit() async throws {
        let client = UsageAPIClient(session: StubURLProtocol.session, version: "test")
        StubURLProtocol.install { _ in .http(429, headers: ["Retry-After": "120"]) }
        await #expect(throws: AppError.rateLimited(retryAfter: 120)) { try await client.fetchUsage(token: "t") }
        StubURLProtocol.install { _ in .http(429) }
        await #expect(throws: AppError.rateLimited(retryAfter: nil)) { try await client.fetchUsage(token: "t") }
    }

    @Test func claudeCodeOfflineAndUserAgent() async throws {
        StubURLProtocol.install { _ in .failure(.notConnectedToInternet) }
        let client = UsageAPIClient(session: StubURLProtocol.session, version: "9.8.7")
        await #expect(throws: AppError.offline) { try await client.fetchUsage(token: "t") }

        let body = try usageJSON()
        StubURLProtocol.install { request in
            request.value(forHTTPHeaderField: "User-Agent") == "Claudometer/9.8.7" ? .http(200, body: body) : .http(400)
        }
        _ = try await client.fetchUsage(token: "t")
    }

    @Test(arguments: [
        (401, "application/json", AppError.sessionKeyInvalid),
        (403, "application/json", .sessionKeyInvalid),
        (403, "text/html; charset=UTF-8", .webBlocked),
        (404, "application/json", .apiChanged),
        (429, "application/json", .rateLimited(retryAfter: nil)),
    ])
    func claudeWebStatus(status: Int, contentType: String, expected: AppError) async {
        StubURLProtocol.install { _ in .http(status, headers: ["Content-Type": contentType]) }
        let web = ClaudeWebClient(session: StubURLProtocol.session)
        await #expect(throws: expected) { try await web.organizations(sessionKey: "k", cache: false) }
    }

    // MARK: Fallback and cooldown (TZ FR-16)

    /// Claude Code answers 429; claude.ai answers normally.
    private func installRateLimitedClaudeCode(webStatus: Int = 200) throws {
        let usage = try usageJSON()
        StubURLProtocol.install { request in
            if isClaudeCode(request) { return .http(429, headers: ["Retry-After": "600"]) }
            guard webStatus == 200 else { return .http(webStatus, headers: ["Content-Type": "application/json"]) }
            return request.url!.path.hasSuffix("/usage") ? .http(200, body: usage) : .http(200, body: orgsJSON)
        }
    }

    @Test func rateLimitFallsBackToClaudeWeb() async throws {
        try installRateLimitedClaudeCode()
        let snapshot = try await service().fetch(account: .primary)
        #expect(snapshot.source == .claudeWeb)
        #expect(snapshot.plan == "max")
    }

    @Test func cooldownSkipsClaudeCodeUntilItEnds() async throws {
        try installRateLimitedClaudeCode()
        let clock = Clock()
        let usage = service(clock: clock)
        _ = try await usage.fetch(account: .primary)
        #expect(StubURLProtocol.requests.filter { $0.host == "api.anthropic.com" }.count == 1)

        // The next poll, inside the 600 s wait, goes straight to claude.ai.
        clock.advance(300)
        let second = try await usage.fetch(account: .primary)
        #expect(second.source == .claudeWeb)
        #expect(StubURLProtocol.requests.filter { $0.host == "api.anthropic.com" }.count == 1)

        // Once the wait is over, Claude Code is asked again; a good answer ends the cooldown.
        let body = try usageJSON()
        StubURLProtocol.install { request in isClaudeCode(request) ? .http(200, body: body) : .http(500) }
        clock.advance(301)
        let third = try await usage.fetch(account: .primary)
        #expect(third.source == .claudeCode)
    }

    @Test func expiredBackupKeyShowsDuringRateLimit() async throws {
        try installRateLimitedClaudeCode(webStatus: 401)
        await #expect(throws: AppError.sessionKeyInvalid) { try await service().fetch(account: .primary) }
    }

    @Test func offlineBackupKeepsTheRateLimitAndItsWait() async throws {
        StubURLProtocol.install { request in
            isClaudeCode(request) ? .http(429, headers: ["Retry-After": "600"]) : .failure(.notConnectedToInternet)
        }
        let clock = Clock()
        let usage = service(clock: clock)
        await #expect(throws: AppError.rateLimited(retryAfter: 600)) { try await usage.fetch(account: .primary) }
        clock.advance(100)
        await #expect(throws: AppError.rateLimited(retryAfter: 500)) { try await usage.fetch(account: .primary) }
    }

    @Test func rateLimitWithoutBackupKeyKeepsTheWait() async throws {
        try installRateLimitedClaudeCode()
        await #expect(throws: AppError.rateLimited(retryAfter: 600)) {
            try await service(backupKey: nil).fetch(account: .primary)
        }
    }

    @Test func expiredLoginUsesClaudeWeb() async throws {
        try installRateLimitedClaudeCode()
        let expired = Credentials(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 0), plan: "pro")
        let snapshot = try await service(credentials: expired).fetch(account: .primary)
        #expect(snapshot.source == .claudeWeb)
        #expect(!StubURLProtocol.requests.contains { $0.host == "api.anthropic.com" })
    }
}

@Suite struct RateLimitTests {
    @Test func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RetryAfter.parse("120") == 120)
        #expect(RetryAfter.parse(" 45 ") == 45)
        #expect(RetryAfter.parse("86400") == RetryAfter.cap)
        #expect(RetryAfter.parse("-5") == 0)
        #expect(RetryAfter.parse("soon") == nil)
        #expect(RetryAfter.parse(nil) == nil)
        let httpDate = "Fri, 15 Jan 2027 08:02:00 GMT"   // 1_800_000_000 + 120 s
        #expect(RetryAfter.parse(httpDate, now: now) == 120)
        #expect(RetryAfter.parse(httpDate, now: now.addingTimeInterval(600)) == 0)
    }

    @Test func cooldownEscalatesWithoutRetryAfter() {
        let cooldown = RouteCooldown()
        let now = Date(timeIntervalSince1970: 0)
        #expect(cooldown.remaining(now: now) == nil)
        cooldown.block(retryAfter: nil, now: now)
        #expect(cooldown.remaining(now: now) == 300)
        cooldown.block(retryAfter: nil, now: now)
        #expect(cooldown.remaining(now: now) == 600)
        for _ in 0..<6 { cooldown.block(retryAfter: nil, now: now) }
        #expect(cooldown.remaining(now: now) == 3600)
        cooldown.clear()
        #expect(cooldown.remaining(now: now) == nil)
    }

    @Test func cooldownHonoursRetryAfterWithAFloor() {
        let cooldown = RouteCooldown()
        let now = Date(timeIntervalSince1970: 0)
        cooldown.block(retryAfter: 900, now: now)
        #expect(cooldown.remaining(now: now) == 900)
        cooldown.block(retryAfter: 5, now: now)
        #expect(cooldown.remaining(now: now) == 60)
        #expect(cooldown.remaining(now: now.addingTimeInterval(61)) == nil)
    }

    @Test func reportedErrorWhenBothRoutesFail() {
        let limited = AppError.rateLimited(retryAfter: 600)
        #expect(UsageService.reported(primary: limited, backup: .sessionKeyInvalid) == .sessionKeyInvalid)
        #expect(UsageService.reported(primary: limited, backup: .offline) == limited)
        #expect(UsageService.reported(primary: limited, backup: .rateLimited(retryAfter: 120)) == .rateLimited(retryAfter: 120))
        #expect(UsageService.reported(primary: limited, backup: .rateLimited(retryAfter: nil)) == limited)
        #expect(UsageService.reported(primary: .tokenExpired, backup: .offline) == .offline)
    }

    @Test func rateLimitDelayFollowsTheWait() {
        #expect(Backoff.nextDelay(interval: 300, failures: 5, error: .rateLimited(retryAfter: 120)) == 120)
        #expect(Backoff.nextDelay(interval: 300, failures: 1, error: .rateLimited(retryAfter: 5)) == 30)
    }
}
