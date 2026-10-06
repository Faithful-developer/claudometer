# Claudometer — Technical Specification (TZ)

| | |
|---|---|
| **Product** | Claudometer: a macOS menu bar app and desktop widget for Claude plan usage limits |
| **Version** | 1.0 (draft) |
| **Date** | 2026-10-06 |
| **Platform** | macOS 14 Sonoma and later |
| **Stack** | Swift 5.10+, SwiftUI, WidgetKit, no third-party dependencies |

---

## 1. Overview

### 1.1 Purpose
Claude Pro and Max subscribers have rolling usage limits: a **5-hour session** window and **weekly** windows. Today the only ways to see how much is left are to open claude.ai → Settings → Usage, or to run `/usage` inside Claude Code. Claudometer keeps these numbers visible all the time, in the menu bar and on the desktop. Users can pace their work and won't hit a limit by surprise.

### 1.2 Target user
A developer or power user on macOS who:
- has a Claude Pro or Max subscription, and
- uses Claude Code and is logged in with their Claude account. The app gets its credentials from Claude Code.

### 1.3 Goals
- G-1: Show % used and the time until reset for every plan limit window.
- G-2: The main number can be read in under 1 second (menu bar).
- G-3: A richer glanceable view on the desktop or in Notification Center (widget).
- G-4: Optional alerts before a limit is reached.
- G-5: Zero configuration when Claude Code is already logged in.

### 1.4 Non-goals (v1)
- Anthropic API (Console) billing or token spend.
- Token or cost counting from local Claude Code logs.
- Multiple accounts.
- Windows and Linux.
- App Store distribution (see §4.6).

---

## 2. Data source

### 2.1 Primary: Claude OAuth usage endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
User-Agent: Claudometer/<version>
```

**Expected response** (shape to be confirmed in milestone M1):

```json
{
  "five_hour":        { "utilization": 42.0, "resets_at": "2026-10-06T18:00:00Z" },
  "seven_day":        { "utilization": 17.0, "resets_at": "2026-10-10T09:00:00Z" },
  "seven_day_opus":   { "utilization": 5.0,  "resets_at": "2026-10-10T09:00:00Z" },
  "seven_day_sonnet": null
}
```

> **M1 finding (2026-10-06):** the live response, saved in `docs/sample-usage.json`, also has a **`limits` array**. Each entry has `kind` (`session`, `weekly_all`, `weekly_scoped`), `group`, `percent`, `severity`, `resets_at`, and `scope.model.display_name` for per-model weekly limits. There is also a **`seven_day_breakdown.rows`** list with the share used by each surface (Claude Code, Chats, Cowork, …). The decoder uses `limits` first and falls back to the top-level keys below.

- `utilization` is the percent used, from 0 to 100. Values above 100 are possible and must be clamped for display only.
- `resets_at` is an ISO 8601 timestamp. It may be `null` when the window has not started.
- Any window object may be missing or `null`. **Unknown keys that end in a `{utilization, resets_at}` object must still be displayed** under a generic label, so new limit types appear without an app update.

### 2.2 Credentials
- Claude Code stores its OAuth credentials in the macOS login Keychain:
  - **Service:** `Claude Code-credentials`
  - **Account:** the current macOS user name
  - **Value:** a JSON string:
    ```json
    { "claudeAiOauth": { "accessToken": "...", "refreshToken": "...", "expiresAt": 1759770000000, "scopes": [...], "subscriptionType": "max" } }
    ```
- Claudometer **only reads** this item with `SecItemCopyMatching`. It never writes to it, deletes it or refreshes the token.
- If `expiresAt` (in ms) is in the past, the app shows the "Token expired" state (§7). Claude Code refreshes the token the next time it runs.
- `subscriptionType`, if present, is shown in the popover footer, for example "Max".

### 2.3 Fallback: claude.ai session key (implemented 2026-10-07)
A claude.ai session cookie (`sessionKey`), entered manually in Settings → Login and stored in Claudometer's own Keychain item (`dev.claudometer.claude-ai-session`):
`GET https://claude.ai/api/organizations` → `GET https://claude.ai/api/organizations/{uuid}/usage`. The response shape is the same as §2.1.
- Used only when Claude Code's login is missing, expired or unreadable (E-1…E-3). Claude Code's token always comes first.
- "Save & Test" checks the key against claude.ai and stores it only if it works.
- HTTP 401, or 403 with a JSON body → "session key expired" (normal polling cadence until the user pastes a new key). 403 with an HTML body or `cf-mitigated` → "blocked by claude.ai" (Cloudflare bot check; backoff).
- The key is never written to disk, logs or the widget's folder. The snapshot records only which source was used.
- While every source fails, windows whose reset time has passed read 0% (weekly windows roll forward a week; a session window has no reset until it is used again). An expired Claude Code token is re-checked every minute.

