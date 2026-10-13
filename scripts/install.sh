#!/bin/bash
# One-command installer for the Claude Usage widget: checks prerequisites, auto-detects your Apple
# Team ID, generates the project, builds, installs to /Applications, and launches it.
#
#   ./scripts/install.sh              # auto-detect Team ID
#   ./scripts/install.sh <TEAM_ID>    # or pass it explicitly
set -euo pipefail
cd "$(dirname "$0")/.."

say()  { printf "\033[1;36m▸ %s\033[0m\n" "$1"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$1"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# 1) macOS + Xcode.app
[ "$(uname)" = "Darwin" ] || die "macOS only."
XCODE="/Applications/Xcode.app"
[ -d "$XCODE" ] || die "Xcode.app not found. Install it from the App Store (open 'macappstore://apps.apple.com/app/id497799835'), open it once, then re-run."
DEV="$XCODE/Contents/Developer"

# 2) XcodeGen
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Need XcodeGen. Install Homebrew (https://brew.sh) then: brew install xcodegen"
  say "Installing XcodeGen…"; brew install xcodegen
fi

# 3) Claude Code CLI (warn only — the app still installs). Match the app's discovery order so a
# GUI launch and this installer agree even when the user's shell PATH is unavailable.
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

CLAUDE_PATH="$(find_claude || true)"
if [ -n "$CLAUDE_PATH" ]; then
  say "Claude Code CLI: $CLAUDE_PATH"
else
  warn "Claude Code CLI not found. Install Claude Code and sign in with 'claude' before using the widget."
fi

# 4) Team ID: arg, else auto-detect from your Apple Development certificate
TEAM="${1:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt sep_multiline,utf8 2>/dev/null \
        | awk -F= '/OU=/{gsub(/ /,"",$2); print $2; exit}')
fi
[ -n "$TEAM" ] || die "No Apple Team ID found. Sign in to Xcode (Settings ▸ Accounts) to get a free Personal Team, then re-run — or pass it: ./scripts/install.sh <TEAM_ID>"
say "Team ID: $TEAM"

# 5) Generate entitlements + project
./scripts/configure.sh "$TEAM" >/dev/null
say "Configured project."

# 6) Build
say "Building (first build downloads/creates a signing profile)…"
LOG="$(mktemp -t claudeusage_build.XXXX.log)"
if ! DEVELOPER_DIR="$DEV" xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage \
      -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates build \
      >"$LOG" 2>&1; then
  tail -30 "$LOG"; die "Build failed — full log: $LOG"
fi

# 7) Locate the built app and install to /Applications
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -name ClaudeUsage.app \
        -path "*/Build/Products/Debug/*" 2>/dev/null | head -1)
[ -n "$APP" ] || die "Could not locate the built ClaudeUsage.app."
DERIVED_APPEX="$APP/Contents/PlugIns/ClaudeUsageWidget.appex"
INSTALLED_APPEX="/Applications/ClaudeUsage.app/Contents/PlugIns/ClaudeUsageWidget.appex"
say "Installing to /Applications…"
# The widget process keeps the previous binary mapped if only the menu-bar app is killed.
pkill -f "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
pkill -f "/Applications/ClaudeUsage.app/Contents/PlugIns/ClaudeUsageWidget.appex" 2>/dev/null || true
sleep 1
rm -rf /Applications/ClaudeUsage.app
cp -R "$APP" /Applications/ClaudeUsage.app

# xcodebuild also registers the DerivedData copy and elects this extension for the debugger.
# chronod then hides both widgets and drops the ones already on the desktop.
# These are best effort: the app is already in place, so a pluginkit miss must not stop the launch.
[ -d "$DERIVED_APPEX" ] && pluginkit -r "$DERIVED_APPEX" 2>/dev/null || true
pluginkit -a "$INSTALLED_APPEX" 2>/dev/null || true
pluginkit -e use -i com.claudeusage.app.ClaudeUsageWidget 2>/dev/null || true
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f /Applications/ClaudeUsage.app 2>/dev/null || true
pluginkit -e use -i com.claudeusage.app.ClaudeUsageWidget 2>/dev/null || true

# 8) Launch. chronod keeps the previous widget list until it is restarted.
say "Refreshing widgets (restarts chronod, the macOS widget service; it comes back on its own)…"
killall chronod 2>/dev/null || true
sleep 1
say "Launching…"
open /Applications/ClaudeUsage.app
sleep 1
pluginkit -e use -i com.claudeusage.app.ClaudeUsageWidget 2>/dev/null || true
pluginkit -m -i com.claudeusage.app.ClaudeUsageWidget || true

cat <<'EOF'

✓ Installed. Add the widgets from the desktop:
  1. Right-click the desktop and choose Edit Widgets.
  2. Search for Claude Usage.
  3. Add Current sub (small or medium).
  4. Add All subs (large) and place it under Current sub.
Launch at login is enabled automatically on first run and can be changed from the menu bar.
EOF
