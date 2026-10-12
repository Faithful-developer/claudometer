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

    /// The API computes `resets_at` per request; fractions of a second across a minute
    /// boundary used to read as a new cycle and repeat the alert.
    @Test func resetTimeJitterIsSameCycle() {
        var tracker = ThresholdTracker()
        let before = Date(timeIntervalSince1970: 1_799_999_999.6)  // hh:mm:59.6
        let after = Date(timeIntervalSince1970: 1_800_000_000.1)   // next minute
        #expect(tracker.evaluate(snapshot(81, resetsAt: before), thresholds: [80, 95], notifyReset: true).count == 1)
        #expect(tracker.evaluate(snapshot(81, resetsAt: after), thresholds: [80, 95], notifyReset: true).isEmpty)
        #expect(tracker.evaluate(snapshot(82, resetsAt: before), thresholds: [80, 95], notifyReset: true).isEmpty)
    }

    @Test func missingWindowDoesNotRefire() {
        var tracker = ThresholdTracker()
        let fable = LimitWindow(id: "weekly_scoped:Fable", group: .weekly, title: "Weekly · Fable", utilization: 85, resetsAt: reset)
        let session = snapshot(10).windows[0]
        #expect(tracker.evaluate(UsageSnapshot(windows: [session, fable]), thresholds: [80, 95], notifyReset: true).count == 1)
        #expect(tracker.evaluate(UsageSnapshot(windows: [session]), thresholds: [80, 95], notifyReset: true).isEmpty)
        #expect(tracker.evaluate(UsageSnapshot(windows: [session, fable]), thresholds: [80, 95], notifyReset: true).isEmpty)
    }

    /// "Has reset" means the limit rolled over, not that usage dipped.
    @Test func resetOnlyOnRollover() {
        var tracker = ThresholdTracker()
        _ = tracker.evaluate(snapshot(96), thresholds: [80, 95], notifyReset: true)
        #expect(tracker.evaluate(snapshot(70), thresholds: [80, 95], notifyReset: true).isEmpty)
        let next = reset.addingTimeInterval(5 * 3600)
        #expect(tracker.evaluate(snapshot(2, resetsAt: next), thresholds: [80, 95], notifyReset: true).count == 1)
        #expect(tracker.evaluate(snapshot(2, resetsAt: next), thresholds: [80, 95], notifyReset: true).isEmpty)
    }

    @Test func endedWindowCountsAsReset() {
        var tracker = ThresholdTracker()
        _ = tracker.evaluate(snapshot(96), thresholds: [80, 95], notifyReset: true)
        let ended = UsageSnapshot(windows: [LimitWindow(id: "session", group: .session, title: "Session", utilization: 0, resetsAt: nil)])
        let events = tracker.evaluate(ended, thresholds: [80, 95], notifyReset: true)
        #expect(events.count == 1)
        if case .reset = events.first {} else { Issue.record("expected reset event") }
    }

    @Test func codableRoundTrip() throws {
        var tracker = ThresholdTracker()
        _ = tracker.evaluate(snapshot(96), thresholds: [80, 95], notifyReset: true)
        var restored = try JSONDecoder().decode(ThresholdTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored.evaluate(snapshot(97), thresholds: [80, 95], notifyReset: true).isEmpty)
    }

    /// Keys written by older builds carry over, so updating does not repeat today's alerts.
    @Test func migratesLegacyKeys() {
        let minute = Int(reset.timeIntervalSince1970 / 60)
        var tracker = ThresholdTracker(legacyFired: ["session|\(minute)|80", "session|\(minute)|95"], nearLimit: ["session"])
        #expect(tracker.evaluate(snapshot(96), thresholds: [80, 95], notifyReset: true).isEmpty)
        let next = reset.addingTimeInterval(5 * 3600)
        #expect(tracker.evaluate(snapshot(1, resetsAt: next), thresholds: [80, 95], notifyReset: true).count == 1)
    }
}

