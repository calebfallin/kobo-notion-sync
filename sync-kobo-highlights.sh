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

# ---- backup: a timestamped, self-contained copy of the Kobo DB --------------
# This DB is the ONLY copy of every highlight + reading position you own — if the
# Kobo is lost, reset, or dies, it's gone. So stash a dated copy on every sync.
# VACUUM INTO writes a single consolidated file (WAL applied) that restores by
# copying it back into the device's .kobo/ folder. Set KOBO_BACKUP=0 to skip.
if [ "${KOBO_BACKUP:-1}" = "1" ]; then
	BACKUP_DIR="$SCRIPT_DIR/backups"
	mkdir -p "$BACKUP_DIR"
	BACKUP_DEST="$BACKUP_DIR/KoboReader-$(date '+%Y%m%d-%H%M%S').sqlite"
	if sqlite3 "$TMPDB" "VACUUM INTO '$BACKUP_DEST';" 2>/dev/null || cp "$TMPDB" "$BACKUP_DEST"; then
		echo "Backed up Kobo DB → backups/$(basename "$BACKUP_DEST")"
	else
		echo "warning: Kobo DB backup failed (continuing)."
	fi
	# Keep only the most recent KOBO_BACKUP_KEEP backups (0 = keep all).
	BACKUP_KEEP="${KOBO_BACKUP_KEEP:-30}"
	if [ "$BACKUP_KEEP" -gt 0 ]; then
		ls -1t "$BACKUP_DIR"/KoboReader-*.sqlite 2>/dev/null \
			| tail -n +$((BACKUP_KEEP + 1)) \
			| while IFS= read -r old; do rm -f "$old"; done || true
	fi
fi

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
  -- Only books actually downloaded to the device. Skips Kobo store
  -- recommendations/previews (IsDownloaded='false'), which otherwise leak
  -- into Notion as phantom book pages you never opened.
  AND IsDownloaded = 'true'
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

# ---- sideload: copy new books from inbox/ onto the Kobo ---------------------
# Drop ebooks into ./inbox and they get copied onto the device on the next sync,
# then archived to ./inbox/sent. Plain EPUBs are converted to Kobo's enhanced
# KEPUB format when `kepubify` is installed (better progress/stats — the very
# data this sync reads); otherwise they're copied as-is. The run always ends by
# ejecting (see finish_and_notify), so a sideloaded book imports when you unplug.
INBOX_DIR="$SCRIPT_DIR/inbox"
SENT_DIR="$INBOX_DIR/sent"
AUTO_EJECT="${KOBO_AUTO_EJECT:-1}"
# Sound played with the "safe to unplug" banner. Unset → "Glass"; set empty to
# silence (KOBO_NOTIFY_SOUND="" in kobo-sync.env). Any name from /System/Library/Sounds.
NOTIFY_SOUND="${KOBO_NOTIFY_SOUND-Glass}"
# Formats the Kobo reads directly (lowercase extensions, no leading dot).
KOBO_NATIVE_EXTS="epub pdf cbz cbr txt html htm rtf fb2 djvu"

SIDELOAD_COPIED=0
SIDELOAD_FAILED=0

