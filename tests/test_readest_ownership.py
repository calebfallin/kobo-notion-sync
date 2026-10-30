"""Verify exact book ownership without a Kobo, token, or network call."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OwnershipTests(unittest.TestCase):
    def apply_filter(self, owned, books):
        return subprocess.run(['jq', '--argjson', 'owned', json.dumps(owned),
                               '-f', str(ROOT / 'filter-native-books.jq')],
                              input=json.dumps(books), text=True, capture_output=True)

    def test_migrated_book_is_not_in_webhook_batch(self):
        migrated = {'volumeId': 'file:///mnt/onboard/Ed Bacon.epub',
                    'title': 'Ed Bacon', 'highlights': [{'text': 'old highlight'}]}
        other = {'volumeId': 'file:///mnt/onboard/Ed Bacon 2.epub',
                 'title': 'Ed Bacon', 'highlights': [{'text': 'other book'}]}
        result = self.apply_filter([migrated['volumeId']], [migrated, other])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [other])

    def test_empty_list_keeps_legacy_behavior(self):
        books = [{'volumeId': 'one'}, {'volumeId': 'two'}]
        self.assertEqual(json.loads(self.apply_filter([], books).stdout), books)

    def test_all_migrated_yields_no_posts(self):
        self.assertEqual(json.loads(self.apply_filter(['one'], [{'volumeId': 'one'}]).stdout), [])

    def test_quoted_unicode_id_is_matched_as_data(self):
        identity = 'file:///mnt/onboard/é "book".epub'
        self.assertEqual(json.loads(self.apply_filter([identity], [{'volumeId': identity}]).stdout), [])

    def test_invalid_ownership_stops_instead_of_sending_all_books(self):
        for owned in [None, {}, 'one', [None], ['']]:
            with self.subTest(owned=owned):
                result = self.apply_filter(owned, [{'volumeId': 'one'}])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
