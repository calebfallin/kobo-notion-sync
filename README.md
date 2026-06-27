# Kobo → Notion sync

Syncs **every book** on a Kobo e-reader into a Notion **Books** database — one
page per book — with read status, progress, finished date, and all of the book's
highlights in the page body. Plug the Kobo into your Mac and run the sync —
easiest from **Raycast** (see *Daily use*) — and re-running handles adds, edits,
and deletes. An optional plug-in auto-trigger is also available.

The same run also pushes books **the other way**: drop an ebook into `inbox/` and
it gets sideloaded onto the Kobo — no Calibre needed (see *Sideload books*).

```
Kobo (USB) ──▶ sync-kobo-highlights.sh ──▶ Notion worker webhook ──▶ Books database
   SQLite          reads + groups              upserts one page per book

inbox/*.epub ─▶ sync-kobo-highlights.sh ─▶ Kobo (USB)
  drop a book      kepubify → KEPUB           imported when it ejects
```

The local side (this repo) reads the device and POSTs to a webhook. All the
Notion logic lives in a **Notion Worker** that's already deployed to the
account — this repo just needs the webhook URL + secret to talk to it. Move this
repo to any Mac, point it at the same webhook, and it syncs to the same Notion.

## What syncs per book

| Books column | Source | Write policy |
|---|---|---|
| Title, Author, Format | Title / Attribution / "Ebook" | set on create only |
| Status | ReadStatus → To Read / Reading / Finished | every sync |
| Progress | % read | every sync |
| Finished | DateLastRead — only if finished and a plausible date (year ≥ 2010) | every sync |
| Highlights | count + page body (chapter headings, quotes, notes) | every sync |
| Rating, Genre, Link | — | **never written** (curate these by hand) |

Each book always sends its *complete current* highlight set, so the worker just
rebuilds the page body — no change-tracking, and deletes take care of themselves.

## Sideload books onto the Kobo (no Calibre)

Calibre is just a wrapper around copying a file onto the device — so this script
does it directly. **Drop an ebook into the `inbox/` folder, plug in the Kobo, and
run the sync.** Each file is copied onto the device, the original is archived to
`inbox/sent/`, and the volume is ejected so the Kobo runs its "Importing content"
pass when you unplug. Books out, highlights in — one command.

```sh
cp ~/Downloads/some-book.epub inbox/    # then run ./sync-kobo-highlights.sh
```

**Formats:**

| You drop… | What happens |
|---|---|
| `.epub` | Converted to **KEPUB** if `kepubify` is installed (better progress/stats — the same data this sync reads), else copied as-is |
| `.kepub.epub` | Copied as-is |
| `.pdf` `.cbz` `.cbr` `.txt` `.html` `.rtf` `.fb2` `.djvu` | Copied as-is (Kobo reads these natively) |
| `.mobi` `.azw` `.azw3` `.kfx` (Kindle) | **Skipped** and left in `inbox/` — Kobo can't read them; convert to EPUB first |

**Optional but recommended — KEPUB conversion** (one tiny binary, no Calibre, no GUI):

```sh
brew install kepubify
```

With it installed, plain EPUBs become Kobo's enhanced KEPUB format on the way in,
which gives accurate page numbers and reading-time stats. Without it, EPUBs still
copy over fine.

**Notes:** the Kobo reads title/author/cover from the file's own metadata, so
filenames don't matter. Files in `inbox/` are git-ignored — they won't be
committed. (Ejection + the completion notification happen at the end of *every*
run, not just when a book is sideloaded — see *Daily use*.)

## Setup on a new Mac

1. **Install `jq`** (the only non-builtin dependency):
   ```sh
   brew install jq
   ```
2. **Clone this repo** anywhere, e.g. `~/dev/kobo-notion-sync`.
3. **Create your config** from the template and fill it in:
   ```sh
   cp kobo-sync.env.example kobo-sync.env
   ```
   - `KOBO_WEBHOOK_URL` — get it with `ntn workers webhooks list` (the `koboSync`
     entry), or copy it from the original Mac's `kobo-sync.env`.
   - `KOBO_SYNC_SECRET` — must match the worker's `KOBO_SYNC_SECRET`. Copy it from
     the original Mac's `kobo-sync.env` (it isn't stored in git).
4. **Make it runnable** — set up the **Raycast command** (recommended; see
   *Daily use*), or just run `./sync-kobo-highlights.sh` from the terminal.
5. **Plug in your Kobo** and run the sync. Done.

   *(Optional)* For hands-off syncing on plug-in, run `./install.sh` and grant
   Full Disk Access to the `KoboSync.app` it builds (see *Permissions*). It wakes
   on every volume mount, so many prefer the manual/Raycast trigger.

## Daily use

Plug in the Kobo, then trigger a sync. When the run finishes it **ejects the Kobo
automatically and pops a "✅ Kobo synced — safe to unplug" notification** (with a
sound), so you can fire it off and just wait for the banner before unplugging.
Turn either off with `KOBO_AUTO_EJECT=0` / `KOBO_NOTIFY_SOUND=""` in `kobo-sync.env`.

