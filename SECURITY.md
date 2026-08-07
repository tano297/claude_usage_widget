# Security

## Authentication boundary

The app never reads, receives, stores, or refreshes a Claude credential. Instead, the non-sandboxed
menu-bar agent launches the installed Claude Code CLI for two bounded calls:

1. `claude auth status --json` supplies login state, account email, and plan type.
2. `claude -p /usage --output-format json --strict-mcp-config --no-session-persistence` asks Claude
   Code to fetch and render its own usage panel.

Claude Code handles authentication and its vendor network request. The app makes no direct HTTP
request and adds no telemetry.

The child process receives a replacement environment containing only basic identity, home,
temporary-directory, locale, Claude/XDG config locations, proxy settings, and TLS certificate
locations. `PATH` is rebuilt from the explicit Claude discovery directories plus `/usr/bin:/bin`,
and `NO_COLOR=1` is forced. Arbitrary API keys and unrelated parent-process secrets are not passed.
The child's stdin is closed, stderr is discarded, and each call is terminated at its deadline.

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

The only persisted file is
`~/Library/Application Support/ClaudeUsage/usage.json`. It contains parsed percentages, reset times,
model-scope names from recognized bar lines, the plan label, and the **account email**. It contains no
credential or analytics block. The directory is restricted to mode `0700` and the file to `0600`.

## Sandboxing

- The **widget** extension remains sandboxed. It has no network access and only a read-only path
  exception for `~/Library/Application Support/ClaudeUsage/`; it renders the agent's snapshot.
- The **agent** is intentionally non-sandboxed so macOS permits it to launch the Claude CLI. It
  carries no sandbox or credential entitlement.

## Personal identifiers are not committed

Apple Team IDs and absolute home paths are injected locally by `scripts/configure.sh` into ignored,
generated files. Committed fixtures and documentation use invented values such as
`user@example.com`; no real account email, organization identifier, or usage analytics belongs in
the repository.

## Undocumented interface and endpoint

Claude Code's `/usage` prose is not a documented, stable API and may change. The parser treats an
unrecognized response as a failure and retains the prior snapshot with a stale badge. Claude Code
currently makes the underlying undocumented Anthropic usage request; the app does not call that
endpoint itself. This project is not affiliated with or endorsed by Anthropic.

## Reporting a vulnerability

Please open a GitHub issue, or contact the maintainer privately for anything sensitive rather than
filing a public issue.
