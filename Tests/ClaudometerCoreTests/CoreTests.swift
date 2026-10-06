import Foundation
import Testing
@testable import ClaudometerCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func json(_ string: String) -> Data { Data(string.utf8) }

@Suite struct DecoderTests {
    @Test func decodesRealSample() throws {
        let snapshot = try UsageDecoder.decode(fixture("sample-usage"))
        #expect(snapshot.windows.map(\.id) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(snapshot.session?.utilization == 12)
        #expect(snapshot.weekly?.utilization == 17)
        #expect(snapshot.windows[2].title == "Weekly · Fable")
        #expect(snapshot.session?.resetsAt != nil)
        #expect(snapshot.breakdown.map(\.key) == ["claude_code", "chat", "cowork", "other"])
        #expect(snapshot.highest?.id == "weekly_scoped:Fable")
    }

    @Test func fallsBackToLegacyKeys() throws {
        let snapshot = try UsageDecoder.decode(json("""
        {"five_hour":{"utilization":42.0,"resets_at":"2026-10-06T18:00:00Z"},
         "seven_day":{"utilization":17,"resets_at":null},
         "seven_day_opus":null,"something_new":{"x":1}}
        """))
        #expect(snapshot.windows.map(\.id) == ["session", "weekly_all"])
        #expect(snapshot.session?.utilization == 42)
        #expect(snapshot.weekly?.resetsAt == nil)
    }

    @Test func unknownLimitKindIsKept() throws {
        let snapshot = try UsageDecoder.decode(json("""
        {"limits":[{"kind":"monthly_tokens","group":"monthly","percent":3,"resets_at":null}]}
        """))
        #expect(snapshot.windows.first?.title == "Monthly Tokens")
        #expect(snapshot.windows.first?.group == .other)
    }

    @Test func emptyResponseIsApiChanged() {
        #expect(throws: AppError.apiChanged) { try UsageDecoder.decode(json("{}")) }
        #expect(throws: AppError.apiChanged) { try UsageDecoder.decode(json("not json")) }
    }

    @Test func parsesMicrosecondDates() throws {
        let date = try #require(UsageDecoder.parseISO8601("2026-10-06T12:19:59.654439+00:00"))
        let base = try #require(UsageDecoder.parseISO8601("2026-10-06T12:19:59Z"))
        #expect(abs(date.timeIntervalSince(base) - 0.654439) < 0.001)
        #expect(UsageDecoder.parseISO8601("2026-11-05T07:59:00+00:00") != nil)
        #expect(UsageDecoder.parseISO8601("garbage") == nil)
    }
}

@Suite struct CredentialsTests {
    @Test func parsesKeychainBlob() throws {
        let creds = try CredentialsProvider.parse(json("""
        {"claudeAiOauth":{"accessToken":"abc","refreshToken":"r","expiresAt":4102444800000,"subscriptionType":"max"}}
        """))
        #expect(creds.accessToken == "abc")
        #expect(creds.plan == "max")
        #expect(!creds.isExpired)
    }

    @Test func missingTokenIsNotSignedIn() {
        #expect(throws: AppError.notSignedIn) { try CredentialsProvider.parse(json("{}")) }
    }

    @Test func expiredToken() throws {
        let creds = try CredentialsProvider.parse(json("""
        {"claudeAiOauth":{"accessToken":"abc","expiresAt":1000}}
        """))
        #expect(creds.isExpired)
    }
}

