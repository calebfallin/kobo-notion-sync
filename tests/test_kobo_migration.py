"""Migration checks with synthetic books. No device, cloud, or user data."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'migrate-kobo-highlights.py')
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / 'snapshot.sqlite'
        self.book = self.root / 'book.kepub.epub'
        with zipfile.ZipFile(self.book, 'w') as z:
            z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
            z.writestr('OPS/book.opf', '<package><metadata/><manifest><item id="c1" href="chapter.xhtml"/></manifest><spine><itemref idref="c1"/></spine></package>')
            z.writestr('OPS/chapter.xhtml', '<html><head/><body><p><span id="kobo.1.1">A😀B</span><em><span id="kobo.1.2"> next</span></em></p></body></html>')
        with sqlite3.connect(self.db) as db:
            db.execute('CREATE TABLE content (ContentID, ContentType, Title, Attribution)')
            db.execute('INSERT INTO content VALUES (?, 6, ?, ?)', ('book-id', 'Test book', 'Test author'))
            db.execute('CREATE TABLE Bookmark (BookmarkID, VolumeID, ContentID, StartContainerPath, StartOffset, EndContainerPath, EndOffset, Text, Annotation, DateCreated, DateModified, Hidden, Type)')
            db.execute('INSERT INTO Bookmark VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                       ('note-id', 'book-id', '/mnt/onboard/book.kepub.epub!OPS!chapter.xhtml', r'span#kobo\.1\.1', 1,
                        r'span#kobo\.1\.2', 5, '😀B next', 'Keep this note', '2026-01-01T00:00:00Z', None, 'false', 'highlight'))

    def convert(self):
        return migration.convert(self.db, self.book, 'book-id')

    def test_exact_range_across_elements_and_utf16(self):
        before = (self.db.read_bytes(), self.book.read_bytes())
        result = self.convert()
        note = result['annotations'][0]
        self.assertEqual(note['cfi'], 'epubcfi(/6/2!/4/2,/2/1:1,/4/2/1:5)')
        self.assertEqual(note['text'], '😀B next')
        self.assertEqual(note['note'], 'Keep this note')
        self.assertEqual(note['id'], 'note-id')
        self.assertEqual(before, (self.db.read_bytes(), self.book.read_bytes()))
        self.assertEqual(note['updatedAt'], note['createdAt'])

    def test_repeated_conversion_preserves_ids_and_locations(self):
        self.assertEqual(self.convert()['annotations'], self.convert()['annotations'])

    def test_wrong_book_text_is_rejected(self):
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE Bookmark SET Text = 'different text'")
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.convert()

    def test_hidden_highlights_are_not_migrated(self):
        for hidden in (1, 'true'):
            with sqlite3.connect(self.db) as db:
                db.execute('UPDATE Bookmark SET Hidden = ?', (hidden,))
            with self.assertRaisesRegex(ValueError, 'No text highlights'):
                self.convert()

    def test_numeric_and_null_visible_flags(self):
        for hidden in (0, None):
            with sqlite3.connect(self.db) as db:
                db.execute('UPDATE Bookmark SET Hidden = ?', (hidden,))
            self.assertEqual(len(self.convert()['annotations']), 1)

    def test_invalid_unicode_boundary_is_rejected(self):
        with sqlite3.connect(self.db) as db:
            db.execute('UPDATE Bookmark SET StartOffset = 2')
        with self.assertRaises(ValueError):
            self.convert()

    def test_wrong_volume_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            migration.convert(self.db, self.book, 'different-book')

    def test_range_across_paragraphs(self):
        doc = migration.minidom.parseString('<html><head/><body><p><span id="kobo.1.1">first</span></p>\n<p><span id="kobo.2.1">second</span></p></body></html>')
        start = migration.endpoint(doc, 'span#kobo.1.1', 2)
        end = migration.endpoint(doc, 'span#kobo.2.1', 3)
        cfi, text = migration.make_range(doc, start, end, '/6/2')
        self.assertEqual(cfi, 'epubcfi(/6/2!/4,/2/2/1:2,/4/2/1:3)')
        self.assertEqual(text, 'rst\nsec')

    def test_duplicate_span_id_is_rejected(self):
        doc = migration.minidom.parseString('<html><body><span id="kobo.1.1">one</span><span id="kobo.1.1">two</span></body></html>')
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            migration.endpoint(doc, 'span#kobo.1.1', 0)


if __name__ == '__main__':
    unittest.main()