### 2.4 Risks
- **R-1:** Both endpoints are **undocumented** and may change or disappear. Mitigations: tolerant decoding, a clear "API changed" error state, and isolating all network code in `UsageAPIClient`.
- **R-2:** The first time the app reads the Keychain, macOS shows an "allow access" prompt. The user must choose **Always Allow**. This must be explained during onboarding.
- **R-3:** Polling too often may trigger rate limiting (HTTP 429). The minimum interval is 1 min, the default is 5 min, and the app backs off on errors.

### 2.5 Data model (`Shared` module)

```swift
enum LimitKind: Hashable, Codable {
    case session          // five_hour
    case weekly           // seven_day
    case weeklyOpus       // seven_day_opus
    case weeklySonnet     // seven_day_sonnet
    case other(String)    // any unknown key
}

struct LimitWindow: Codable, Identifiable {
    var id: LimitKind { kind }
    let kind: LimitKind
    let utilization: Double     // 0...100+
    let resetsAt: Date?
}

struct UsageSnapshot: Codable {
    let windows: [LimitWindow]
    let plan: String?           // "pro" | "max" | nil
    let fetchedAt: Date
}

enum UsageState: Codable {
    case ok(UsageSnapshot)
    case stale(UsageSnapshot, error: AppError)   // last good data + current error
    case error(AppError)                          // no data at all
}
```

---

## 3. Functional requirements

### 3.1 Menu bar item
- **FR-1:** The app runs as a menu bar–only agent app (`LSUIElement = YES`, no Dock icon).
- **FR-2:** The menu bar shows a small ring/gauge icon and the % of the **primary metric**, for example `◔ 42%`.
- **FR-3:** The primary metric can be chosen in Settings:
  - Session (5h), the default
  - Weekly
  - Highest of all windows
- **FR-4:** The colour depends on utilization, and the thresholds can be changed in Settings:
  - green below 60%
  - yellow from 60% to 85%
  - red above 85%
  - grey when the data is stale or there is an error
- **FR-5:** Optional "compact" mode shows the icon only, without the % text.

### 3.2 Popover (click on the menu bar item)
- **FR-6:** One row per limit window, each with:
  - the label (for example "Session (5h)", "Weekly — all models", "Weekly — Opus")
  - a progress bar
  - % used
  - a reset countdown, for example "Resets in 2h 14m" or "Resets Fri 09:00" when more than 24h away
- **FR-7:** The footer shows "Updated N min ago", the plan name, and buttons for **Refresh**, **Settings…** and **Quit**.
- **FR-8:** When the app is in an error state, the popover shows a message with an action button (see §7).
- **FR-9:** The countdowns update every 30 s while the popover is open. This needs no network call.

### 3.3 Desktop / Notification Center widget (WidgetKit)
- **FR-10:** Three widget families are supported:
  - **Small (`systemSmall`):** a large ring for the primary metric, the %, and "resets in Xh Ym".
  - **Medium (`systemMedium`):** Session and Weekly bars with % and reset times.
  - **Large (`systemLarge`):** all windows, the plan name and "updated at" time.
- **FR-11:** The widget reads the latest `UsageState` from the shared App Group container. **The widget makes no network calls.**
- **FR-12:** The app calls `WidgetCenter.shared.reloadAllTimelines()` after each successful fetch.
- **FR-13:** Each widget timeline adds entries every 15 min so countdowns stay roughly current between app updates. If the data is more than 30 min old, the widget shows a "stale" badge.
- **FR-14:** Clicking the widget opens the popover through the URL scheme `claudometer://open`.

### 3.4 Polling
- **FR-15:** The app fetches once at launch, then repeats every N minutes. N defaults to 5 and can be set from 1 to 30.
- **FR-16:** On error, the app backs off exponentially: 1 → 2 → 4 → 8 → 15 min (cap), then returns to normal after a success. When the server returns HTTP 429 with a `Retry-After` header, the app waits at least that long.
- **FR-17:** Polling pauses while the Mac sleeps and an immediate fetch runs on wake (`NSWorkspace.didWakeNotification`). The app also fetches immediately when the network comes back (`NWPathMonitor`).
- **FR-18:** Clicking Refresh fetches immediately. Repeated clicks are debounced to one fetch every 10 s.

