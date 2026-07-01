#!/bin/bash
# One-time local setup before building. Generates a machine-specific widget entitlements file and
# regenerates the Xcode project with your Apple Team ID — neither of which is committed, so the
# repo stays free of personal identifiers.
#
#   ./scripts/configure.sh <TEAM_ID>
#   ./scripts/configure.sh ABCDE12345
#
# Find TEAM_ID in Xcode ▸ Settings ▸ Accounts (or run: security find-certificate -c
# "Apple Development" -p | openssl x509 -noout -subject  → the OU= field).
set -euo pipefail

TEAM="${1:?usage: configure.sh <TEAM_ID>}"
cd "$(dirname "$0")/.."

DIR="$HOME/Library/Application Support/ClaudeUsage"
TEMPLATE="ClaudeUsageWidget/ClaudeUsageWidget.entitlements.template"
ENT="ClaudeUsageWidget/ClaudeUsageWidget.entitlements"

# 1) Generate the widget's read-only sandbox exception for your real absolute path (gitignored).
sed "s#__CLAUDE_USAGE_DIR__#${DIR}#g" "$TEMPLATE" > "$ENT"

# 2) Regenerate the Xcode project with your team baked in via the env var project.yml references.
DEVELOPMENT_TEAM="$TEAM" xcodegen generate >/dev/null

echo "Configured (local, not committed):"
echo "  DEVELOPMENT_TEAM       = ${TEAM}"
echo "  Widget read exception  = ${DIR}/"
echo "  Generated              = ${ENT}, ClaudeUsage.xcodeproj"
echo
echo "Next:  open ClaudeUsage.xcodeproj   (or: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \\"
echo "         xcodebuild -scheme ClaudeUsage -allowProvisioningUpdates build)"
