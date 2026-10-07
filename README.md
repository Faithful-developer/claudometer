<p align="center"><img src="docs/icon.png" width="128" alt="Claudometer icon"></p>

# Claudometer — unofficial Claude usage meter

A tiny macOS menu bar app (plus a desktop widget) that shows how much of your **Claude plan limits** you've used: the 5‑hour session window and the weekly windows, each with a reset countdown. When another limit runs high (say weekly at 80%), it gets its own lettered ring in the menu bar so you don't miss it. Click any limit in the popover to copy all your limits as an image.

> **Unofficial.** Claudometer is an independent open-source project. It is not affiliated with, endorsed by or supported by Anthropic. It relies on an **undocumented** usage endpoint that may change or stop working at any time; if the format changes, the app says "Usage format not recognised" instead of showing wrong numbers.

<p align="center">
  <img src="docs/screenshots/menubar-light.png" height="36" alt="Menu bar item">
  <br><br>
  <img src="docs/screenshots/popover-light.png" width="300" alt="Popover">
  &nbsp;
  <img src="docs/screenshots/widget-medium-dark-high.png" width="388" alt="Medium desktop widget">
</p>

## What it reads, and what it never does

**Reads**
- Your **Claude Code login token** from the macOS Keychain item `Claude Code-credentials`, **read-only**. Claudometer never changes, refreshes or deletes it.
- Your usage from `api.anthropic.com/api/oauth/usage`, the same account endpoint Claude Code uses.
- It saves only the last usage numbers (percentages and reset times, no token) to `~/Library/Application Support/Claudometer/`, so the widget can show them.
- *Optional, off by default:* a claude.ai `sessionKey` you paste in yourself (see [claude.ai backup](#optional-claudeai-backup)).

**Never**
- Never writes a token or key to disk, `UserDefaults`, logs or the widget's folder. Tokens stay in memory; the optional session key lives only in Claudometer's own Keychain item.
- Never logs credentials or usage.
- Never talks to any server except Anthropic (`api.anthropic.com`, and `claude.ai` only if you enable the backup) and GitHub (`api.github.com`, a daily anonymous check for new releases).
- No analytics, no telemetry, no third-party services.

The code is short and open, so you can check all of this yourself: [`CredentialsProvider`](Sources/ClaudometerCore/CredentialsProvider.swift), [`UsageAPIClient`](Sources/ClaudometerCore/UsageAPIClient.swift), [`UsageService`](Sources/ClaudometerCore/UsageService.swift).

### About the Keychain prompt

The first time Claudometer reads Claude Code's login, macOS may show *"Claudometer wants to use your confidential information stored in 'Claude Code-credentials' in your keychain."* That's expected: it's how the app reuses your existing Claude Code login instead of asking for a password. Choose **Always Allow** so it doesn't ask on every check. You can revoke it any time in Keychain Access.

The full specification is in [TZ.md](TZ.md).

## Requirements

- macOS 14 Sonoma or later
- A Claude Pro/Max subscription and **Claude Code signed in** (`claude` → `/login`). Claudometer reuses that login.

## Install

Building it yourself (below) is the most transparent option. Prebuilt, ad-hoc signed builds are also available:

Download the latest `Claudometer-x.y.z.dmg` from [Releases](https://github.com/Faithful-developer/claudometer/releases) and drag the app to Applications.
Claudometer checks for new releases once a day and shows **Update Available** in the menu; *Settings → About* has **Check for Updates**.

### "Claudometer can't be opened" on first launch

The prebuilt app is not signed with an Apple Developer ID and not notarized (that needs a paid developer account, which this project doesn't have), so Gatekeeper blocks it the first time. Either:

1. Try to open the app once, then go to **System Settings → Privacy & Security**, scroll down to the message about Claudometer and click **Open Anyway**. Confirm with your password or Touch ID. Only needed once per version.
2. Or clear the quarantine flag in Terminal: `xattr -dr com.apple.quarantine /Applications/Claudometer.app`

Updates downloaded from Releases go through the same step. If you'd rather not trust a prebuilt binary, build it yourself below: the build is ad-hoc signed on your Mac, so Gatekeeper never asks.

## Build & run (no Xcode needed)

```bash
scripts/build-app.sh             # → build/Claudometer.app (universal, ad-hoc signed)
scripts/build-app.sh --install   # copy to /Applications and launch
scripts/build-app.sh --dmg       # also package build/Claudometer-<version>.dmg
scripts/test.sh                  # unit tests (clean build; works around a CLT macro-plugin bug)
```

Swift Package Manager builds the menu bar app with only the Command Line Tools installed.

## Desktop widget (needs Xcode)

```bash
brew install xcodegen
scripts/build-xcode.sh      # app + widget → /Applications, launched
```

No Apple developer team is needed. The app and widget share data through `~/Library/Application Support/Claudometer/` instead of an App Group: the sandboxed widget has a read-only sandbox exception for that one folder. The shared code is linked statically into both, so library validation passes with local signing. After installing, right-click the desktop → **Edit Widgets…** → search "Claudometer".

## Optional: claude.ai backup

Claude Code refreshes its login only while it's running, so after about 8 hours with Claude Code closed the token expires and Claudometer shows the last known numbers. If you want usage to stay live anyway, paste your claude.ai `sessionKey` cookie in **Settings → Login** and press **Save & Test**.

- **Off by default.** Nothing happens unless you paste a key.
- Used **only** while Claude Code's login is expired or missing; Claude Code's login always comes first.
- Stored only in Claudometer's own Keychain item and sent only to `claude.ai`. **Remove** deletes it.
- It's your full claude.ai web session and the claude.ai endpoint is also undocumented, so skip this if you're not comfortable with that.

## How it works

| Piece | What it does |
|---|---|
| `CredentialsProvider` | Reads Claude Code's OAuth token from the Keychain item `Claude Code-credentials` (read-only; never stored or logged) |
| `ClaudeWebClient` | Backup source: claude.ai's usage API with the `sessionKey` cookie you paste in *Settings → Login*. Used only while Claude Code's login is expired (Claude Code refreshes it only while running) |
| `UsageAPIClient` | `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` |
| `UsageDecoder` | Tolerant parsing. Prefers the `limits` array and falls back to the legacy `five_hour` / `seven_day*` keys. Unknown limit kinds are still shown |
| `UsageStore` | Polls every 5 min by default (1–30). Backs off exponentially on errors (1→2→4→8→15 min), honours `Retry-After`, and refreshes on wake or when the network comes back |
| `NotificationManager` | Optional alerts at 80% / 95% (once per window per reset cycle) and when a limit resets |
| `SnapshotStore` | Last known state as JSON (`~/Library/Application Support/Claudometer/`, or the App Group in the widget build). Contains no token |

## Project layout

```
Sources/ClaudometerCore/   models, decoder, API client, Keychain, backoff, thresholds, store
Sources/Claudometer/       SwiftUI menu bar app (MenuBarExtra), settings, notifications
Widget/                    WidgetKit extension (built via project.yml / Xcode)
Tests/                     swift-testing unit tests + real response fixture
scripts/                   build-app.sh, make-icon.swift
Config/                    entitlements for the Xcode build
TZ.md                      technical specification
```

## Design

Claudometer follows Apple's Human Interface Guidelines and looks like a built-in menu bar extra (Battery, Wi‑Fi, Control Center):
- **System look:** the window keeps the system material. Text uses hierarchical `.primary`/`.secondary`/`.tertiary` styles, so it picks up vibrancy, light/dark mode and Increase Contrast.
- **Light and dark:** follows the system by default. *Settings → General → Appearance* can pin Light or Dark.
- **Colours:** from the Claudometer palette ([docs/palette.html](docs/palette.html)). Meters use Meter Coral; Attention amber and Over-limit red take over near limits; status pills (On track / Ahead of pace / Getting close / Near limit) use each status colour on its soft tint. Dark mode uses matching dark steps of the same hues.
- **Warnings:** system orange and red appear only above your thresholds, always with an SF Symbol and a label.
- **Menu bar icon:** monochrome like other system icons until usage needs attention.
- **Actions:** full-width menu rows with keyboard shortcuts (⌘R, ⌘,, ⌘Q) and an accent-coloured hover highlight.
- **Settings:** toolbar tabs (General, Notifications, Login, About) with grouped forms.
- **Meters:** capacity rings and bars, like the Batteries widget. A 2pt tick marks how much of the window's time has passed, so you can see your pace.
- **Usage by surface:** one stacked bar with a legend that lists each value. Series follow the palette order: Usage coral (Claude Code), plum (Chats), teal (Cowork). The dark steps were picked to keep the hues and still pass the data-viz colour-blind checks.
- **Shared code:** the components live in `Sources/ClaudometerCore/UI/`, so the popover and widgets match.

## Developer notes

- `Claudometer --render-previews <dir> [--sample high|rings|stale|signedout]` renders the menu bar icon, popover and all three widget sizes (light and dark) to PNGs, then exits. It uses the cached state, or made-up numbers: `--sample high` for high usage, `--sample rings` for two other limits high enough to get extra menu bar rings. It's used for the screenshots above.
- `swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`.
- `scripts/release.sh 0.2.0 "notes"` builds the app with the widget, packages a DMG, tags `v0.2.0` and publishes the GitHub release. Always bump the version: the in-app update check compares it with the latest release.
- Notifications and launch at login only work from the bundled `.app`, not from `swift run`.

## License

[MIT](LICENSE). "Claude" is a trademark of Anthropic; this project only refers to it to describe what it measures.
