#!/bin/bash
# Fetch live Claude usage using the Claude Code OAuth token from the macOS Keychain.
# This is the exact call the widget's agent makes, in shell form — handy for validating the
# data layer without building the app. Prints a compact summary plus the raw JSON with --raw.
set -euo pipefail

RAW=0
[[ "${1:-}" == "--raw" ]] && RAW=1

CREDS="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
if [[ -z "$CREDS" ]]; then
  echo "error: no 'Claude Code-credentials' item in Keychain. Sign in with: claude" >&2
  exit 1
fi

TOKEN="$(jq -r '.claudeAiOauth.accessToken' <<<"$CREDS")"
TIER="$(jq -r '.claudeAiOauth.rateLimitTier // "unknown"' <<<"$CREDS")"
VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
UA="claude-code/${VER:-2.1.0}"

BODY="$(curl -sS https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "User-Agent: ${UA}" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json")"

if [[ "$RAW" == "1" ]]; then
  echo "$BODY" | jq .
  exit 0
fi

echo "Plan tier : ${TIER}"
jq -r '
  def pct(w): if w == null or w.utilization == null then "—" else "\(w.utilization|floor)%" end;
  def reset(w): if w == null then "—" else (w.resets_at // "—") end;
  "Session   : \(pct(.five_hour))  · resets \(reset(.five_hour))",
  "Weekly    : \(pct(.seven_day))  · resets \(reset(.seven_day))",
  "Opus wk   : \(pct(.seven_day_opus))",
  "Credits   : \(if (.spend.enabled // false) then "\((.spend.used.amount_minor // 0)/100) / \((.spend.limit.amount_minor // 0)/100) \(.spend.limit.currency // "USD")" else "disabled" end)"
' <<<"$BODY"
