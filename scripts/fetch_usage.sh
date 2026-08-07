#!/bin/bash
# Exercise the same two Claude CLI calls as the app and print only the auth fields and usage-bar
# lines the snapshot parser is allowed to consume. The analytics section is intentionally dropped.
set -euo pipefail

find_claude() {
  local candidate directory
  if [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then
    printf '%s\n' "$CLAUDE_BIN"
    return 0
  fi
  for candidate in \
    "$HOME/.local/bin/claude" \
    "$HOME/.npm-global/bin/claude" \
    "$HOME/.bun/bin/claude" \
    "$HOME/.volta/bin/claude" \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  while IFS= read -r directory; do
    [ -n "$directory" ] || continue
    candidate="$directory/claude"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(printf '%s' "${PATH:-}" | tr ':' '\n')
  return 1
}

# macOS has no built-in `timeout`; Perl's alarm gives each plain subprocess call the same bounded
# watchdog behavior without adding a package dependency.
run_with_timeout() {
  local seconds="$1"
  shift
  /usr/bin/perl -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV or exit 127' "$seconds" "$@"
}

CLAUDE="$(find_claude)" || {
  echo "error: Claude Code CLI not found. Install Claude Code, then retry." >&2
  exit 1
}

AUTH_JSON=""
set +e
AUTH_JSON="$(run_with_timeout 10 "$CLAUDE" auth status --json </dev/null 2>/dev/null)"
AUTH_EXIT=$?
set -e
if [ "$AUTH_EXIT" -ne 142 ] && \
   jq -e 'type == "object" and has("loggedIn")' >/dev/null 2>&1 <<<"$AUTH_JSON"; then
  if jq -e '.loggedIn == false' >/dev/null 2>&1 <<<"$AUTH_JSON"; then
    echo 'error: sign in with `claude`, then retry.' >&2
    exit 1
  fi
  EMAIL="$(jq -r 'select(.loggedIn == true) | .email // empty' <<<"$AUTH_JSON")"
  PLAN="$(jq -r 'select(.loggedIn == true) | .subscriptionType // empty' <<<"$AUTH_JSON")"
  [ -z "$EMAIL" ] || printf 'Account    : %s\n' "$EMAIL"
  [ -z "$PLAN" ] || printf 'Plan       : %s\n' "$PLAN"
fi

set +e
USAGE_JSON="$(run_with_timeout 30 "$CLAUDE" -p /usage --output-format json \
    --strict-mcp-config --no-session-persistence </dev/null 2>/dev/null)"
USAGE_EXIT=$?
set -e
if [ "$USAGE_EXIT" -eq 142 ] || [ -z "$USAGE_JSON" ]; then
    echo "error: Claude could not return usage before the timeout." >&2
    exit 1
fi

PROSE="$(jq -er '
  map(select(.type == "result"))[0]
  | select(.is_error == false and .subtype == "success")
  | .result
' <<<"$USAGE_JSON")" || {
  echo "error: Claude returned no successful usage result." >&2
  exit 1
}

LINES="$(grep -E \
  '^Current session: [0-9]+% used( (·|-) resets .+)?$|^Current week \(all models\): [0-9]+% used( (·|-) resets .+)?$|^Current week \(.+\): [0-9]+% used( (·|-) resets .+)?$' \
  <<<"$PROSE" || true)"
[ -n "$LINES" ] || {
  echo "error: Claude returned no recognized usage bars." >&2
  exit 1
}
printf '%s\n' "$LINES"
