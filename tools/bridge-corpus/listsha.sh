#!/usr/bin/env bash
# listsha.sh — sha256 of an inventory list, framed exactly as sh's reviewed
# generator frames its inventorySHA256 constant: strings.Join(paths, "\n")
# followed by one trailing "\n". awk `print` emits precisely that for a
# one-path-per-line input, so the digest is computable offline with no Go
# toolchain — verify.sh relies on that.
#
# Input: paths on stdin (or a file argument). Blank lines are dropped, which
# matches the generator's non-empty path list.
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "usage: listsha.sh [file]" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  awk 'NF { print }' "$1" | shasum -a 256 | awk '{print $1}'
else
  awk 'NF { print }' | shasum -a 256 | awk '{print $1}'
fi