### 3.5 Notifications
- **FR-19:** Optional local notifications through `UserNotifications`. They are off until the user enables them.
- **FR-20:** The alert thresholds default to **80%** and **95%**. Each threshold fires **once per window per reset cycle**, keyed by `kind + resetsAt`.
- **FR-21:** An optional "Limit reset" notification fires when a window that was at or above 95% goes back to a low value.

### 3.6 Settings window
- **FR-22:** Settings:
  - **Refresh interval:** a stepper, 1–30 min
  - **Menu bar metric:** Session / Weekly / Highest
  - **Compact menu bar:** on/off
  - **Colour thresholds:** two sliders
  - **Notifications:** on/off and the thresholds
  - **Launch at login:** uses `SMAppService.mainApp`
  - **About:** version and a GitHub link
- **FR-23:** Settings are stored in `UserDefaults`. Values the widget needs, such as the primary metric and thresholds, are mirrored into the App Group defaults.

### 3.7 Onboarding / states
- **FR-24:** On first launch, a short onboarding sheet explains:
  1. Claudometer reads your Claude Code login.
  2. macOS will ask for Keychain access. Choose "Always Allow".
  3. If you are not logged in, run `claude` in Terminal, then `/login`.
- **FR-25:** Each error state from §7 has its own message and recovery action.

---

## 4. Non-functional requirements

- **NFR-1 · Platform:** macOS 14+, on Apple Silicon and Intel (universal binary).
- **NFR-2 · Stack:** Swift and SwiftUI with `MenuBarExtra(.window)`, WidgetKit, `URLSession` with async/await and `Security.framework`. **No third-party dependencies.**
- **NFR-3 · Performance:** at idle the app uses less than 1% CPU and less than 50 MB RSS. Each fetch uses less than 50 KB of network traffic.
- **NFR-4 · Privacy and security:**
  - The access token stays in memory only. It is never written to disk, `UserDefaults`, logs or the App Group container.
  - The only network host is `api.anthropic.com`, plus `claude.ai` if the v2 fallback is enabled.
  - There is no analytics and no telemetry.
  - Logs go through `os.Logger` with `privacy: .private` on anything sensitive.
- **NFR-5 · UX:**
  - Supports light and dark mode.
  - Respects accent colour and Reduce Motion.
  - Every control and gauge has a VoiceOver label, for example "Session limit, 42 percent used, resets in 2 hours 14 minutes".
- **NFR-6 · Localization:** English in v1. All strings live in `Localizable.xcstrings` so more languages can be added later.
- **NFR-7 · Distribution:**
  - v1 is a Developer ID–signed, notarized DMG.
  - The **main app is not sandboxed**, because it reads another app's Keychain item.
  - The **widget extension is sandboxed**, which WidgetKit requires. It only reads the App Group container.
  - The App Group ID uses the team prefix: `<TEAMID>.com.<you>.claudometer`.
- **NFR-8 · Robustness:** decoding is tolerant. Unknown fields are ignored, missing windows are skipped, and the app never crashes on bad data.

---

## 5. Architecture

### 5.1 Xcode targets

| Target | Type | Responsibility |
|---|---|---|
| `Claudometer` | macOS App (agent) | Menu bar UI, polling, Keychain, network, notifications, settings |
| `ClaudometerWidget` | Widget Extension | Small, medium and large widgets that read from the App Group |
| `Shared` | Framework / Swift package (local) | Models, `SharedSnapshotStore`, formatting helpers (countdowns, colours) |
| `ClaudometerTests` | Unit tests | Decoding, backoff, threshold logic, formatting |

### 5.2 Components

| Component | Module | Responsibility |
|---|---|---|
| `KeychainTokenProvider` | App | Reads `Claude Code-credentials`, parses the JSON, returns `(accessToken, expiresAt, plan)` |
| `UsageAPIClient` | App | `func fetchUsage(token:) async throws -> UsageSnapshot`. Builds the request, maps HTTP codes to `AppError` |
| `UsageDecoder` | Shared | Tolerant JSON → `[LimitWindow]`, including unknown keys |
| `UsageStore` | App | `@Observable` main state, polling timer, backoff, sleep/wake and network monitoring |
| `SharedSnapshotStore` | Shared | Reads and writes `UsageState` as JSON in the App Group container, then triggers a widget reload |
| `NotificationManager` | App | Threshold crossing detection, de-duplication, `UNUserNotificationCenter` |
| `SettingsStore` | Shared | Typed `UserDefaults` wrapper, mirrored to App Group defaults |
| `Formatters` | Shared | `"2h 14m"`, `"Fri 09:00"`, colour for a given %, labels for each `LimitKind` |

