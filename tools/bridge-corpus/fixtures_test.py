#!/usr/bin/env python3
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True
from unittest.mock import patch
import fixtures


class FixtureLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name)
        self.files = [{'path': 'fixture.txt', 'bytes': 3, 'sha256': 'a' * 64}]
        self.row = {'result': {'Path': 'example.test/fixture', 'Version': 'v1.0.0', 'Sum': 'h1:module', 'GoModSum': 'h1:gomod', 'Dir': str(self.cache / 'module'), 'Zip': str(self.cache / 'module.zip'), 'GoMod': str(self.cache / 'module.mod')}, 'archive': {'sha256': 'b' * 64}, 'gomod': {'sha256': 'c' * 64}, 'files': self.files}
        self.locked = {('example.test/fixture', 'v1.0.0'): {'sum': 'h1:module', 'gomod_sum': 'h1:gomod', 'archive_sha256': 'b' * 64, 'gomod_sha256': 'c' * 64, 'tree_sha256': hashlib.sha256(json.dumps(self.files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}}

    def tearDown(self):
        self.tmp.cleanup()

    def test_valid_locked_module(self):
        fixtures.check_locked_module(self.row, self.locked, self.cache)

    def test_rewritten_tree_manifest_is_rejected(self):
        self.row['files'][0]['sha256'] = 'd' * 64
        with self.assertRaisesRegex(ValueError, 'tree manifest'):
            fixtures.check_locked_module(self.row, self.locked, self.cache)

    def test_archive_replacement_is_rejected(self):
        self.row['archive']['sha256'] = 'd' * 64
        with self.assertRaisesRegex(ValueError, 'artifact checksum'):
            fixtures.check_locked_module(self.row, self.locked, self.cache)

    def test_module_version_substitution_is_rejected(self):
        self.row['result']['Version'] = 'v2.0.0'
        with self.assertRaisesRegex(ValueError, 'outside reviewed'):
            fixtures.check_locked_module(self.row, self.locked, self.cache)

    def test_unreviewed_sum_is_rejected(self):
        self.row['result']['Sum'] = 'h1:unreviewed'
        with self.assertRaisesRegex(ValueError, 'module sum'):
            fixtures.check_locked_module(self.row, self.locked, self.cache)

    def test_cache_redirect_is_rejected(self):
        self.row['result']['Dir'] = '/tmp/unverified-cache'
        with self.assertRaisesRegex(ValueError, 'outside declared'):
            fixtures.check_locked_module(self.row, self.locked, self.cache)

    def test_tree_checks_symlinks(self):
        (self.cache / 'escape').symlink_to('/tmp')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            fixtures.tree(self.cache)

    def test_tree_detects_byte_and_membership_changes(self):
        (self.cache / 'fixture').write_text('original')
        original = fixtures.tree(self.cache)
        (self.cache / 'fixture').write_text('tampered')
        self.assertNotEqual(original, fixtures.tree(self.cache))
        (self.cache / 'extra').write_text('extra')
        self.assertEqual(2, len(fixtures.tree(self.cache)))


if __name__ == '__main__':
    unittest.main()
