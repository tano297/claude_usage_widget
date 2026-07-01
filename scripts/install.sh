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

# 3) Claude Code login (warn only — the app still installs). Do not use `-w` here; reading the
# secret just to test presence can trigger an unnecessary Keychain prompt from `/usr/bin/security`.
security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 \
  || warn "No Claude Code credentials in Keychain yet. Sign in with 'claude' or the widget will show 'not signed in'."

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
say "Installing to /Applications…"
pkill -f "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
sleep 1
rm -rf /Applications/ClaudeUsage.app
cp -R "$APP" /Applications/ClaudeUsage.app
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f /Applications/ClaudeUsage.app 2>/dev/null || true

# 8) Launch
say "Launching…"
open /Applications/ClaudeUsage.app

cat <<'EOF'

✓ Installed.  Finish up:
  1. Click "Always Allow" on the Keychain prompt (first run only).
  2. Open Notification Center (swipe left from the right edge, or click the clock)
     → scroll down → Edit Widgets → add "Claude Usage" (Medium).
  3. Click the menu-bar gauge icon → enable "Launch at login".
EOF