### 5.3 Data flow

```
 ┌──────────────┐  read   ┌──────────────────────┐
 │ macOS        │◄────────│ KeychainTokenProvider│
 │ Keychain     │         └──────────┬───────────┘
 └──────────────┘                    │ token
                                     ▼
 ┌──────────────┐  HTTPS  ┌──────────────────────┐
 │ api.anthropic│◄────────│ UsageAPIClient       │
 │ .com         │────────►│ + UsageDecoder       │
 └──────────────┘  JSON   └──────────┬───────────┘
                                     │ UsageSnapshot
                                     ▼
                          ┌──────────────────────┐   ┌─────────────────────┐
         timer / wake ───►│ UsageStore           │──►│ NotificationManager │
         refresh click    └───┬──────────────┬───┘   └─────────────────────┘
                              │              │
                  @Observable │              │ write JSON + reloadAllTimelines()
                              ▼              ▼
                   ┌────────────────┐  ┌──────────────────────┐
                   │ MenuBarExtra   │  │ App Group container  │
                   │ + Popover UI   │  └──────────┬───────────┘
                   └────────────────┘             │ read
                                                  ▼
                                       ┌──────────────────────┐
                                       │ ClaudometerWidget    │
                                       │ (S / M / L)          │
                                       └──────────────────────┘
```

### 5.4 Suggested folder layout

```
claude-widget/
├── TZ.md
├── Claudometer.xcodeproj
├── Claudometer/            # app target
│   ├── ClaudometerApp.swift
│   ├── MenuBar/            # label, popover views
│   ├── Settings/
│   ├── Onboarding/
│   ├── Services/           # KeychainTokenProvider, UsageAPIClient, NotificationManager
│   └── UsageStore.swift
├── ClaudometerWidget/      # widget extension
│   ├── ClaudometerWidget.swift
│   ├── Provider.swift
│   └── Views/              # Small/Medium/Large
├── Shared/                 # models, decoder, store, formatters, settings
└── ClaudometerTests/
```

---

## 6. UI mockups

### 6.1 Menu bar
```
  … 🔋 📶  ◔ 42%  🔍 Mon 16:30
```

### 6.2 Popover (≈ 300 pt wide)
```
┌──────────────────────────────────────┐
│  Claudometer                    Max  │
├──────────────────────────────────────┤
│  Session (5h)                  42 %  │
│  ████████░░░░░░░░░░░                 │
│  Resets in 2h 14m                    │
│                                      │
│  Weekly — all models           17 %  │
│  ███░░░░░░░░░░░░░░░░                 │
│  Resets Fri 09:00                    │
│                                      │
│  Weekly — Opus                  5 %  │
│  █░░░░░░░░░░░░░░░░░░                 │
│  Resets Fri 09:00                    │
├──────────────────────────────────────┤
│  Updated 1 min ago                   │
│  [↻ Refresh]   [Settings…]   [Quit]  │
└──────────────────────────────────────┘
```

### 6.3 Widgets
```
 Small                 Medium
┌───────────┐         ┌───────────────────────────────┐
│   ╭───╮   │         │ Session (5h)            42 %  │
│  │ 42% │  │         │ ████████░░░░░░░░  in 2h 14m   │
│   ╰───╯   │         │ Weekly                  17 %  │
│  Session  │         │ ███░░░░░░░░░░░░░  Fri 09:00   │
│ in 2h 14m │         └───────────────────────────────┘
└───────────┘

 Large
┌───────────────────────────────┐
│ Claudometer              Max  │
│ Session (5h)            42 %  │
│ ████████░░░░░░░░  in 2h 14m   │
│ Weekly — all            17 %  │
│ ███░░░░░░░░░░░░░  Fri 09:00   │
│ Weekly — Opus            5 %  │
│ █░░░░░░░░░░░░░░░  Fri 09:00   │
│                               │
│ Updated 16:28                 │
└───────────────────────────────┘
```

---

## 7. Error handling

