#!/usr/bin/env bash
#
# sync-kobo-highlights.sh
# -----------------------
# Reads highlights from a USB-connected Kobo e-reader and pushes them to the
# Notion `koboSync` worker webhook — one POST per book, each carrying that book's
# *complete current* highlight set. The worker upserts a page per book in the
# Books database and rebuilds its highlights, so adds, edits, and deletes all
# sync correctly just by running this again.
#
# Usage:
#   1. Plug the Kobo into this Mac (it mounts at /Volumes/KOBOeReader).
#   2. ./sync-kobo-highlights.sh
#
# Config (webhook URL + secret) is read from `kobo-sync.env` next to this
# script, or from the environment. See kobo-sync.env.example.
#
# Dependencies: sqlite3, jq, curl — all preinstalled on macOS except jq.

set -euo pipefail

# launchd StartOnMount jobs don't inherit your shell PATH; set an explicit one.
# All required tools ship in /usr/bin on macOS (Homebrew paths added just in case).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The LaunchAgent passes --watch on every mount event: retry briefly so the
# just-mounted volume can settle, and exit quietly when it isn't the Kobo.
WATCH_MODE=0
[ "${1:-}" = "--watch" ] && WATCH_MODE=1

# In watch mode (LaunchAgent / app wrapper), append all output to the log file
# directly, so logging works no matter how we're invoked.
if [ "$WATCH_MODE" = "1" ]; then
	exec >> "$SCRIPT_DIR/sync.log" 2>&1
fi

# ---- config -----------------------------------------------------------------
if [ -f "$SCRIPT_DIR/kobo-sync.env" ]; then
	# shellcheck disable=SC1091
	. "$SCRIPT_DIR/kobo-sync.env"
fi

WEBHOOK_URL="${KOBO_WEBHOOK_URL:-}"
WEBHOOK_SECRET="${KOBO_SYNC_SECRET:-}"

fail() { echo "error: $*" >&2; exit 1; }

# ---- locate the Kobo --------------------------------------------------------
KOBO_MOUNT_CFG="${KOBO_MOUNT:-/Volumes/KOBOeReader}"
KOBO_MOUNT=""
DB_PATH=""
find_kobo() {
	for v in "$KOBO_MOUNT_CFG" /Volumes/KOBO* /Volumes/kobo*; do
		if [ -f "$v/.kobo/KoboReader.sqlite" ]; then
			KOBO_MOUNT="$v"
			DB_PATH="$v/.kobo/KoboReader.sqlite"
			return 0
		fi
	done
	return 1
}

echo "=== $(date '+%Y-%m-%d %H:%M:%S') kobo-sync (watch=$WATCH_MODE) ==="

if ! find_kobo; then
	if [ "$WATCH_MODE" = "1" ]; then
		tries=0
		until find_kobo; do
			tries=$((tries + 1))
			if [ "$tries" -ge 8 ]; then
				echo "No Kobo on this mount event — skipping."
				exit 0
			fi
			sleep 1
		done
	else
		fail "No Kobo found. Plug it in and unlock it, then retry. (looked for /Volumes/KOBOeReader/.kobo/KoboReader.sqlite)"
	fi
fi

# ---- preflight --------------------------------------------------------------
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found"
command -v jq >/dev/null 2>&1 || fail "jq not found (install with: brew install jq)"
command -v curl >/dev/null 2>&1 || fail "curl not found"
[ -n "$WEBHOOK_URL" ] || fail "KOBO_WEBHOOK_URL is not set (see kobo-sync.env)"
[ -n "$WEBHOOK_SECRET" ] || fail "KOBO_SYNC_SECRET is not set (see kobo-sync.env)"

echo "Kobo found at $KOBO_MOUNT"

