# Security

## Authentication boundary

The primary bars/email pipeline never reads, receives, stores, or refreshes a Claude credential.
Instead, the non-sandboxed menu-bar agent launches the installed Claude Code CLI for two bounded
calls:

1. `claude auth status --json` supplies login state, account email, and plan type.
2. `claude -p /usage --output-format json --strict-mcp-config --no-session-persistence` asks Claude
   Code to fetch and render its own usage panel.

Claude Code handles authentication and the primary vendor network request. The app adds no
telemetry.

The child process receives a replacement environment containing only basic identity, home,
temporary-directory, locale, Claude/XDG config locations, proxy settings, and TLS certificate
locations. `PATH` is rebuilt from the explicit Claude discovery directories plus `/usr/bin:/bin`,
and `NO_COLOR=1` is forced. Arbitrary API keys and unrelated parent-process secrets are not passed.
The child's stdin is closed, stderr is discarded, and each call is terminated at its deadline.

Extra subscriptions use a separate browser sign-in, described under Other subscriptions. That path
does not replace these two CLI calls, and a roster failure cannot mark this snapshot stale or
change its error.

## Supplemental usage-credits token handling

Usage credits are a deliberately isolated, user-controlled supplement because Claude Code's
`/usage` prose does not expose them. When **Show usage credits** is enabled, the agent:

1. Spawns exactly `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` with
   stdin closed, stderr discarded, only `HOME`/`USER` in its environment, and a four-second
   termination deadline.
2. Decodes only `claudeAiOauth.accessToken` from stdout. The token exists only in a local in-memory
   value, is never logged or placed in an error, and is never persisted in `usage.json` or defaults.
3. Sends it only as a bearer token to `https://api.anthropic.com/api/oauth/usage`, with a 15-second
   request timeout. The app does not refresh, rewrite, or delete Claude Code's credential.

Today this read is promptless because Claude Code creates the Keychain item through
`/usr/bin/security` and its ACL trusts that binary. Anthropic has said it will harden this surface,
so this is a deliberate user-chosen tradeoff rather than a promised integration. A failed,
malformed, empty, or timed-out Keychain read permanently auto-disables future credits fetches until
the user explicitly turns the menu option back on. HTTP 403 does the same. Only a fixed short reason
is stored in `UserDefaults`; raw stdout/stderr and response content are not.

Any non-instant credential read trips the breaker — including one the user approves. A promptless
read returns in about ten milliseconds, so a `security` call that exits 0 only after more than a
second means a dialog was shown and answered; that output is discarded exactly like a failure and
the breaker opens. The guaranteed worst case is therefore one password dialog, ever: it is never
shown twice. HTTP 401 (including a token mid-refresh), HTTP 429, server errors, malformed endpoint
data, and network failures hide credits only for the current cycle and do not trip it. No credits
outcome can mark the primary snapshot stale or alter its error.

## Output and persistence boundary

Auth decoding consumes only `loggedIn`, `email`, and `subscriptionType`. Organization identifiers,
organization names, auth method, provider details, and unknown fields are ignored.

The `/usage` result is scanned line by line. Only these exact data shapes may enter a snapshot:

- `Current session: <integer>% used` with an optional reset suffix
- `Current week (all models): <integer>% used` with an optional reset suffix
- `Current week (<name>): <integer>% used` with an optional reset suffix

Every other line is discarded. In particular, request counts and skill, subagent, plugin, or MCP
server names from the “What's contributing” analytics block are never persisted. Raw CLI output is
also never logged or included in an error; user-facing failures are fixed strings.

The CLI snapshot file is
`~/Library/Application Support/ClaudeUsage/usage.json`. It contains parsed percentages, reset times,
model-scope names from recognized bar lines, the plan label, the **account email**, and optional
credit totals. It contains no credential, endpoint junk fields, or analytics block. The directory is
restricted to mode `0700` and the file to `0600`. A second file, `roster.json`, lives in that same
directory and is described below. Neither file contains a token.

## Sandboxing

- The **widget** extension remains sandboxed. It has no network access and only a read-only path
  exception for `~/Library/Application Support/ClaudeUsage/`. That directory holds `usage.json` and
  `roster.json`. The widget reads both and does not read the Keychain.
