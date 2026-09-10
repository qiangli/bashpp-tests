#!/usr/bin/env python3
"""Prepare an isolated SDK from two authenticated official archives.

Source files come from the source archive; compiled tools come from the pinned
platform distribution. Neither an installed toolchain nor a version string is
trusted as a substitute for distribution authentication.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
import inventory as inv


def reviewed_toolchain(pin, goos, goarch, rows=None):
    """Return the one reviewed distribution for an SDK platform, or refuse."""
    if rows is None:
        rows = inv.rows(inv.REPO / "docs/go-oracle/toolchain.tsv")
    candidates = [r for r in rows if r[0] == "toolchain" and r[1:4] == [pin["release"], goos, goarch]]
    inv.require(len(candidates) == 1, "platform lacks one reviewed toolchain pin")
    tool = candidates[0]
    inv.require(len(tool) == 10, "malformed reviewed toolchain pin")
    return tool


def prepare(source_cache, cache, output, goos, goarch, verify_existing=False):
    pin = inv.pins()
    tool = reviewed_toolchain(pin, goos, goarch)
    archive = cache / tool[5]
    if verify_existing:
        for directory in (source_cache / "go", cache, output):
            inv.require(directory.is_dir() and not directory.is_symlink(), "existing SDK directory required: " + str(directory))
        for existing in (source_cache / pin["filename"], archive, output / "bin/go"):
            inv.require(existing.is_file() and not existing.is_symlink(), "existing SDK file required: " + str(existing))
    else:
        cache.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        fd, tmp = tempfile.mkstemp(prefix="sdk-download-", dir=cache)
        os.close(fd)
        try:
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "https://go.dev/dl/" + tool[5], "-o", tmp], check=True)
            inv.require(inv.sha(Path(tmp).read_bytes()) == tool[6], "SDK download checksum mismatch")
            os.replace(tmp, archive)
        finally:
            Path(tmp).unlink(missing_ok=True)
    distpin = dict(pin, sha256=tool[6])
    distribution = inv.archive_files(archive, distpin)
    inv.require(inv.sha(distribution["bin/go"]) == tool[4], "SDK Go executable checksum mismatch")
    source = inv.archive_files(source_cache / pin["filename"], pin)
    # Authenticate the cached upstream tree as well; this is the root other
    # corpus lanes reuse, and merging must not conceal a source edit there.
    inv.verify_source(source_cache / "go", source)
    for name in set(source) & set(distribution):
        inv.require(source[name] == distribution[name], "source/distribution bytes disagree: " + name)
    merged = dict(distribution, **source)
    if output.exists():
        inv.verify_source(output, merged)
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix="sdk-stage-", dir=output.parent))
        try:
            # Preserve official executable modes from both archives. Tools and
            # source scripts may be invoked by native compiler unit tests.
            modes = {}
            for filename in (archive, source_cache / pin["filename"]):
                with tarfile.open(filename, "r:gz") as tf:
                    for member in tf:
                        if member.isfile():
                            modes[member.name.removeprefix("go/")] = member.mode & 0o777
            for name, data in merged.items():
                p = stage / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(data)
                p.chmod(modes[name])
            os.rename(stage, output)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    identity = {"schema": "go-full-sdk/v1", "root": str(output.resolve()), "release": pin["release"], "goos": goos, "goarch": goarch,
                "source_archive": {"path": str((source_cache / pin["filename"]).resolve()), "sha256": pin["sha256"]},
                "distribution_archive": {"path": str(archive.resolve()), "sha256": tool[6]},
                "go": inv.fingerprint("bin/go", merged), "source_files": len(source), "merged_files": len(merged),
                "manifest_sha256": inv.sha("".join(name + "\t" + inv.sha(data) + "\n" for name, data in sorted(merged.items())).encode())}
    return identity


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source-cache", type=Path, default=inv.REPO / ".cache/go-full")
    p.add_argument("--cache", type=Path, default=inv.REPO / ".cache/go-full-sdk")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--verify-existing", action="store_true", help="authenticate only; never download or materialize missing paths")
    p.add_argument("--goos", required=True)
    p.add_argument("--goarch", required=True)
    args = p.parse_args()
    print(json.dumps(prepare(args.source_cache, args.cache, args.output, args.goos, args.goarch, args.verify_existing), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as exc:
        print("FATAL: " + str(exc), file=sys.stderr)
        sys.exit(2)
