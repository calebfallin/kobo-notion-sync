# Kobo → Notion sync

Syncs **every book** on a Kobo e-reader into a Notion **Books** database — one
page per book — with read status, progress, finished date, and all of the book's
highlights in the page body. Plug the Kobo into your Mac and it syncs
automatically; re-running handles adds, edits, and deletes.

```
Kobo (USB) ──▶ sync-kobo-highlights.sh ──▶ Notion worker webhook ──▶ Books database
   SQLite          reads + groups              upserts one page per book
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
4. **Install the auto-sync:**
   ```sh
   ./install.sh
   ```
5. **Grant Full Disk Access** to the app it built (one time, required — see
   *Permissions* below):
   `System Settings → Privacy & Security → Full Disk Access → "+" → KoboSync.app`
6. **Plug in your Kobo.** Done.

## Daily use

**Automatic** — plug in the Kobo. A LaunchAgent (`StartOnMount`) runs the sync on
mount; within a few seconds Notion is up to date. Progress is logged to
`sync.log`.

**Manual** — run it anytime:
```sh
./sync-kobo-highlights.sh
```

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
| `sync-kobo-highlights.sh` | the bridge — reads the Kobo, POSTs to the webhook |
| `install.sh` / `uninstall.sh` | set up / tear down the auto-sync LaunchAgent |
| `kobo-sync.env.example` | template for your webhook URL + secret |
| `kobo-sync.env` | your real config (git-ignored) |
| `KoboSync.app` | FDA wrapper, built locally by `install.sh` (git-ignored) |
| `sync.log` | run log (git-ignored) |