@Suite struct FormatterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func durations() {
        #expect(Formatters.duration(30) == "1m")
        #expect(Formatters.duration(0) == "<1m")
        #expect(Formatters.duration(2 * 3600 + 14 * 60) == "2h 14m")
        #expect(Formatters.duration(3 * 3600) == "3h")
        #expect(Formatters.duration(3 * 86400 + 4 * 3600) == "3d 4h")
    }

    @Test func resetText() {
        #expect(Formatters.resetText(nil, now: now) == "Not started")
        #expect(Formatters.resetText(now.addingTimeInterval(-5), now: now) == "Resetting…")
        #expect(Formatters.resetText(now.addingTimeInterval(8040), now: now) == "Resets in 2h 14m")
        let far = Formatters.resetText(now.addingTimeInterval(3 * 86400), now: now, locale: Locale(identifier: "en_US_POSIX"))
        #expect(far.hasPrefix("Resets ") && !far.hasPrefix("Resets in"))
        #expect(Formatters.shortReset(now.addingTimeInterval(600), now: now) == "in 10m")
    }

    @Test func percentClamps() {
        #expect(Formatters.percent(42.4) == "42%")
        #expect(Formatters.percent(130) == "100%+")
        #expect(Formatters.percent(100) == "100%")
        #expect(Formatters.percent(-3) == "0%")
    }

    @Test func levels() {
        #expect(UsageLevel.of(10) == .ok)
        #expect(UsageLevel.of(60) == .warning)
        #expect(UsageLevel.of(90) == .critical)
        #expect(UsageLevel.of(nil) == .unknown)
    }
}

@Suite struct BackoffTests {
    @Test func normalInterval() {
        #expect(Backoff.nextDelay(interval: 300, failures: 0) == 300)
    }

    @Test func exponential() {
        let delays = (1...7).map { Backoff.nextDelay(interval: 300, failures: $0, error: .offline) }
        #expect(delays == [60, 120, 240, 480, 900, 900, 900])
    }

    @Test func honoursRetryAfter() {
        #expect(Backoff.nextDelay(interval: 300, failures: 1, error: .rateLimited(retryAfter: 600)) == 600)
    }

    @Test func refreshesRightAfterReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Backoff.untilNextReset(300, resets: [now.addingTimeInterval(60)], now: now) == 75)
        #expect(Backoff.untilNextReset(300, resets: [now.addingTimeInterval(3600)], now: now) == 300)
        #expect(Backoff.untilNextReset(300, resets: [now.addingTimeInterval(-10)], now: now) == 300)
    }

    @Test func permanentErrorsKeepInterval() {
        #expect(Backoff.nextDelay(interval: 300, failures: 4, error: .notSignedIn) == 300)
    }
}

@Suite struct ThresholdTests {
    let reset = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ value: Double, resetsAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(windows: [LimitWindow(id: "session", group: .session, title: "Session", utilization: value, resetsAt: resetsAt ?? reset)])
    }

    @Test func firesOncePerCycle() {
        var tracker = ThresholdTracker()
        #expect(tracker.evaluate(snapshot(50), thresholds: [80, 95], notifyReset: true).isEmpty)
        #expect(tracker.evaluate(snapshot(81), thresholds: [80, 95], notifyReset: true).count == 1)
        #expect(tracker.evaluate(snapshot(85), thresholds: [80, 95], notifyReset: true).isEmpty)
        let high = tracker.evaluate(snapshot(96), thresholds: [80, 95], notifyReset: true)
        #expect(high == [.crossed(window: snapshot(96).windows[0], threshold: 95)])
    }

    @Test func jumpSkipsLowerThreshold() {
        var tracker = ThresholdTracker()
        let events = tracker.evaluate(snapshot(97), thresholds: [80, 95], notifyReset: false)
        #expect(events.count == 1)
        #expect(tracker.evaluate(snapshot(97), thresholds: [80, 95], notifyReset: false).isEmpty)
    }

    @Test func newCycleFiresAgainAndReportsReset() {
        var tracker = ThresholdTracker()
        _ = tracker.evaluate(snapshot(96), thresholds: [80, 95], notifyReset: true)
        let next = reset.addingTimeInterval(5 * 3600)
        let afterReset = tracker.evaluate(snapshot(2, resetsAt: next), thresholds: [80, 95], notifyReset: true)
        #expect(afterReset.count == 1)
        if case .reset = afterReset.first {} else { Issue.record("expected reset event") }
        #expect(tracker.evaluate(snapshot(81, resetsAt: next), thresholds: [80, 95], notifyReset: true).count == 1)
    }
}