@Suite struct ExtraRingTests {
    let snapshot = UsageSnapshot(windows: [
        LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 50, resetsAt: nil),
        LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 80, resetsAt: nil),
        LimitWindow(id: "weekly_scoped:Fable", group: .weekly, title: "Weekly · Fable", utilization: 60, resetsAt: nil),
    ])

    @Test func picksHighNonPrimaryWindows() {
        #expect(snapshot.highWindows(excluding: ["session"], from: 80).map(\.id) == ["weekly_all"])
        #expect(snapshot.highWindows(excluding: ["session"], from: 60).map(\.id) == ["weekly_all", "weekly_scoped:Fable"])
        // Limits already shown never repeat as an extra ring; highest comes first.
        #expect(snapshot.highWindows(excluding: ["weekly_all"], from: 50).map(\.id) == ["weekly_scoped:Fable", "session"])
        #expect(snapshot.highWindows(excluding: [], from: 0).count == 2)
    }

    /// Session is a digit so a weekly Sonnet limit ("S") can't be mistaken for it.
    @Test func badgeLetters() {
        let sonnet = LimitWindow(id: "weekly_scoped:Sonnet", group: .weekly, title: "Weekly · Sonnet", utilization: 0, resetsAt: nil)
        #expect((snapshot.windows + [sonnet]).map(\.badgeLetter) == ["5", "W", "F", "S"])
    }
}

