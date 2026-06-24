#!/usr/bin/env bash
#
# install.sh — set up the Kobo → Notion auto-sync on this Mac.
#
#   1. builds the KoboSync.app wrapper (so macOS can grant it Full Disk Access)
#   2. installs a LaunchAgent that runs it whenever a volume is mounted
#   3. (re)loads the agent
#
# Prereqs: macOS, jq (`brew install jq`), and a filled-in kobo-sync.env.
# Re-running is safe (idempotent).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.caleb.kobo-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$DIR/KoboSync.app"
SCRIPT="$DIR/sync-kobo-highlights.sh"
UID_="$(id -u)"

command -v jq >/dev/null 2>&1 || {
	echo "error: jq not found — install it with: brew install jq" >&2
	exit 1
}
if [ ! -f "$DIR/kobo-sync.env" ]; then
	echo "error: kobo-sync.env not found." >&2
	echo "  cp kobo-sync.env.example kobo-sync.env   and fill in the webhook URL + secret." >&2
	exit 1
fi
chmod +x "$SCRIPT"

echo "Building KoboSync.app…"
rm -rf "$APP"
osacompile -o "$APP" \
	-e 'try' \
	-e "do shell script \"$SCRIPT --watch\"" \
	-e 'end try'

echo "Writing LaunchAgent → $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/applet</string>
	</array>
	<key>StartOnMount</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$DIR/sync.log</string>
	<key>StandardErrorPath</key>
	<string>$DIR/sync.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
	</dict>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
</dict>
</plist>
EOF

echo "Loading agent…"
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"

cat <<EOF

✅ Installed.

ONE manual step (required once): grant Full Disk Access to the app, so the
background job is allowed to read the Kobo's removable volume —

  System Settings → Privacy & Security → Full Disk Access → "+"  →  select:
    $APP

Then plug in your Kobo. Watch it work with:
  tail -f "$DIR/sync.log"

Run a sync by hand anytime with:
  "$SCRIPT"
EOF
