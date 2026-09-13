#!/usr/bin/env bash
# Sprint: #155; Story: S155.8; Story-ID: f9942bd4459a
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# It reports the pinned version so the digest check, rather than the older
# version guard, is the first failure. No corpus work may start afterward.
fake_go="$tmp/go"
want=1db869c560a193573a71be466a34e0d4abb7792d78165c6102cdda069276a3a8

# A small wrapper is needed because an arbitrary wrong binary would fail the
# version check first and would not prove the SHA-256 guard is active.
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf '%s\n' 'if test "${1:-}" = version; then'
	printf '%s\n' '  printf "%s\\n" "go version go1.27.0 linux/amd64"'
	printf '%s\n' '  exit 0'
	printf '%s\n' 'fi'
	printf '%s\n' 'exit 99'
} > "$fake_go"
chmod +x "$fake_go"
got=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$fake_go" | awk '{print $1}'; else shasum -a 256 "$fake_go" | awk '{print $1}'; fi)
test "$got" != "$want" || { printf 'test setup accidentally matches pinned Go binary\n' >&2; exit 1; }

set +e
GO127_TOOL="$fake_go" "$root/tools/upstream-harness/corpus-gate.sh" >"$tmp/stdout" 2>"$tmp/stderr"
rc=$?
set -e
test "$rc" -eq 1 || { printf 'expected exit 1, got %s\n' "$rc" >&2; exit 1; }
expected="FAIL pin go_binary_sha256: expected $want, got $got"
grep -Fx "$expected" "$tmp/stderr" >/dev/null || {
	printf 'missing exact failure line: %s\n' "$expected" >&2
	cat "$tmp/stderr" >&2
	exit 1
}
printf 'PASS corpus gate rejects wrong Go binary SHA-256\n'
