#!/usr/bin/env python3
"""Read-only SDK authentication never downloads or creates missing paths."""
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/go-full"))
import sdk


class ExistingSDKTests(unittest.TestCase):
    def test_missing_directories_are_not_created(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(sdk.subprocess, "run") as process:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, "existing SDK directory required"):
                sdk.prepare(root / "source", root / "cache", root / "sdk", "darwin", "arm64", True)
            self.assertEqual(list(root.iterdir()), [])
            process.assert_not_called()

    def test_missing_pinned_archive_cannot_trigger_download(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(sdk.subprocess, "run") as process:
            root = Path(tmp)
            for path in (root / "source/go", root / "cache", root / "sdk/bin"):
                path.mkdir(parents=True)
            # An existing arbitrary archive filename is not the pinned input.
            (root / "cache/untrusted.tar.gz").write_bytes(b"wrong archive")
            (root / "sdk/bin/go").write_bytes(b"tool")
            before = sorted(str(p.relative_to(root)) for p in root.rglob("*"))
            with self.assertRaisesRegex(ValueError, "existing SDK file required"):
                sdk.prepare(root / "source", root / "cache", root / "sdk", "darwin", "arm64", True)
            self.assertEqual(before, sorted(str(p.relative_to(root)) for p in root.rglob("*")))
            process.assert_not_called()

    def test_symlink_sdk_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(sdk.subprocess, "run") as process:
            root = Path(tmp)
            (root / "real").mkdir()
            (root / "source").mkdir()
            (root / "source/go").symlink_to(root / "real", target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "existing SDK directory required"):
                sdk.prepare(root / "source", root / "cache", root / "sdk", "darwin", "arm64", True)
            process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
