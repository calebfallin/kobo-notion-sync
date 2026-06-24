#!/usr/bin/env bash
#
# uninstall.sh — remove the auto-sync LaunchAgent and the generated app.
# Does not touch your Notion data or kobo-sync.env.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.caleb.kobo-sync"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$DIR/KoboSync.app"

echo "Uninstalled. (If you want, remove the Full Disk Access entry for KoboSync.app manually.)"