| # | Condition | Detection | Menu bar | Popover message | Recovery |
|---|---|---|---|---|---|
| E-1 | Claude Code not logged in | Keychain item not found (`errSecItemNotFound`) | `◔ —` grey | "Not signed in. Run `claude` in Terminal and use `/login`." | Re-check on every poll and on Refresh |
| E-2 | Keychain access denied | `errSecAuthFailed` / user denied | `◔ —` grey | "Keychain access denied. Click Retry and choose Always Allow." | Retry button calls the Keychain again |
| E-3 | Token expired | `expiresAt < now` or HTTP 401 | grey + last % | "Session expired. Open Claude Code once to refresh your login." | Re-read the Keychain on every poll |
| E-4 | Rate limited | HTTP 429 | last % (stale) | "Rate limited, retrying in N min." | Honour `Retry-After` and back off |
| E-5 | Offline / timeout | `URLError` | last % (stale) | "Offline. Showing data from HH:MM." | `NWPathMonitor` fetches when the network returns |
| E-6 | Server error | HTTP 5xx | last % (stale) | "Claude service error. Retrying…" | Back off |
| E-7 | API changed | HTTP 404, or decoding returns no windows | `◔ ?` grey | "Usage format not recognised. Check for an update." | Log the response shape (no token) and keep polling at the normal interval |

Stale data (E-3 to E-6) is still displayed but greyed out, with a "Showing data from HH:MM" note.

---

## 8. Milestones

| # | Milestone | Scope | Exit criteria |
|---|---|---|---|
| M1 | **Spike** | Read the Keychain item and call the endpoint from a Swift script or Playground. Record the real response shape. | Real JSON saved in `docs/sample-usage.json` (with the token removed). §2.1 updated if needed |
| M2 | **Menu bar MVP** | `KeychainTokenProvider`, `UsageAPIClient`, `UsageStore`, menu bar label, popover, Refresh/Quit | FR-1…FR-9 and FR-15…FR-18 work. E-1 and E-3…E-5 handled |
| M3 | **Widget** | App Group, `SharedSnapshotStore`, widget extension with S/M/L | FR-10…FR-14 work and the widget updates after a fetch |
| M4 | **Settings & notifications** | Settings window, launch at login, notifications, onboarding | FR-19…FR-25 work |
| M5 | **Polish & release** | Accessibility, app icon, unit tests, signing, notarization, DMG | §9 acceptance criteria all pass |

**Status (2026-10-06):**
- **Done:**
  - M1.
  - M2: built with SwiftPM, live data verified.
  - M4: written; notifications and launch at login need the bundled `.app`.
- **M3:** widget code is written and typechecks against the SDK. It still needs Xcode and a Team ID to build (`project.yml`).
- **M5 so far:** icon, unit tests, ad-hoc signed universal `.app` and DMG script. Developer ID signing and notarization are still open.

---

## 9. Acceptance criteria

- **AC-1:** Fresh install with Claude Code logged in: after onboarding and "Always Allow", the menu bar shows a % within 5 s.
- **AC-2:** The menu bar Session % matches `/usage` in Claude Code (or claude.ai → Settings → Usage) within ±1 percentage point.
- **AC-3:** The reset countdown matches the reset time shown by claude.ai within ±1 minute.
- **AC-4:** After a fetch, the desktop widget shows the new value within 1 minute.
- **AC-5:** With Wi‑Fi off, the app shows the last data greyed out with the stale message. With Wi‑Fi back on, it updates without user action within 1 minute.
- **AC-6:** After `/logout` in Claude Code, the app shows E-1 at the next poll and does not crash.
- **AC-7:** With notifications on and thresholds at 80/95, crossing 80% produces exactly one notification per reset cycle.
- **AC-8:** The token does not appear in any file under `~/Library` or in the Console.app logs. Checked with `grep -r` for the token prefix.
- **AC-9:** Idle CPU averages under 1% over 10 minutes, measured in Activity Monitor.
- **AC-10:** Unit tests cover decoding (known, unknown and missing keys), backoff, threshold de-duplication and countdown formatting. All pass.

---

## 10. Open questions & future work

- **Q-1:** Do the exact response fields (`seven_day_sonnet`, extra-usage or "overage" fields) differ between Pro and Max? This is answered in M1.
- **Q-2:** Should the app ask Claude Code to refresh an expired token, for example by running `claude -p ""`? This is not done in v1 because it has side effects.
- **F-1:** The claude.ai cookie fallback (§2.3) for users who don't use Claude Code.
- **F-2:** Multiple accounts or organisations.
- **F-3:** A local usage history: store snapshots and show a 7-day sparkline in the popover and the large widget.
- **F-4:** Show the "burn rate" and the projected time to the limit at the current pace.
- **F-5:** A Raycast extension, an Übersicht widget, or an iOS companion that reads the same data.
- **F-6:** Homebrew Cask distribution and automatic updates with Sparkle. This would add a dependency, so it needs a review.
