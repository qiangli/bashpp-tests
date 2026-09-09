#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True
import tempfile
from pathlib import Path
import unittest
import skips


class SkipSourceBindingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def source(self, path, body):
        p = self.root / 'src' / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
        return p

    def test_package_callsite_has_priority_over_same_basename(self):
        direct = self.source('example/check_test.go', 'package example\n t.Skip("darwin")\n')
        other = self.source('other/check_test.go', 'package other\n t.Skip("different")\n')
        rows = skips.bind_callsite('example', 'check_test.go', 2, self.root, {'check_test.go': [other, direct]})
        self.assertEqual(1, len(rows))
        self.assertEqual('src/example/check_test.go', rows[0]['sdk_relative_path'])
        self.assertEqual(' t.Skip("darwin")', rows[0]['source_line'])

    def test_helper_skip_call_disambiguates_basename(self):
        helper = self.source('internal/testenv/check.go', 'package testenv\n t.Skip("host")\n')
        unrelated = self.source('other/check.go', 'package other\n return true\n')
        rows = skips.bind_callsite('example', 'check.go', 2, self.root, {'check.go': [helper, unrelated]})
        self.assertEqual(1, len(rows))
        self.assertEqual('src/internal/testenv/check.go', rows[0]['sdk_relative_path'])

    def test_unresolved_callsite_remains_empty(self):
        self.assertEqual([], skips.bind_callsite('example', 'absent.go', 99, self.root, {}))

    def test_out_of_bounds_source_is_rejected(self):
        p = self.source('example/test.go', 'package example\n')
        with self.assertRaisesRegex(ValueError, 'outside source'):
            skips.context(p, 2, self.root)

    def test_source_record_changes_when_bytes_change(self):
        p = self.source('example/test.go', 't.Skip("original")\n')
        before = skips.context(p, 1, self.root)
        p.write_text('t.Skip("changed")\n')
        self.assertNotEqual(before['source']['sha256'], skips.context(p, 1, self.root)['source']['sha256'])


if __name__ == '__main__':
    unittest.main()
