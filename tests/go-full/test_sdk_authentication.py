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
    LINUX_AMD64 = [
        "toolchain", "go1.27.0", "linux", "amd64",
        "1db869c560a193573a71be466a34e0d4abb7792d78165c6102cdda069276a3a8",
        "go1.27.0.linux-amd64.tar.gz",
        "675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685",
        "golang.org/toolchain", "v0.0.1-go1.27.0.linux-amd64",
        "h1:fVts2HjYwzBWrJtkf1B9HRDAuCZcZLexWI6ZX6Ls/IU=",
    ]

    def test_linux_amd64_official_distribution_pin_is_exact_and_unique(self):
        rows = [row for row in sdk.inv.rows(sdk.inv.REPO / "docs/go-oracle/toolchain.tsv")
                if row[:4] == ["toolchain", "go1.27.0", "linux", "amd64"]]
        self.assertEqual(rows, [self.LINUX_AMD64])

        # A duplicate must cease to be an authenticated coordinate; the exact
        # assertions above make any one-byte value mutation fail this test.
        duplicate = rows + rows
        with self.assertRaisesRegex(ValueError, "platform lacks one reviewed toolchain pin"):
            sdk.reviewed_toolchain({"release": "go1.27.0"}, "linux", "amd64", duplicate)
        mutated = rows[0].copy()
        mutated[4] = "0" * 64
        self.assertNotEqual(mutated, self.LINUX_AMD64)

    def test_linux_amd64_missing_sdk_fails_closed_before_download(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(sdk.subprocess, "run") as process:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, "existing SDK directory required"):
                sdk.prepare(root / "source", root / "cache", root / "sdk", "linux", "amd64", True)
            self.assertEqual(list(root.iterdir()), [])
            process.assert_not_called()

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
