# Kobo to Notion Sync

## Required parent context

Before work, apply these instruction files in order:

1. `../../../AGENTS.md` for the root Agent Manager.
2. `../../AGENTS.md` for the Personal Area Manager.
3. `../AGENTS.md` for the Personal Development Orchestrator.
4. This file for the Kobo sync repository.

Read a missing parent explicitly. Stop if a required file is missing, inaccessible, or in conflict.

## Purpose and scope

This independent Git repository owns the local Kobo-to-Notion sync, Kobo book sideloading, device database backups, and the optional macOS launch agent wrapper.

Read `README.md` before changing behavior. Keep implementation, tests, commits, and evidence inside this repository.

## Safety and private data

The sync script can read and eject a connected Kobo, copy books, write backups, and send book data to Notion. A code-change request does not authorize running the live sync or changing the device or Notion.

Run `sync-kobo-highlights.sh`, `install.sh`, or `uninstall.sh` only when Caleb explicitly requests the related live action. Confirm the connected device and intended Notion destination first.

Never read, print, commit, or replace `kobo-sync.env`, webhook secrets, Kobo database backups, ebooks, logs, or another ignored private file unless the exact task requires the minimum read. Do not include their contents in reports.

## Development

Prefer paths relative to this repository. Do not add a hard-coded reference to the former `/Users/calebfallin/dev/personal/` tree.

For shell-only changes, run `bash -n` on every changed shell script. Use `shellcheck` when it is installed and relevant. Do not run the live sync as a syntax test.

Keep inbox, backup, environment, log, and generated application files ignored.

## Git and completion

This repository owns its own Git history. Do not stage it in the parent agents repository.

Before edits, inspect the branch and working tree. Preserve unrelated work. Commit and push only under the current authorization.

Report files changed, syntax or other tests, device or Notion side effects, branch, commit state, and push state. Confirm `AGENTS.md` and `CLAUDE.md` match byte for byte.
