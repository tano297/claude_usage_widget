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

The only persisted data file is
`~/Library/Application Support/ClaudeUsage/usage.json`. It contains parsed percentages, reset times,
model-scope names from recognized bar lines, the plan label, the **account email**, and optional
credit totals. It contains no credential, endpoint junk fields, or analytics block. The directory is
restricted to mode `0700` and the file to `0600`.

## Sandboxing

- The **widget** extension remains sandboxed. It has no network access and only a read-only path
  exception for `~/Library/Application Support/ClaudeUsage/`; it renders the agent's snapshot.
- The **agent** is intentionally non-sandboxed so macOS permits it to launch the Claude CLI and the
  fixed `/usr/bin/security` credits read. It carries no sandbox or credential entitlement.

## Personal identifiers are not committed

Apple Team IDs and absolute home paths are injected locally by `scripts/configure.sh` into ignored,
generated files. Committed fixtures and documentation use invented values such as
`user@example.com`; no real account email, organization identifier, or usage analytics belongs in
the repository.

## Undocumented interface and endpoint

Claude Code's `/usage` prose and Anthropic's `/api/oauth/usage` endpoint are not documented, stable
interfaces and may change. The prose parser treats an unrecognized response as a primary failure and
retains the prior snapshot with a stale badge; the isolated endpoint supplement simply omits credits
or opens its breaker. This project is not affiliated with or endorsed by Anthropic.

## Reporting a vulnerability

Please open a GitHub issue, or contact the maintainer privately for anything sensitive rather than
filing a public issue.