@Suite struct PinnedRingTests {
    let snapshot = UsageSnapshot(windows: [
        LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: 50, resetsAt: nil),
        LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: 40, resetsAt: nil),
        LimitWindow(id: "weekly_scoped:Fable", group: .weekly, title: "Weekly · Fable", utilization: 90, resetsAt: nil),
        LimitWindow(id: "weekly_scoped:Opus", group: .weekly, title: "Weekly · Opus", utilization: 85, resetsAt: nil),
    ])

    private func ids(_ metric: MenuBarMetric, _ pinned: [String], _ threshold: Double? = 80) -> [String] {
        let rings = snapshot.menuBarWindows(metric: metric, pinned: pinned, extraThreshold: threshold)
        return [rings.primary?.id ?? "-"] + rings.extras.map(\.id)
    }

    @Test func withoutPinsMatchesHighRings() {
        #expect(ids(.session, []) == ["session", "weekly_scoped:Fable", "weekly_scoped:Opus"])
        #expect(ids(.session, [], nil) == ["session"])
    }

    @Test func pinnedComeFirstInSnapshotOrder() {
        #expect(ids(.session, ["weekly_scoped:Fable", "weekly_all"], nil) == ["session", "weekly_all", "weekly_scoped:Fable"])
    }

    /// A pinned limit isn't repeated as a high ring, and high rings only fill the two-ring cap.
    @Test func highRingsShareTheCap() {
        #expect(ids(.session, ["weekly_scoped:Fable"]) == ["session", "weekly_scoped:Fable", "weekly_scoped:Opus"])
        #expect(ids(.session, ["weekly_all", "weekly_scoped:Fable"]) == ["session", "weekly_all", "weekly_scoped:Fable"])
    }

    @Test func skipsPrimaryAndUnknownPins() {
        #expect(ids(.highest, ["weekly_scoped:Fable", "weekly_scoped:Gone"], nil) == ["weekly_scoped:Fable"])
        #expect(ids(.weekly, ["weekly_all", "session"], nil) == ["weekly_all", "session"])
    }

    /// Stored pins beyond the cap are ignored, and there's no room left for high rings.
    @Test func pinnedAreCapped() {
        #expect(ids(.session, ["weekly_scoped:Opus", "weekly_scoped:Fable", "weekly_all"]) == ["session", "weekly_all", "weekly_scoped:Fable"])
    }

    @Test func settingsTitles() {
        #expect(snapshot.windows.map(\.settingsTitle) == ["Session (5h)", "Weekly (all models)", "Weekly (Fable)", "Weekly (Opus)"])
    }

    @Test func pinsRoundTrip() {
        #expect(MenuBarPins.decode("") == [])
        let pins = ["weekly_all", "weekly_scoped:Fable"]
        #expect(MenuBarPins.decode(MenuBarPins.encode(pins)) == pins)
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
        // No assets: offered as a page link only.
        #expect(UpdateChecker.newer(than: "0.1.0", in: body)?.download == nil)
    }

    @Test func readsTheDMGWithItsChecksum() {
        let hex = String(repeating: "ab", count: 32)
        let body = json(#"""
        {"tag_name":"v0.3.0","html_url":"https://github.com/x/y/releases/tag/v0.3.0","assets":[
          {"name":"notes.txt","browser_download_url":"https://github.com/x/y/notes.txt","digest":"sha256:\#(hex)"},
          {"name":"Claudometer-0.3.0.dmg","browser_download_url":"https://github.com/x/y/releases/download/v0.3.0/Claudometer-0.3.0.dmg","digest":"sha256:\#(hex.uppercased())"}
        ]}
        """#)
        let download = UpdateChecker.newer(than: "0.2.0", in: body)?.download
        #expect(download?.url.lastPathComponent == "Claudometer-0.3.0.dmg")
        #expect(download?.sha256 == hex)
        // A DMG without a checksum can't be verified, so it isn't offered for installing.
        let unverified = json(#"{"tag_name":"v0.3.0","assets":[{"name":"Claudometer-0.3.0.dmg","browser_download_url":"https://github.com/x/y/a.dmg"}]}"#)
        #expect(UpdateChecker.newer(than: "0.2.0", in: unverified)?.download == nil)
    }

    @Test func hashesFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claudometer-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try UpdateChecker.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct OutageTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func userActionErrorsAlertRightAway() {
        var tracker = OutageTracker()
        #expect(tracker.record(error: .tokenExpired, now: start) == .stopped(.tokenExpired))
    }

    @Test func passingErrorsWaitForGrace() {
        var tracker = OutageTracker()
        #expect(tracker.record(error: .offline, now: start) == nil)
        #expect(tracker.record(error: .server(status: 503), now: start.addingTimeInterval(29 * 60)) == nil)
        #expect(tracker.record(error: .offline, now: start.addingTimeInterval(30 * 60)) == .stopped(.offline))
    }

    @Test func alertsOncePerOutage() {
        var tracker = OutageTracker()
        _ = tracker.record(error: .tokenExpired, now: start)
        #expect(tracker.record(error: .tokenExpired, now: start.addingTimeInterval(60)) == nil)
        #expect(tracker.record(error: .notSignedIn, now: start.addingTimeInterval(120)) == nil)
        #expect(tracker.record(error: nil, now: start.addingTimeInterval(180)) == .recovered)
        // A new outage alerts again.
        #expect(tracker.record(error: .tokenExpired, now: start.addingTimeInterval(240)) == .stopped(.tokenExpired))
    }

    @Test func recoversSilentlyWithoutAlert() {
        var tracker = OutageTracker()
        _ = tracker.record(error: .offline, now: start)
        #expect(tracker.record(error: nil, now: start.addingTimeInterval(60)) == nil)
        // The grace period starts over after a success.
        #expect(tracker.record(error: .offline, now: start.addingTimeInterval(31 * 60)) == nil)
    }

    @Test func survivesRelaunch() throws {
        var tracker = OutageTracker()
        _ = tracker.record(error: .tokenExpired, now: start)
        var restored = try JSONDecoder().decode(OutageTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored == tracker)
        #expect(restored.record(error: .tokenExpired, now: start.addingTimeInterval(60)) == nil)
    }

    @Test func recoveryButtons() {
        #expect(AppError.tokenExpired.recoveries(hasSessionKey: false) == [.tryAgain, .addSessionKey])
        #expect(AppError.tokenExpired.recoveries(hasSessionKey: true) == [.tryAgain])
        #expect(AppError.notSignedIn.recoveries(hasSessionKey: false) == [.tryAgain, .addSessionKey])
        #expect(AppError.sessionKeyInvalid.recoveries(hasSessionKey: true) == [.updateSessionKey])
        #expect(AppError.offline.recoveries(hasSessionKey: false) == [.tryAgain])
    }

    @Test func dataFromText() {
        let fetched = start
        let sameDay = Formatters.dataFromText(fetched, now: fetched.addingTimeInterval(60))
        let nextDay = Formatters.dataFromText(fetched, now: fetched.addingTimeInterval(2 * 86_400))
        let time = fetched.formatted(date: .omitted, time: .shortened)
        #expect(sameDay == "Showing data from \(time)")
        #expect(nextDay.hasPrefix("Showing data from "))
        #expect(nextDay != sameDay && nextDay.hasSuffix(time))
    }
}

/// Runs in Russian against the repo's strings files, then goes back to English (the keys).
@Suite struct LocalizationTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let root = repo.appendingPathComponent("Resources/Localization")

    private func inRussian(_ body: () throws -> Void) rethrows {
        try L10n.$scoped.withValue(L10n.make("ru", root: Self.root), operation: body)
    }

    @Test func russianPlurals() {
        inRussian {
            #expect(tr("Every %lld minutes", 2) == "Каждые 2\u{a0}минуты")
            #expect(tr("Every %lld minutes", 5) == "Каждые 5\u{a0}минут")
            #expect(tr("Every %lld minutes", 21) == "Каждую 21\u{a0}минуту")
            #expect(tr("%lld percent used", 1) == "использован 1 процент")
            #expect(tr("%lld percent used", 42) == "использовано 42 процента")
            #expect(tr("%lld percent used", 91) == "использован 91 процент")
            #expect(tr("%@ %lld percent", "Неделя Fable", 80) == "Неделя Fable: 80 процентов")
        }
    }

    @Test func russianFormatting() {
        inRussian {
            #expect(Formatters.duration(2 * 3600 + 14 * 60) == "2\u{a0}ч 14\u{a0}мин")
            #expect(Formatters.duration(3 * 86400 + 4 * 3600) == "3\u{a0}дн. 4\u{a0}ч")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(Formatters.resetText(now.addingTimeInterval(2 * 3600), now: now) == "Сброс через 2\u{a0}ч")
            #expect(Formatters.shortReset(now.addingTimeInterval(2 * 3600), now: now) == "через 2\u{a0}ч")
            #expect(Formatters.shortReset(now.addingTimeInterval(3 * 86400), now: now).hasPrefix("через") == false)
            let window = LimitWindow(id: "weekly_scoped:Fable", group: .weekly, title: "Weekly · Fable", utilization: 80, resetsAt: nil)
            #expect(window.title == "Неделя · Fable")
            #expect(window.shortTitle == "Fable")
            #expect(window.settingsTitle == "Неделя (Fable)")
            #expect(AppError.offline.message == "Нет подключения к интернету. Повтор будет выполнен автоматически.")
        }
    }

    @Test func englishIsTheKey() {
        #expect(Formatters.duration(2 * 3600 + 14 * 60) == "2h 14m")
        #expect(Formatters.shortReset(Date(timeIntervalSince1970: 7200), now: Date(timeIntervalSince1970: 0)) == "in 2h")
    }

    /// Every `tr("…")` key in the sources has a Russian translation.
    @Test func everyKeyIsTranslated() throws {
        let strings = try #require(NSDictionary(contentsOf: Self.root.appendingPathComponent("ru.lproj/Localizable.strings")) as? [String: String])
        let plurals = try #require(NSDictionary(contentsOf: Self.root.appendingPathComponent("ru.lproj/Localizable.stringsdict")) as? [String: Any])
        let known = Set(strings.keys).union(plurals.keys)
        // English-only keys: identical in Russian.
        let untranslated: Set = ["100%+", "%lld%%"]
        let pattern = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        for folder in ["Sources", "Widget"] {
            let files = FileManager.default.enumerator(at: Self.repo.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let key = String(text[Range(match.range(at: 1), in: text)!])
                        .replacingOccurrences(of: #"\n"#, with: "\n").replacingOccurrences(of: #"\""#, with: "\"")
                    if !known.contains(key), !untranslated.contains(key) { missing.append(key) }
                }
            }
        }
        #expect(missing.isEmpty, "Missing in ru.lproj: \(missing)")
    }
}

@Suite struct HistoryTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ t: TimeInterval, session: Double, weekly: Double, weeklyReset: Date? = nil, sessionReset: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(windows: [
            LimitWindow(id: "session", group: .session, title: "Session (5h)", utilization: session, resetsAt: sessionReset ?? start.addingTimeInterval(4 * 3600)),
            LimitWindow(id: "weekly_all", group: .weekly, title: "Weekly · all models", utilization: weekly, resetsAt: weeklyReset ?? start.addingTimeInterval(3 * 86400)),
        ], fetchedAt: start.addingTimeInterval(t))
    }

    @Test func mergesCloseReadingsAndTrimsOldOnes() {
        var history = UsageHistory()
        for minutes in stride(from: 0.0, through: 60, by: 1) {
            history.record(snapshot(minutes * 60, session: minutes, weekly: 10))
        }
        // One reading per minute for an hour stays a handful of samples.
        #expect(history.samples.count <= 8)
        #expect(history.samples.last?.u["session"] == 60)
        history.record(snapshot(9 * 86400, session: 1, weekly: 1))
        #expect(history.samples.allSatisfy { start.addingTimeInterval(9 * 86400).timeIntervalSince($0.t) <= 8 * 86400 })
        // Older readings than the newest are ignored.
        let count = history.samples.count
        history.record(snapshot(0, session: 5, weekly: 5))
        #expect(history.samples.count == count)
    }

    @Test func usagePerDayCountsAcrossAReset() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: start)
        let firstReset = day.addingTimeInterval(86400 + 12 * 3600)
        let secondReset = firstReset.addingTimeInterval(7 * 86400)
        let history = UsageHistory(samples: [
            .init(t: day.addingTimeInterval(3600), u: ["weekly_all": 50], r: ["weekly_all": firstReset]),
            .init(t: day.addingTimeInterval(20 * 3600), u: ["weekly_all": 70], r: ["weekly_all": firstReset]),
            // Next day: the limit reset at noon, then 15 points were used.
            .init(t: day.addingTimeInterval(86400 + 18 * 3600), u: ["weekly_all": 15], r: ["weekly_all": secondReset]),
            .init(t: day.addingTimeInterval(86400 + 22 * 3600), u: ["weekly_all": 25], r: ["weekly_all": secondReset]),
        ])
        let days = history.dailyUse(windowId: "weekly_all", days: 3, now: day.addingTimeInterval(86400 + 23 * 3600), calendar: calendar)
        #expect(days.map(\.percent) == [0, 20, 25])
        #expect(history.daysWithData(windowId: "weekly_all", calendar: calendar) == 2)
    }

    @Test func forecastsTheLimitAtTheCurrentPace() {
        let reset = start.addingTimeInterval(3 * 3600)
        let history = UsageHistory(samples: [
            .init(t: start.addingTimeInterval(-3600), u: ["session": 60], r: ["session": reset]),
            .init(t: start.addingTimeInterval(-1800), u: ["session": 70], r: ["session": reset]),
        ])
        // 20 points an hour from 80%: the limit in an hour, before the reset in three.
        let window = LimitWindow(id: "session", group: .session, title: "", utilization: 80, resetsAt: reset)
        let limit = history.forecast(for: window, at: start)
        #expect(limit.map { abs($0.timeIntervalSince(start.addingTimeInterval(3600))) < 1 } == true)
        // The reset comes first at a slower pace.
        let slow = LimitWindow(id: "session", group: .session, title: "", utilization: 62, resetsAt: reset)
        #expect(history.forecast(for: slow, at: start) == nil)
        // Readings from the previous window don't count.
        let fresh = LimitWindow(id: "session", group: .session, title: "", utilization: 80, resetsAt: reset.addingTimeInterval(5 * 3600))
        #expect(history.forecast(for: fresh, at: start) == nil)
        // Idle.
        let idle = UsageHistory(samples: [.init(t: start.addingTimeInterval(-3600), u: ["session": 80], r: ["session": reset])])
        #expect(idle.forecast(for: window, at: start) == nil)
    }

    @Test func survivesRelaunch() throws {
        var history = UsageHistory()
        history.record(snapshot(0, session: 10, weekly: 20))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claudometer-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        HistoryStore(fileURL: file).save(history)
        #expect(HistoryStore(fileURL: file).load() == history)
    }
}

@Suite struct CheckInTests {
    private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func dueOncePerUTCDay() {
        #expect(CheckIn.isDue(lastSent: nil, now: utc("2026-10-11T10:00:00Z")))
        #expect(!CheckIn.isDue(lastSent: utc("2026-10-11T00:05:00Z"), now: utc("2026-10-11T23:55:00Z")))
        #expect(CheckIn.isDue(lastSent: utc("2026-10-11T23:55:00Z"), now: utc("2026-10-12T00:05:00Z")))
        // A clock set back doesn't send again.
        #expect(!CheckIn.isDue(lastSent: utc("2026-10-12T09:00:00Z"), now: utc("2026-10-11T09:00:00Z")))
    }

    @Test func sendsOnlyTheFourFields() throws {
        let data = try JSONEncoder().encode(CheckIn(id: "abc", version: "0.2.2", language: "ru", os: "26.0"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["id": "abc", "version": "0.2.2", "language": "ru", "os": "26.0"])
    }
}