# ---- snapshot the database (incl. WAL) so we never read the live file --------
TMPDB="$(mktemp -t koboreader)"
trap 'rm -f "$TMPDB" "$TMPDB-wal" "$TMPDB-shm"' EXIT
cp "$DB_PATH" "$TMPDB"
[ -f "$DB_PATH-wal" ] && cp "$DB_PATH-wal" "$TMPDB-wal" || true
[ -f "$DB_PATH-shm" ] && cp "$DB_PATH-shm" "$TMPDB-shm" || true

# ---- extract every book + its highlights ------------------------------------
# Books: every ContentType=6 row in `content` (read status, progress, series…).
read -r -d '' BOOKS_SQL <<'EOF' || true
SELECT
  ContentID      AS volumeId,
  Title          AS title,
  Attribution    AS author,
  ReadStatus     AS readStatus,
  ___PercentRead AS percentRead,
  DateLastRead   AS dateLastRead,
  Series         AS series,
  SeriesNumber   AS seriesNumber
FROM content
WHERE ContentType = 6
ORDER BY Title;
EOF

# Highlights: Bookmark rows joined to `content` for the chapter title.
read -r -d '' HL_SQL <<'EOF' || true
SELECT
  b.VolumeID    AS volumeId,
  b.BookmarkID  AS id,
  b.Text        AS text,
  b.Annotation  AS note,
  ch.Title      AS chapter,
  b.DateCreated AS createdAt
FROM Bookmark b
LEFT JOIN content ch ON ch.ContentID = b.ContentID
WHERE b.Text IS NOT NULL AND TRIM(b.Text) <> ''
ORDER BY b.VolumeID, b.ChapterProgress, b.StartContainerPath, b.DateCreated;
EOF

BOOKS_RAW="$(sqlite3 -json "$TMPDB" "$BOOKS_SQL" 2>/dev/null || true)"; BOOKS_RAW="${BOOKS_RAW:-[]}"
HL_RAW="$(sqlite3 -json "$TMPDB" "$HL_SQL" 2>/dev/null || true)"; HL_RAW="${HL_RAW:-[]}"

# ---- merge: attach each book's highlights -----------------------------------
BOOKS="$(jq -nc --argjson books "$BOOKS_RAW" --argjson hls "$HL_RAW" '
	($hls | group_by(.volumeId)
	      | map({ key: .[0].volumeId, value: . })
	      | from_entries) as $byVol
	| $books
	| map(. + {
		highlights: (($byVol[.volumeId] // [])
			| map({
				id: (.id | tostring),
				text: .text,
				note: .note,
				chapter: .chapter,
				createdAt: .createdAt
			}))
	})')"

COUNT="$(printf '%s' "$BOOKS" | jq 'length')"
if [ "$COUNT" = "0" ]; then
	echo "No books found on the Kobo. Nothing to sync."
	exit 0
fi
HLBOOKS="$(printf '%s' "$BOOKS" | jq '[.[] | select(.highlights | length > 0)] | length')"
echo "Found $COUNT book(s), $HLBOOKS with highlights. Syncing to Notion…"

# ---- POST each book to the webhook ------------------------------------------
ok=0; failed=0
while IFS= read -r book; do
	btitle="$(printf '%s' "$book" | jq -r '.title')"
	n="$(printf '%s' "$book" | jq '.highlights | length')"
	code="$(printf '%s' "$book" | curl -s -o /dev/null -w '%{http_code}' \
		--max-time 120 \
		-X POST "$WEBHOOK_URL" \
		-H "Content-Type: application/json" \
		-H "X-Kobo-Sync-Secret: $WEBHOOK_SECRET" \
		--data-binary @-)"
	if [ "$n" -gt 0 ]; then hl=" ($n highlights)"; else hl=""; fi
	if [ "${code:0:1}" = "2" ]; then
		printf '  ✓ %s%s\n' "$btitle" "$hl"
		ok=$((ok + 1))
	else
		printf '  ✗ %s%s — HTTP %s\n' "$btitle" "$hl" "$code"
		failed=$((failed + 1))
	fi
done < <(printf '%s' "$BOOKS" | jq -c '.[]')

echo "Done. $ok synced, $failed failed."
[ "$failed" = "0" ]
