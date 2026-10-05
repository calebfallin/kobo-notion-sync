#!/usr/bin/env bash
# Sideload helpers. Source this file; it does not start a sync or access Notion.

sideload_digest() {
	local digest
	digest="$(shasum -a 256 < "$1")" || return 1
	printf '%s' "${digest:0:16}"
}

sideload_filename() {
	local f="$1" output_ext="$2" base stem safe digest
	base="$(basename "$f")"
	stem="${base%.*}"
	case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
	*.kepub.epub) stem="${stem%.*}" ;;
	esac
	# ASCII names work on the Kobo filesystem. Leave room for extensions and
	# collision suffixes; title/author still come from the ebook's metadata.
	safe="$(printf '%s' "$stem" | LC_ALL=C tr -c 'A-Za-z0-9 ._-' '_' \
		| LC_ALL=C cut -c 1-140 | sed 's/^[ .]*//; s/[ .]*$//')"
	[ -n "$safe" ] || safe="book"
	if [ "$safe" != "$stem" ]; then
		digest="$(sideload_digest "$f")" || return 1
		safe="$safe-$digest"
	fi
	printf '%s.%s' "$safe" "$output_ext"
}

sideload_valid_epub() {
	# Reject broken downloads before conversion or plain-EPUB fallback.
	unzip -tqq "$1" >/dev/null 2>&1 \
		&& [ "$(unzip -p "$1" mimetype 2>/dev/null)" = "application/epub+zip" ] \
		&& unzip -p "$1" META-INF/container.xml >/dev/null 2>&1
}

sideload_one() (
	# A subshell keeps scratch cleanup separate from the main DB-backup trap.
	f="$1"; ext="$2"; have_kepubify="$3"
	base="$(basename "$f")"
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/kobo-sideload.XXXXXX")" || return 1
	staged=""
	trap 'if [ -n "$staged" ]; then rm -f "$staged"; fi; rm -rf "$workdir"' EXIT
	prepared="$f"
	output_ext="$ext"
	case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
	*.kepub.epub) output_ext="kepub.epub" ;;
	esac

	if [ "$ext" = "epub" ]; then
		if ! sideload_valid_epub "$f"; then
			echo "  ✗ $base — invalid EPUB archive (left in inbox/)"
			return 1
		fi
		if [ "$output_ext" != "kepub.epub" ] && [ "$have_kepubify" = "1" ]; then
			# Never give kepubify the download's long output name. Its own
			# temporary suffix can exceed the filesystem's filename limit.
			if kepubify -i -o "$workdir/book.kepub.epub" "$f" >"$workdir/conversion.log" 2>&1 \
				&& [ -s "$workdir/book.kepub.epub" ]; then
				prepared="$workdir/book.kepub.epub"
				output_ext="kepub.epub"
			else
				echo "  ↳ $base — KEPUB conversion failed; copying the valid EPUB instead"
				sed 's/^/    /' "$workdir/conversion.log"
			fi
		fi
	fi

	name="$(sideload_filename "$f" "$output_ext")" || return 1
	target="$KOBO_MOUNT/$name"
	if [ -e "$target" ] && ! cmp -s "$prepared" "$target"; then
		# Two downloads can have the same short name. Keep both books.
		digest="$(sideload_digest "$f")" || return 1
		name="${name%.$output_ext}-$digest.$output_ext"
		target="$KOBO_MOUNT/$name"
	fi
	if [ -e "$target" ]; then
		if ! cmp -s "$prepared" "$target"; then
			echo "  ✗ $base — destination conflicts with an existing book (left in inbox/)"
			return 1
		fi
	else
		# Copy under a short, hidden name, then publish the complete file.
		staged="$(mktemp "$KOBO_MOUNT/.kobo-sideload.XXXXXX")" || return 1
		if ! cp "$prepared" "$staged" || ! mv -n "$staged" "$target" || [ -e "$staged" ]; then
			echo "  ✗ $base — copy failed (left in inbox/)"
			return 1
		fi
		staged=""
	fi

	archive="$SENT_DIR"
	if [ -e "$archive/$base" ]; then
		# Preserve an earlier original rather than silently overwriting it.
		archive="$(mktemp -d "$SENT_DIR/batch.XXXXXX")" || return 1
	fi
	if ! mv "$f" "$archive/"; then
		echo "  ✗ $base — copied to Kobo, but could not archive (left in inbox/)"
		return 1
	fi
	echo "  ✓ $base → $name"
)

sideload_books() {
	SIDELOAD_COPIED=0
	SIDELOAD_FAILED=0
	[ -d "$INBOX_DIR" ] || return 0
	shopt -s nullglob
	local entries=("$INBOX_DIR"/*)
	shopt -u nullglob
	# macOS Bash 3.2 treats expansion of an empty array as unset under -u.
	[ "${#entries[@]}" -gt 0 ] || return 0
	local candidates=() f
	for f in "${entries[@]}"; do
		[ -f "$f" ] && candidates+=("$f")
	done
	[ "${#candidates[@]}" -gt 0 ] || return 0

	echo "Sideloading ${#candidates[@]} file(s) from inbox/ …"
	if ! mkdir -p "$SENT_DIR"; then
		SIDELOAD_FAILED="${#candidates[@]}"
		echo "  ✗ Could not create inbox/sent/; originals remain in inbox/"
		return 0
	fi
	local have_kepubify=0 base lower ext
	command -v kepubify >/dev/null 2>&1 && have_kepubify=1
	for f in "${candidates[@]}"; do
		base="$(basename "$f")"
		lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
		ext="${lower##*.}"
		if ! printf '%s\n' $KOBO_NATIVE_EXTS | grep -qx "$ext"; then
			echo "  ⤬ $base — .$ext isn't read by Kobo; convert to EPUB first (left in inbox/)"
			SIDELOAD_FAILED=$((SIDELOAD_FAILED + 1))
			continue
		fi
		if sideload_one "$f" "$ext" "$have_kepubify"; then
			SIDELOAD_COPIED=$((SIDELOAD_COPIED + 1))
		else
			SIDELOAD_FAILED=$((SIDELOAD_FAILED + 1))
		fi
	done
	echo "Sideload: $SIDELOAD_COPIED copied, $SIDELOAD_FAILED skipped/failed."
}
