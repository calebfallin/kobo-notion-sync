#!/usr/bin/env python3
"""Apply the small UTC parsing fix to the verified Readest 0.12.16 plugin."""
import argparse
import hashlib
from pathlib import Path
import re

FUNCTION = re.compile(r'function SyncAnnotations:parseISODatetime\(dt\)\n.*?\nend\n', re.S)
REPLACEMENT = '''function SyncAnnotations:parseISODatetime(dt)
    return require("readest_utc").parse(dt) or os.time()
end
'''


def patch(plugin_dir, expected_hash, apply=False):
    target = Path(plugin_dir) / 'readest_syncannotations.lua'
    original = target.read_bytes()
    if hashlib.sha256(original).hexdigest() != expected_hash:
        raise ValueError('Source checksum differs; no files changed')
    patched, count = FUNCTION.subn(REPLACEMENT, original.decode())
    if count != 1:
        raise ValueError('Expected exactly one date parser; no files changed')
    helper = Path(__file__).with_name('readest_utc.lua').read_bytes()
    if apply:
        backup = target.with_suffix('.lua.before-utc-fix')
        if backup.exists():
            raise ValueError('Backup already exists; no files changed')
        backup.write_bytes(original)
        target.with_name('readest_utc.lua').write_bytes(helper)
        target.write_text(patched)
        if target.read_text() != patched:
            raise OSError('Installed patch did not pass readback')
    return patched


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin-dir', required=True, type=Path)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--apply', action='store_true', help='Write after making a backup; default only checks')
    args = parser.parse_args()
    patch(args.plugin_dir, args.expected_sha256, args.apply)
    print('UTC patch applied and read back.' if args.apply else 'UTC patch is ready. No files changed.')
