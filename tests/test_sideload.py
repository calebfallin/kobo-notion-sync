"""Test sideloading in temporary folders. Never run the live sync."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]


def make_epub(path, text="Test book"):
    with zipfile.ZipFile(path, "w") as book:
        book.writestr("mimetype", "application/epub+zip")
        book.writestr("META-INF/container.xml", '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''')
        book.writestr("book.opf", '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">test</dc:identifier>
<dc:title>Test book</dc:title><dc:language>en</dc:language></metadata>
<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="chapter"/></spine></package>''')
        book.writestr("chapter.xhtml", f'''<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Test</title></head><body><p>{text}</p></body></html>''')


class SideloadTests(unittest.TestCase):
    def setUp(self):
        (REPO / "inbox").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix=".test-sideload-", dir=REPO / "inbox")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inbox = self.root / "inbox"
        self.kobo = self.root / "kobo"
        self.bin = self.root / "bin"
        for folder in (self.inbox, self.kobo, self.bin):
            folder.mkdir()
        self.stub_converter('''[ "$1" = "-i" ] && [ "$2" = "-o" ] || exit 2
[ "${3##*/}" = "book.kepub.epub" ] || exit 3
printf 'called\\n' >> "$TEST_CONVERTER_CALLS"
cp "$4" "$3"
''')

    def stub_converter(self, body):
        tool = self.bin / "kepubify"
        tool.write_text("#!/bin/bash\nset -eu\n" + body)
        tool.chmod(0o755)

    def run_sideload(self, *, converter=True, real_converter=False, kobo=None):
        env = os.environ.copy()
        env.update(TEST_REPO=str(REPO), TEST_INBOX=str(self.inbox),
                   TEST_KOBO=str(kobo or self.kobo), TMPDIR=str(self.root),
                   TEST_CONVERTER_CALLS=str(self.root / "converter-calls"))
        if not real_converter:
            env["PATH"] = str(self.bin) + os.pathsep + env["PATH"]
        script = '''set -euo pipefail
INBOX_DIR="$TEST_INBOX"
SENT_DIR="$INBOX_DIR/sent"
KOBO_MOUNT="$TEST_KOBO"
KOBO_NATIVE_EXTS="epub pdf cbz cbr txt html htm rtf fb2 djvu"
. "$TEST_REPO/sideload-books.sh"
'''
        if not converter:
            script += '''command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "kepubify" ]; then return 1; fi
    builtin command "$@"
}
'''
        script += '''sideload_books
printf 'RESULT %s %s\\n' "$SIDELOAD_COPIED" "$SIDELOAD_FAILED"
'''
        result = subprocess.run(["/bin/bash", "-c", script], env=env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(list(self.root.glob("kobo-sideload.*")))
        self.assertFalse(list(self.kobo.glob(".kobo-sideload.*")))
        return result.stdout + result.stderr

    def device_files(self):
        return [p for p in self.kobo.iterdir() if p.is_file()]

    def test_long_unicode_download_names(self):
        names = ["Ed Bacon " + "x" * 190 + " Anna’s Archive.epub",
                 "Rush " + "x" * 195 + " Anna’s Archive.epub"]
        for name in names:
            make_epub(self.inbox / name)
        output = self.run_sideload()
        self.assertIn("RESULT 2 0", output)
        self.assertEqual(len(self.device_files()), 2)
        for file in self.device_files():
            self.assertLess(len(file.name.encode()), 200)
            self.assertTrue(file.name.isascii())
            self.assertTrue(file.name.endswith(".kepub.epub"))
        for name in names:
            self.assertTrue((self.inbox / "sent" / name).is_file())

    def test_conversion_error_falls_back_and_shows_error(self):
        self.stub_converter('echo "test conversion error" >&2\nexit 1\n')
        make_epub(self.inbox / "Book.epub")
        output = self.run_sideload()
        self.assertIn("RESULT 1 0", output)
        self.assertIn("test conversion error", output)
        self.assertIn("copying the valid EPUB instead", output)
        self.assertTrue((self.kobo / "Book.epub").is_file())

    def test_converter_success_without_output_falls_back(self):
        self.stub_converter("exit 0\n")
        make_epub(self.inbox / "Book.epub")
        self.assertIn("RESULT 1 0", self.run_sideload())
        self.assertTrue((self.kobo / "Book.epub").is_file())

    def test_corrupt_download_stays_in_inbox(self):
        source = self.inbox / "Broken.epub"
        source.write_bytes(b"not an EPUB")
        output = self.run_sideload()
        self.assertIn("RESULT 0 1", output)
        self.assertIn("invalid EPUB archive", output)
        self.assertTrue(source.is_file())
        self.assertEqual(self.device_files(), [])

    def test_same_truncated_prefix_keeps_both_books(self):
        for tail in ("first", "second"):
            make_epub(self.inbox / ("x" * 210 + tail + ".epub"), tail)
        self.assertIn("RESULT 2 0", self.run_sideload())
        self.assertEqual(len(self.device_files()), 2)

    def test_existing_different_book_is_preserved(self):
        target = self.kobo / "Book.kepub.epub"
        target.write_bytes(b"existing book")
        make_epub(self.inbox / "Book.epub")
        self.assertIn("RESULT 1 0", self.run_sideload())
        self.assertEqual(target.read_bytes(), b"existing book")
        self.assertEqual(len(self.device_files()), 2)

    def test_repeat_download_preserves_both_archived_originals(self):
        source = self.inbox / "Book.epub"
        make_epub(source)
        self.assertIn("RESULT 1 0", self.run_sideload())
        shutil.copyfile(self.inbox / "sent" / source.name, source)
        self.assertIn("RESULT 1 0", self.run_sideload())
        self.assertEqual(len(self.device_files()), 1)
        self.assertEqual(len(list((self.inbox / "sent").rglob("Book.epub"))), 2)

    def test_no_converter_copies_plain_epub(self):
        make_epub(self.inbox / "Book.epub")
        self.assertIn("RESULT 1 0", self.run_sideload(converter=False))
        self.assertTrue((self.kobo / "Book.epub").is_file())

    def test_native_formats_and_existing_kepub_skip_conversion(self):
        for ext in ("pdf", "cbz", "cbr", "txt", "html", "htm", "rtf", "fb2", "djvu"):
            (self.inbox / f"Book.{ext}").write_bytes(b"native format fixture")
        make_epub(self.inbox / "Book.kepub.epub")
        self.assertIn("RESULT 10 0", self.run_sideload())
        self.assertFalse((self.root / "converter-calls").exists())

    def test_copy_failure_retains_original(self):
        source = self.inbox / "Book.epub"
        make_epub(source)
        self.assertIn("RESULT 0 1", self.run_sideload(kobo=self.root / "missing-device"))
        self.assertTrue(source.is_file())

    def test_partial_copy_is_removed(self):
        tool = self.bin / "cp"
        tool.write_text('#!/bin/bash\nprintf partial > "$2"\necho "test copy error" >&2\nexit 1\n')
        tool.chmod(0o755)
        source = self.inbox / "Book.epub"
        make_epub(source)
        output = self.run_sideload()
        self.assertIn("RESULT 0 1", output)
        self.assertIn("copy failed", output)
        self.assertTrue(source.is_file())
        self.assertEqual(self.device_files(), [])

    def test_archive_failure_can_be_retried_without_duplicate_device_copy(self):
        tool = self.bin / "mv"
        tool.write_text('''#!/bin/bash
case "$2" in */sent/) echo "test archive error" >&2; exit 1 ;; esac
exec /bin/mv "$@"
''')
        tool.chmod(0o755)
        source = self.inbox / "Book.epub"
        make_epub(source)
        output = self.run_sideload()
        self.assertIn("RESULT 0 1", output)
        self.assertIn("could not archive", output)
        self.assertTrue(source.is_file())
        self.assertEqual(len(self.device_files()), 1)
        tool.unlink()
        self.assertIn("RESULT 1 0", self.run_sideload())
        self.assertEqual(len(self.device_files()), 1)

    def test_empty_inbox(self):
        self.assertIn("RESULT 0 0", self.run_sideload())

    def test_unsupported_file_is_retained(self):
        source = self.inbox / "Book.azw3"
        source.write_bytes(b"unsupported format fixture")
        self.assertIn("RESULT 0 1", self.run_sideload())
        self.assertTrue(source.is_file())

    @unittest.skipUnless(shutil.which("kepubify"), "kepubify is not installed")
    def test_real_converter_with_maximum_length_unicode_name(self):
        source = self.inbox / ("é" * 122 + ".epub")
        make_epub(source)
        output = self.run_sideload(real_converter=True)
        self.assertIn("RESULT 1 0", output)
        self.assertTrue(self.device_files()[0].name.endswith(".kepub.epub"))
        with zipfile.ZipFile(self.device_files()[0]) as book:
            self.assertIsNone(book.testzip())
            self.assertIn(b"koboSpan", book.read("chapter.xhtml"))

    @unittest.skipUnless(shutil.which("kepubify"), "kepubify is not installed")
    def test_real_conversion_repeat_does_not_add_a_duplicate(self):
        source = self.inbox / "Book.epub"
        make_epub(source)
        self.assertIn("RESULT 1 0", self.run_sideload(real_converter=True))
        shutil.copyfile(self.inbox / "sent" / source.name, source)
        self.assertIn("RESULT 1 0", self.run_sideload(real_converter=True))
        self.assertEqual(len(self.device_files()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