**Raycast (recommended)** — run the **Sync Kobo to Notion** command. Set it up
once: save the file below as `sync-kobo-to-notion.sh` in this repo, then add this
folder in Raycast under *Settings → Extensions → Script Commands → Add Script
Directory*. It then runs from Raycast as **Sync Kobo to Notion**.

```bash
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Sync Kobo to Notion
# @raycast.mode fullOutput
# @raycast.icon 📚
# @raycast.packageName Kobo → Notion
# @raycast.description Sync all books + highlights from a plugged-in Kobo into Notion.

cd "$(dirname "$0")" || exit 1
exec ./sync-kobo-highlights.sh
```

**Terminal** — run it directly anytime:
```sh
./sync-kobo-highlights.sh
```

**Automatic on plug-in (optional)** — `./install.sh` installs a LaunchAgent
(`StartOnMount`) that syncs whenever a volume mounts; `./uninstall.sh` removes it.
Convenient, but it wakes on *every* mount (any drive or disk image), which many
find noisy — the Raycast trigger is usually nicer.

## Managing it

```sh
tail -f sync.log                                            # watch it work
launchctl bootout gui/$(id -u)/com.caleb.kobo-sync          # disable auto-sync
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.caleb.kobo-sync.plist  # re-enable
launchctl kickstart gui/$(id -u)/com.caleb.kobo-sync        # force a run now
./uninstall.sh                                              # remove agent + app
```

## Permissions (the one gotcha)

A launchd background job can't read a removable volume until granted **Full Disk
Access**, and macOS attributes that grant to the *executable* — for a launchd
`.sh` that's `bash`, a protected system binary you can't grant. So the agent runs
through **`KoboSync.app`** (an app bundle *is* a valid FDA target), which
`install.sh` builds and `do shell script`-runs the real script.

If a plug-in doesn't sync, check `sync.log`. The telltale failure is:
`cp: …/KoboReader.sqlite: Operation not permitted` → FDA isn't granted to
`KoboSync.app`. Grant it (step 5) and reload the agent.

> Manual runs from Terminal don't need this — Terminal already has the grant.

## How it reads the Kobo

`KoboReader.sqlite` (in `.kobo/` on the mounted device) holds everything:
- `content` (ContentType = 6) — one row per book: title, author, `ReadStatus`,
  `___PercentRead`, `DateLastRead`, …
- `Bookmark` — highlights/notes (`Text`, `Annotation`, joined to `content` for
  the chapter title).

The script snapshots the DB (incl. `-wal`/`-shm`) so it never reads the live
file, extracts both tables with `sqlite3 -json`, merges them with `jq`, and POSTs
one JSON payload per book to the webhook.

## Backups

That same `KoboReader.sqlite` is the **only** copy of every highlight and reading
position you own — lose, reset, or brick the Kobo and it's gone. So every sync
drops a timestamped, self-contained copy into **`backups/`** (via `VACUUM INTO`,
WAL applied — one file, directly restorable). The newest `KOBO_BACKUP_KEEP`
(default 30) are kept; set `KOBO_BACKUP=0` to disable. The `.sqlite` files are
git-ignored.

**Restore** — with the Kobo plugged in, copy a backup back over the device DB:

```sh
cp backups/KoboReader-<stamp>.sqlite "/Volumes/KOBOeReader/.kobo/KoboReader.sqlite"
rm -f "/Volumes/KOBOeReader/.kobo/KoboReader.sqlite-wal" \
      "/Volumes/KOBOeReader/.kobo/KoboReader.sqlite-shm"   # then eject
```

## Notes / limitations

- Covers store-bought **and** sideloaded books — read straight from the device.
- **Not real-time.** Kobo has no live push; sync happens on plug-in (or manual run).
- Each book's **page body is owned by the sync** and rebuilt when highlights
  change. Keep personal notes in a property or a sub-page, not the book's body.
- A book whose highlights are *all* deleted won't be re-sent, so its page keeps
  the last highlights. Per-highlight deletes within a book sync fine.
- The two helper columns (`Kobo Volume ID`, `Sync Hash`) are internal — hide them
  in your Notion views.

## Files

| File | Purpose |
|---|---|
| `sync-kobo-highlights.sh` | the bridge — reads the Kobo + POSTs to the webhook, then sideloads `inbox/` onto the device |
| `inbox/` | drop ebooks here to sideload them; originals move to `inbox/sent/` (contents git-ignored) |
| `backups/` | timestamped `KoboReader.sqlite` copies, one per sync (`.sqlite` files git-ignored) |
| `sync-kobo-to-notion.sh` | Raycast command wrapper (the **Sync Kobo to Notion** command) |
| `install.sh` / `uninstall.sh` | set up / tear down the optional auto-sync LaunchAgent |
| `kobo-sync.env.example` | template for your webhook URL + secret |
| `kobo-sync.env` | your real config (git-ignored) |
| `KoboSync.app` | FDA wrapper, built locally by `install.sh` (git-ignored) |
| `sync.log` | run log (git-ignored) |
