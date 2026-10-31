"""Check that the targeted installer preserves the source and fails closed."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('patcher', ROOT / 'patch-readest-timezone.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)

SOURCE = b'''local SyncAnnotations = {}
function SyncAnnotations:parseISODatetime(dt)
    return os.time()
end
return SyncAnnotations
'''


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.target = self.directory / 'readest_syncannotations.lua'
        self.target.write_bytes(SOURCE)
        self.sha = hashlib.sha256(SOURCE).hexdigest()

    def test_dry_run_does_not_write(self):
        result = patcher.patch(self.directory, self.sha)
        self.assertIn('require("readest_utc").parse(dt)', result)
        self.assertEqual(self.target.read_bytes(), SOURCE)
        self.assertEqual(list(self.directory.iterdir()), [self.target])

    def test_apply_keeps_original_and_verified_helper(self):
        patcher.patch(self.directory, self.sha, apply=True)
        self.assertEqual(self.target.with_suffix('.lua.before-utc-fix').read_bytes(), SOURCE)
        self.assertEqual((self.directory / 'readest_utc.lua').read_bytes(),
                         (ROOT / 'readest_utc.lua').read_bytes())
        self.assertIn('require("readest_utc").parse(dt)', self.target.read_text())
        self.assertTrue(self.target.read_text().endswith('return SyncAnnotations\n'))

    def test_source_mismatch_changes_nothing(self):
        with self.assertRaisesRegex(ValueError, 'checksum'):
            patcher.patch(self.directory, '0' * 64, apply=True)
        self.assertEqual(self.target.read_bytes(), SOURCE)
        self.assertEqual(list(self.directory.iterdir()), [self.target])

    def test_existing_backup_is_preserved(self):
        backup = self.target.with_suffix('.lua.before-utc-fix')
        backup.write_bytes(b'earlier backup')
        with self.assertRaisesRegex(ValueError, 'Backup already exists'):
            patcher.patch(self.directory, self.sha, apply=True)
        self.assertEqual(backup.read_bytes(), b'earlier backup')
        self.assertEqual(self.target.read_bytes(), SOURCE)


if __name__ == '__main__':
    unittest.main()
