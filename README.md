# Claude Usage Widget

A native macOS **Notification Center / desktop widget** that shows your Claude usage the same way
the claude.ai and Claude Code `/usage` panel does — session limit, weekly limit, weekly Opus, and
usage credits — for **any plan** (Pro, Max 5×, Max 20×, credit/overage).

<p align="center">
  <img src="docs/widget.png" alt="Claude Usage widget in macOS Notification Center" width="520">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

> **Unofficial.** This reads an *undocumented* Anthropic endpoint and is **not affiliated with or
> endorsed by Anthropic**. It may break at any time. See [security & disclaimer](#security).

## ⚡ Install with Claude Code (easiest)

Clone the repo, open **Claude Code** in the repo folder, and paste this prompt — it will read the
docs, check what you're missing, install what it can, guide the manual bits, and set up the widget:

```text
Install this macOS "Claude Usage" widget for me from this repo.
1. Read README.md and SECURITY.md, then tell me in 2 lines what the app does with my Claude token.
2. Check my prerequisites: macOS; Xcode.app installed; Homebrew; that I'm signed into Claude Code
   (run `claude`); and signed into Xcode with an Apple ID (Settings > Accounts) for a free Personal Team.
3. Install anything missing that is safe to install non-interactively (e.g. `brew install xcodegen`).
   If Xcode.app or the Xcode Apple-ID sign-in is missing, walk me through those (they are manual).
4. Run `./scripts/install.sh` and show me any errors, fixing what you can.
5. When it builds, tell me to click "Always Allow" on the Keychain prompt, then walk me through
   adding the "Claude Usage" widget in Notification Center and enabling "Launch at login".
Explain each step briefly before running it, and never print my token.
```

Prefer to drive it yourself? Jump to [Manual install](#manual-install).

## Features

- **Session** (5-hour), **Weekly** (all-models), and **Weekly · Opus** limits — utilization % with
  live "resets in …" countdowns.
- **Usage credits** — spent vs. monthly cap (and balance) when enabled.
- **All plan types** — sections that don't apply to your plan are hidden automatically.
- Color-coded by severity (blue → amber → red), matching the claude.ai panel.
- A companion **menu-bar readout** with a refresh button and *Launch at login*.
- Runs entirely on your Mac. No server, no telemetry, token never leaves your machine except to
  Anthropic's own endpoint.

| Notification Center | Xcode timeline preview |
|---|---|
| <img src="docs/widget.png" width="380"> | <img src="docs/timeline.png" width="380"> |

## How it works

```
Keychain (Claude Code-credentials)
        │  read token   (non-sandboxed agent only)
        ▼
ClaudeUsage.app  ──►  GET https://api.anthropic.com/api/oauth/usage
  (menu-bar agent)         │
        │  parse           ▼
        ▼            write usage.json
~/Library/Application Support/ClaudeUsage/usage.json
        ▲  read-only (sandbox path exception)
        │
ClaudeUsageWidget  (sandboxed WidgetKit extension) → renders in Notification Center
```

The agent owns auth + network because a sandboxed widget can't read Claude Code's Keychain item or
refresh an expired token. The widget reads one plain JSON file through a read-only sandbox
*path exception* — deliberately **not** an App Group, which on macOS needs a paid developer account.
A path exception is honored by **free personal-team** signing, so no paid membership is required.

## Requirements

- macOS 14+ (built and tested on macOS 26)
- [Claude Code](https://claude.com/claude-code) signed in (this app reuses its Keychain token)
- **Xcode** (to build the WidgetKit extension) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- A free Apple ID (Personal Team) for local signing — no paid membership needed

## Manual install

Prerequisites: **Xcode.app**, `brew install xcodegen`, and a one-time Xcode sign-in (Settings ▸
Accounts) for a free Personal Team. Then, from the repo root:

```bash
./scripts/install.sh        # auto-detects your Team ID, configures, builds, installs, launches
#   make install            # same thing
#   ./scripts/install.sh <TEAM_ID>   # if auto-detect can't find your team
```

Then: click **Always Allow** on the first-run Keychain prompt → open **Notification Center** →
**Edit Widgets** → add **Claude Usage** (medium) → and enable **Launch at login** from the
menu-bar gauge icon so the agent keeps the widget fresh after a reboot.

<details>
<summary>Prefer to run the steps yourself</summary>

```bash
brew install xcodegen
./scripts/configure.sh <TEAM_ID>   # generates entitlements + the Xcode project
#   Team ID: security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
open ClaudeUsage.xcodeproj         # ⌘R  (or: make build)
```
</details>

### Verify the data layer without Xcode

```bash
make check        # or: swift run DataLayerCheck   → "ALL CHECKS PASSED"
make live         # or: swift run DataLayerCheck --live   (Keychain → endpoint → parsed snapshot)
bash scripts/fetch_usage.sh        # the same request in shell form
```

## Repo layout

| Path | What |
|------|------|
| `Shared/` | Model, parser, formatting, Keychain + fetch, snapshot store (pure, testable) |
| `SharedUI/` | SwiftUI pieces shared by the menu bar popover and the widget |
| `ClaudeUsageApp/` | The background agent app (menu bar item, timer, login item) |
| `ClaudeUsageWidget/` | The WidgetKit extension (TimelineProvider + small/medium views) |
| `Tools/DataLayerCheck/` | Data-layer assertions that run with **no Xcode** |
| `fixtures/` | Sample API responses for Pro / Max 5× / Max 20× / limits-only |
| `scripts/install.sh` | One-command install (auto-detects Team ID, builds, installs, launches) |
| `scripts/configure.sh` | Generates local entitlements + project with your Team ID |
| `scripts/fetch_usage.sh` | The live request in shell form (handy for debugging) |
| `project.yml` | XcodeGen spec → `ClaudeUsage.xcodeproj` |

## How data refreshes

- The agent polls every 3 minutes (`UsageAgent.refreshInterval`), writes `usage.json`, and reloads
  the widget; WidgetKit also self-refreshes countdowns roughly every 15 minutes.
- **Token auto-refresh (on by default).** As the ~8h OAuth token nears expiry, the agent refreshes
  it via the refresh-token grant and writes the rotated tokens **back into the same Keychain blob**
  (preserving every sibling key), so the widget stays fresh even when Claude Code has been idle and
  Claude Code keeps working seamlessly. It first re-reads the Keychain in case Claude Code already
  refreshed, and a failed refresh writes nothing and just falls back to the last snapshot. Toggle it
  off from the menu-bar icon ("Refresh token automatically"). The client_id and token endpoint are
  the same ones Claude Code itself uses.

## Security

The token is read from the Keychain, sent only to Anthropic's `/api/oauth/usage`, and **never
written to disk or logged** — only the derived usage numbers are stored. Full details, sandboxing,
and the unofficial-endpoint disclaimer are in **[SECURITY.md](SECURITY.md)**.

## Roadmap

- `systemSmall` polish and optional multi-account support.
- A signed, notarized release build so friends can install without Xcode.

## License

[MIT](LICENSE) © 2026 Andres Milioto. Not affiliated with Anthropic.