@Suite struct StoreTests {
    @Test func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        let store = SnapshotStore(fileURL: url)
        let state = UsageState(snapshot: try UsageDecoder.decode(fixture("sample-usage")).withPlan("max"), error: .offline)
        try store.save(state)
        let loaded = try #require(store.load())
        #expect(loaded.snapshot?.windows.count == 3)
        #expect(loaded.snapshot?.plan == "max")
        #expect(loaded.error == .offline)
        #expect(loaded.isStale)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@Suite struct FallbackTests {
    @Test func normalizesPastedKeys() {
        #expect(SessionKeyStore.normalize("  sk-ant-sid01-abc\n") == "sk-ant-sid01-abc")
        #expect(SessionKeyStore.normalize("sessionKey=sk-ant-sid01-abc") == "sk-ant-sid01-abc")
        #expect(SessionKeyStore.normalize("Cookie: foo=1; sessionKey=sk-ant-sid01-abc; bar=2") == "sk-ant-sid01-abc")
        #expect(SessionKeyStore.normalize("\"sk-ant-sid01-abc\"") == "sk-ant-sid01-abc")
    }

    @Test func picksChatOrganizationAndPlan() {
        let orgs: [[String: Any]] = [
            ["uuid": "api", "capabilities": ["api"]],
            ["uuid": "chat", "capabilities": ["chat", "claude_max"]],
        ]
        let org = ClaudeWebClient.pickOrganization(orgs)
        #expect(org?["uuid"] as? String == "chat")
        #expect(ClaudeWebClient.plan(from: org ?? [:]) == "max")
        #expect(ClaudeWebClient.plan(from: ["capabilities": ["chat", "claude_pro"]]) == "pro")
    }

    @Test func detectsBotCheck() throws {
        let url = URL(string: "https://claude.ai/api/organizations")!
        let html = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=UTF-8"]))
        let json = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        #expect(ClaudeWebClient.isBotCheck(html))
        #expect(!ClaudeWebClient.isBotCheck(json))
    }

    @Test func onlyLoginErrorsFallBack() {
        #expect(AppError.tokenExpired.allowsWebFallback)
        #expect(AppError.notSignedIn.allowsWebFallback)
        #expect(!AppError.offline.allowsWebFallback)
        #expect(!AppError.rateLimited(retryAfter: nil).allowsWebFallback)
    }

    @Test func expiredTokenRetriesWithinAMinute() {
        #expect(Backoff.nextDelay(interval: 300, failures: 4, error: .tokenExpired) == 60)
        #expect(Backoff.nextDelay(interval: 300, failures: 4, error: .sessionKeyInvalid) == 300)
    }

    @Test func projectsPassedResetsToZero() {
        let now = Date()
        let snapshot = UsageSnapshot(windows: [
            LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 80, resetsAt: now.addingTimeInterval(-60)),
            LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 50, resetsAt: now.addingTimeInterval(-3600)),
            LimitWindow(id: "weekly_scoped:Opus", group: .weekly, title: "Weekly · Opus", utilization: 30, resetsAt: now.addingTimeInterval(3600)),
        ], source: .claudeWeb)
        let projected = snapshot.projected(at: now)
        #expect(projected.windows.map(\.utilization) == [0, 0, 30])
        #expect(projected.windows[0].resetsAt == nil)
        #expect(projected.windows[1].resetsAt == now.addingTimeInterval(-3600 + 7 * 86400))
        #expect(projected.source == .claudeWeb)
        #expect(snapshot.projected(at: now.addingTimeInterval(-7200)) == snapshot)
    }
}

@Suite struct UpdateTests {
    @Test func comparesVersions() {
        #expect(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.2"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func readsLatestRelease() {
        let body = json(#"{"tag_name":"v0.2.0","html_url":"https://github.com/x/y/releases/tag/v0.2.0","draft":false,"prerelease":false}"#)
        #expect(UpdateChecker.newer(than: "0.1.0", in: body)?.version == "0.2.0")
        #expect(UpdateChecker.newer(than: "0.2.0", in: body) == nil)
        let pre = json(#"{"tag_name":"v0.3.0","prerelease":true}"#)
        #expect(UpdateChecker.newer(than: "0.1.0", in: pre) == nil)
    }
}
