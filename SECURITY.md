# Security

## How your credentials are handled

This app displays your Claude usage, which requires your Anthropic account's OAuth token. Here is
exactly what it does with it:

- **Read locally.** The token is read from the macOS **Keychain** item `Claude Code-credentials`
  that Claude Code already created on your machine. macOS shows a one-time consent prompt the first
  time (you click *Always Allow*). See `Shared/UsageClient.swift` → `readClaudeCredentials()`.
- **Sent only to Anthropic.** The access token goes **only** to `https://api.anthropic.com/api/oauth/usage`
  (as a `Bearer` header — the endpoint Claude Code's `/usage` uses). Nothing is sent anywhere else.
- **Never written to disk in plaintext, never logged.** Tokens exist only in memory for the duration
  of a request. The only file persisted is the parsed usage snapshot (percentages, reset times, plan
  label, credit totals) at `~/Library/Application Support/ClaudeUsage/usage.json` — it contains **no
  token**. Grep the source: the access token is only interpolated into the `Authorization` header.
- **Never modifies Claude Code credentials.** The app does not refresh tokens, rewrite the
  Keychain item, or delete anything from Keychain. If the token expires, the widget shows a stale
  snapshot until Claude Code refreshes its own credential.
- **No telemetry, no network calls of our own.** There is no analytics, no third-party SDK, and no
  server. Everything runs on your Mac.

## Sandboxing

- The **widget** extension is sandboxed and holds only two entitlements: `app-sandbox` and a
  **read-only** exception for the single directory `~/Library/Application Support/ClaudeUsage/`. It
  has no network or Keychain access at all.
- The **agent** app is intentionally non-sandboxed because reading Claude Code's Keychain item
  requires it. It has no entitlements beyond that.

## Personal identifiers are not committed

Your Apple Team ID and absolute home path are injected locally by `scripts/configure.sh` into
generated files that are `.gitignore`d (`ClaudeUsageWidget.entitlements`, `ClaudeUsage.xcodeproj`).
The committed sources contain only placeholders.

## Unofficial / undocumented endpoint

`/api/oauth/usage` is **not a documented, supported API**. It may change or break at any time, and
this project is **not affiliated with or endorsed by Anthropic**. Use at your own risk.

## Reporting a vulnerability

Please open a GitHub issue, or for anything sensitive, contact the maintainer privately rather than
filing a public issue.