- The **agent** is intentionally non-sandboxed so macOS permits it to launch the Claude CLI, open
  the sign-in browser, and run the fixed `/usr/bin/security` credits read. It carries no sandbox or
  credential entitlement.

## Other subscriptions

Accounts besides the Claude Code login are a separate pipeline. Open in the menu signs each one in
through the browser. By default that is a private Chrome window. A Chrome profile can be picked
instead in the Subscriptions window; it opens a normal window, so that profile's saved logins are
available. To list the profiles, the app reads only the folder and display names from Chrome's
`Local State` file. Without Chrome, the default browser opens.

**Sign-in uses Claude Code's OAuth client.** This app has no OAuth client of its own. It sends
Claude Code's public client ID to `https://claude.ai/oauth/authorize`, so the consent page names
Claude Code, not this app, and it redeems the code at `https://console.anthropic.com/v1/oauth/token`.
Anthropic's [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) page says
OAuth authentication "is designed to support ordinary use of Claude Code and other native Anthropic
applications", that "Anthropic does not permit third-party developers to offer Claude.ai login into
their own applications", and that developers "may not collect, store, or intermediate Claude.ai
credentials or session tokens". This feature stores a refresh token, and Anthropic can block the
flow at any time. The app requests only the `user:profile` scope and only reads usage. Using this
feature is your decision; nothing else in the app needs it.

The redirect is a localhost callback on port 1456, or 1458 when 1456 is taken. The listener binds
`127.0.0.1`, and `::1` when that is free. It accepts only `GET /callback` with this sign-in's
`state`, once. Any other request gets 404, and the sign-in keeps waiting. The code exchange uses
PKCE (S256), so a code that another local process sees cannot be redeemed without the verifier,
which never leaves the app.

The app stores only that account's refresh token, in the login Keychain under the service
`com.claudeusage.app.roster`, with the account set to the row's UUID and the label
`Claude Usage: <email>`. The token is not written to `roster.json`, `usage.json`, or UserDefaults,
and it is not logged or copied into an error string. At launch the app turns off Keychain dialogs
for its own process, so a Keychain call that would need a dialog fails instead. That happens when
the login keychain is locked, or when the item was created by a build signed differently, for
example by another team or from a fork. The row then says "Keychain locked or blocked" and keeps its
last meters. Unlock the Mac; for a differently signed build, add the account again, which replaces
the item.

Removing a row deletes its Keychain item. It does not revoke the token at Anthropic. If
`roster.json` is lost, its Keychain items stay until you delete them in Keychain Access.

`roster.json` holds, for each row, an id, the email, the 5-hour and weekly meters, the time of the
last reading, a stale flag, and a fixed error string. The directory stays mode `0700` and the file
mode `0600`.

The agent exchanges the refresh token for a short-lived access token when it has none or the one it
has is about to expire. When the token endpoint returns a new refresh token, the agent saves it
before it reads usage. The access token stays in memory only, until a minute before it expires, and
is used for `GET https://api.anthropic.com/api/oauth/usage`. These requests refuse redirects, so the
bearer token is not sent to another address. A roster miss leaves the last meters in place with a
stale mark. It does not mark the CLI snapshot stale and does not change the CLI snapshot's error.
These accounts are only read for meters. The app does not send inference as them.

## Personal identifiers are not committed

Apple Team IDs and absolute home paths are injected locally by `scripts/configure.sh` into ignored,
generated files. Committed fixtures and documentation use invented values such as
`user@example.com`; no real account email, organization identifier, or usage analytics belongs in
the repository.

## Undocumented interface and endpoint

Claude Code's `/usage` prose and Anthropic's `/api/oauth/usage` endpoint are not documented, stable
interfaces and may change. The prose parser treats an unrecognized response as a primary failure and
retains the prior snapshot with a stale badge; the isolated endpoint supplement simply omits credits
or opens its breaker. The roster uses that same usage endpoint with a refresh token from the browser
sign-in, through Claude Code's OAuth client. A roster failure keeps the last roster meters and does
not affect the CLI snapshot. This project is not affiliated with or endorsed by Anthropic.

## Reporting a vulnerability

Please open a GitHub issue, or contact the maintainer privately for anything sensitive rather than
filing a public issue.