sideload_books() {
	SIDELOAD_COPIED=0
	SIDELOAD_FAILED=0
	[ -d "$INBOX_DIR" ] || return 0

	# Top-level files only — skip the sent/ archive, subdirs, and dotfiles.
	shopt -s nullglob
	local entries=("$INBOX_DIR"/*)
	shopt -u nullglob
	local candidates=() f
	for f in "${entries[@]}"; do
		[ -f "$f" ] && candidates+=("$f")
	done
	[ "${#candidates[@]}" -gt 0 ] || return 0

	echo "Sideloading ${#candidates[@]} file(s) from inbox/ …"
	mkdir -p "$SENT_DIR"
	local have_kepubify=0
	command -v kepubify >/dev/null 2>&1 && have_kepubify=1

	local base lower ext
	for f in "${candidates[@]}"; do
		base="$(basename "$f")"
		lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
		ext="${lower##*.}"

		# Already a KEPUB → copy as-is.
		case "$lower" in
		*.kepub.epub)
			if cp "$f" "$KOBO_MOUNT/$base"; then
				mv "$f" "$SENT_DIR/"; echo "  ✓ $base (kepub)"; SIDELOAD_COPIED=$((SIDELOAD_COPIED + 1))
			else
				echo "  ✗ $base — copy failed"; SIDELOAD_FAILED=$((SIDELOAD_FAILED + 1))
			fi
			continue
			;;
		esac

		# Plain EPUB → convert to KEPUB when we can, else copy as-is.
		if [ "$ext" = "epub" ] && [ "$have_kepubify" = "1" ]; then
			# -o <existing dir> writes "<name>.kepub.epub" there; -i drops the
			# "_converted" suffix (safe: output dir differs from inbox/).
			if kepubify -i -o "$KOBO_MOUNT" "$f" >/dev/null 2>&1; then
				mv "$f" "$SENT_DIR/"; echo "  ✓ $base → kepub"; SIDELOAD_COPIED=$((SIDELOAD_COPIED + 1))
			else
				echo "  ✗ $base — kepubify failed (left in inbox/)"; SIDELOAD_FAILED=$((SIDELOAD_FAILED + 1))
			fi
			continue
		fi

		# Other natively-readable formats (incl. plain EPUB with no kepubify) → copy.
		if printf '%s\n' $KOBO_NATIVE_EXTS | grep -qx "$ext"; then
			if cp "$f" "$KOBO_MOUNT/$base"; then
				mv "$f" "$SENT_DIR/"; echo "  ✓ $base"; SIDELOAD_COPIED=$((SIDELOAD_COPIED + 1))
			else
				echo "  ✗ $base — copy failed"; SIDELOAD_FAILED=$((SIDELOAD_FAILED + 1))
			fi
			continue
		fi

		# Unsupported (mobi/azw/azw3/kfx/…): the Kobo can't read these.
		echo "  ⤬ $base — .$ext isn't read by Kobo; convert to EPUB first (left in inbox/)"
		SIDELOAD_FAILED=$((SIDELOAD_FAILED + 1))
	done

	echo "Sideload: $SIDELOAD_COPIED copied, $SIDELOAD_FAILED skipped/failed."
}

notify() {
	# notify <title> <message> — best-effort macOS banner; never fails the run.
	# Messages are built from counts only (no user text), so no escaping worries.
	local snd=""
	[ -n "${NOTIFY_SOUND:-}" ] && snd=" sound name \"$NOTIFY_SOUND\""
	osascript -e "display notification \"$2\" with title \"$1\"$snd" >/dev/null 2>&1 || true
}

# Eject the Kobo (so it's safe to physically remove) and pop a notification
# summarizing the run. Called once at the end of every successful detection.
#   finish_and_notify <notion_synced> <notion_failed>
finish_and_notify() {
	local synced="$1" sync_failed="$2"
	local added="${SIDELOAD_COPIED:-0}"
	local sl_failed="${SIDELOAD_FAILED:-0}"
	local errors=$((sync_failed + sl_failed))

	# Short body line for the banner.
	local summary="$synced book(s) synced"
	[ "$added" -gt 0 ] && summary="$summary · $added added to Kobo"
	[ "$errors" -gt 0 ] && summary="$summary · $errors failed (see sync.log)"

	if [ "$AUTO_EJECT" != "1" ]; then
		echo "$summary (auto-eject off — unmount the Kobo yourself before unplugging)."
		notify "Kobo sync done" "$summary"
		return 0
	fi

	echo "Ejecting ${KOBO_MOUNT}…"
	if diskutil eject "$KOBO_MOUNT" >/dev/null 2>&1; then
		echo "Ejected — safe to unplug."
		if [ "$errors" -gt 0 ]; then
			notify "Kobo synced with errors — safe to unplug" "$summary"
		else
			notify "Kobo synced — safe to unplug ✅" "$summary"
		fi
	else
		echo "Couldn't eject $KOBO_MOUNT automatically."
		notify "Kobo sync done — eject failed" "$summary · unmount it yourself before unplugging"
	fi
}

COUNT="$(printf '%s' "$BOOKS" | jq 'length')"
if [ "$COUNT" = "0" ]; then
	echo "No books found on the Kobo. Nothing to sync to Notion."
	sideload_books
	finish_and_notify 0 0
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

# Then push books the other way: inbox/ → Kobo.
sideload_books

# Eject + notify so it's safe to unplug (always, not just when books were added).
finish_and_notify "$ok" "$failed"

# Succeed only if both halves were clean.
[ "$failed" = "0" ] && [ "${SIDELOAD_FAILED:-0}" = "0" ]
