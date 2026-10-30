"""Verify UTC conversion in several host zones, including DST boundaries."""
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UTCTests(unittest.TestCase):
    def test_server_timestamps_are_independent_of_local_zone(self):
        lua = shutil.which('lua')
        self.assertIsNotNone(lua, 'Install Lua to run the plugin date tests')
        dates = ['2026-10-30T21:22:12Z', '2026-10-30T21:22:12.123+00:00',
                 '2026-01-15T12:00:00Z', '2026-03-08T06:59:59Z',
                 '2026-03-08T07:00:00Z', '2026-11-01T05:59:59Z',
                 '2026-11-01T06:00:00Z', '2000-02-29T00:00:00Z',
                 '2026-10-30T17:22:12-04:00', '2026-10-31T02:52:12+05:30']
        expected = [int(datetime.fromisoformat(date.replace('Z', '+00:00')).timestamp()) for date in dates]
        for zone in ['UTC', 'America/New_York', 'Asia/Kolkata', 'Pacific/Auckland']:
            script = 'local utc = dofile("readest_utc.lua")\n'
            script += '\n'.join('print(string.format("%.0f", utc.parse(' + json.dumps(date) + ')))' for date in dates)
            out = subprocess.check_output([lua, '-'], input=script, text=True, cwd=ROOT,
                                          env={**os.environ, 'TZ': zone})
            self.assertEqual([int(n) for n in out.splitlines()], expected, zone)

    def test_invalid_dates_fail_instead_of_inventing_a_position(self):
        lua = shutil.which('lua')
        self.assertIsNotNone(lua)
        script = '''local utc = dofile("readest_utc.lua")
for _, value in ipairs({"2026-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01T24:00:00Z", "not a date", "2026-01-01T00:00:00+99:99"}) do
    assert(utc.parse(value) == nil, value)
end
assert(utc.parse(nil) == nil)
'''
        subprocess.run([lua, '-'], input=script, text=True, cwd=ROOT, check=True)


if __name__ == '__main__':
    unittest.main()
