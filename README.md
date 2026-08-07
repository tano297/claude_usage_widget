# Claude Usage Widget

A native macOS **Notification Center / desktop widget** that shows the limits from Claude Code's
`/usage` panel: current session, current week, and any per-model weekly limits. It also shows the
signed-in account email and plan label in the menu-bar popover and medium widget.

<p align="center">
  <img src="docs/widget.png" alt="Claude Usage widget in Notification Center" width="350">
  &nbsp;&nbsp;
  <img src="docs/menu.png" alt="Claude Usage menu-bar popover" width="205">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

> **Unofficial.** Claude Code's `/usage` prose is not a documented, stable interface. It may change
> at any time; parse failures retain the last good values with a **Stale** badge. This project is not
> affiliated with or endorsed by Anthropic. See [security & disclaimer](#security).

## ⚡ Install with Claude Code (easiest)

Clone the repo, open **Claude Code** in the repo folder, and paste this prompt:

```text
Install this macOS "Claude Usage" widget for me from this repo.
1. Read README.md and SECURITY.md, then tell me in 2 lines how the app gets usage without reading
   or holding my Claude credentials.
2. Check my prerequisites: macOS; Claude Code installed and signed in via `claude`; Xcode.app;
   Homebrew; and Xcode signed in with an Apple ID for a free Personal Team.
3. Install anything missing that is safe to install non-interactively (e.g. `brew install xcodegen`).
   If Xcode.app or the Xcode Apple-ID sign-in is missing, walk me through those manual steps.
4. Run `./scripts/install.sh` and show me any errors, fixing what you can.
5. When it builds, walk me through adding "Claude Usage" in Notification Center. Launch at login
   turns on automatically.
Explain each step briefly before running it, and never print raw Claude usage output.
```

Prefer to drive it yourself? Jump to [Manual install](#manual-install).

## Features

- **Session**, **Weekly**, and per-model **Weekly · <model>** utilization with live reset
  countdowns. Rows appear only when Claude's `/usage` output reports them.
- **Account context** — the signed-in email appears below the plan label on surfaces with room.
- **Plan labels** from Claude Code (`Max`, `Pro`, `Team`, `Free`, or `Enterprise`). The CLI output
  does not expose Max's 5×/20× tier, so the widget intentionally shows simply `Max`.
- Anthropic-clay identity color (`#D97757`) with warmer severity escalation as a limit fills.
- **Tap-to-refresh (↻)** plus a live **Updated … ago** freshness indicator.
- A companion menu-bar readout, refresh button, notifications, and launch-at-login control.
- Runs locally with no project server or telemetry. Claude Code handles its own authentication and
  vendor request; the app never reads or holds a credential.

The `/usage` prose currently has no credits row, so fresh snapshots do not show usage credits.

## How it works

```text
ClaudeUsage.app (non-sandboxed menu-bar agent)
        │
        ├─► claude auth status --json
        │      consume only loggedIn, email, subscriptionType
        │
        └─► claude -p /usage --output-format json
              --strict-mcp-config --no-session-persistence
                       │
                       ▼
              whitelist three usage-bar line forms
                       │
                       ▼
~/Library/Application Support/ClaudeUsage/usage.json
                       ▲  read-only sandbox path exception
                       │
ClaudeUsageWidget (sandboxed WidgetKit extension) → renders in Notification Center
```

The agent spawns the Claude Code CLI, which handles its own authentication and network request. It
discards everything except auth status's `loggedIn`, `email`, and `subscriptionType` fields and the
three recognized `/usage` bar-line forms. In particular, the “What's contributing” analytics block
is never written to the snapshot.

The widget reads one JSON file through a read-only sandbox path exception. This deliberately avoids
App Groups, which require a registered group identifier; local personal-team signing is sufficient.

## Requirements

- macOS 14+ (built and tested on macOS 26)
- [Claude Code](https://claude.com/claude-code) **installed and signed in via `claude`**
- **Xcode** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A free Apple ID (Personal Team) for local signing — no paid membership needed

## Manual install

Prerequisites: **Xcode.app**, `brew install xcodegen`, Claude Code signed in, and a one-time Xcode
sign-in (Settings ▸ Accounts) for a free Personal Team. From the repo root:

```bash
./scripts/install.sh             # auto-detects Team ID, builds, installs, launches
# make install                   # same thing
# ./scripts/install.sh <TEAM_ID> # if auto-detect cannot find your team
```

No Keychain approval is required. Open **Notification Center** → **Edit Widgets** → add **Claude
Usage** (medium). Launch at login is enabled automatically on first run and can be changed from the
menu-bar gauge.

<details>
<summary>Prefer to run the steps yourself</summary>

```bash
brew install xcodegen
./scripts/configure.sh <TEAM_ID>   # generates local entitlements + the Xcode project
# Team ID: security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
open ClaudeUsage.xcodeproj         # ⌘R (or: make build)
```
</details>

### Verify the data layer without Xcode

```bash
make check        # or: swift run DataLayerCheck → "ALL CHECKS PASSED"
make live         # or: swift run DataLayerCheck --live (Claude CLI → parsed snapshot)
bash scripts/fetch_usage.sh        # same two CLI calls, printing only recognized fields/lines
```

## Repo layout

| Path | What |
|------|------|
| `Shared/` | Model, CLI subprocess client, parser, formatting, and snapshot store |
| `SharedUI/` | SwiftUI pieces shared by the menu-bar popover and widget |
| `ClaudeUsageApp/` | Background menu-bar agent, timer, notifications, and login item |
| `ClaudeUsageWidget/` | Sandboxed WidgetKit extension |
| `Tools/DataLayerCheck/` | Data-layer assertions that run with no Xcode project |
| `fixtures/` | Fabricated Claude CLI envelopes, prose, and auth status |
| `scripts/install.sh` | One-command configure/build/install/launch flow |
| `scripts/configure.sh` | Generates local entitlements and project with your Team ID |
| `scripts/fetch_usage.sh` | Bounded live CLI pipeline for debugging |
| `project.yml` | XcodeGen spec → `ClaudeUsage.xcodeproj` |

## Refresh behavior

- The agent refreshes automatically every 3 minutes and on demand when the menu opens or ↻ is
  tapped. Triggers are coalesced to at most one refresh per 20 seconds.
- Each refresh normally takes about **1.5–2 seconds** for `/usage`, plus roughly 0.2 seconds for auth
  status. The usage subprocess has a 30-second timeout; auth status has a 10-second timeout.
- `--strict-mcp-config` prevents configured MCP servers from connecting during a poll, and
  `--no-session-persistence` avoids writing a session transcript for every refresh.
- If auth status itself fails, the agent still attempts `/usage` with a generic `Claude` plan and no
  email. A confirmed signed-out status skips `/usage` and shows a fixed sign-in message.
- A failed or changed response never replaces good numbers: the prior snapshot is marked stale and
  the UI shows a fixed, non-sensitive error message.

**Launch at login.** The agent must be running for the widget to stay current, so its first launch
registers it as a login item. Keep the app in `/Applications`; `SMAppService` may refuse a DerivedData
or quarantined copy. Verify it with `pgrep -lf ClaudeUsage.app/Contents/MacOS/ClaudeUsage` or open the
menu-bar gauge and inspect the freshness row.

## Security

The app does not read Claude credentials and makes no direct usage request. It launches Claude Code
with a minimal environment allowlist, closes stdin, discards stderr, and persists only recognized
usage bars plus the plan label and account email. The snapshot directory is mode `0700`, and
`usage.json` is mode `0600`. Full details are in [SECURITY.md](SECURITY.md).

## Roadmap

- `systemSmall` polish and optional multi-account support.
- A signed, notarized release build so friends can install without Xcode.

## License

[MIT](LICENSE) © 2026 Andres Milioto. Not affiliated with Anthropic.
