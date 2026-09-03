#!/usr/bin/env bash
# Genuine descendant leak used by the process-mutation tests.
#
# The grandchild moves itself into a NEW session, so the gate's process-group
# TERM/KILL provably cannot reach it and kill(0, -pgid) cannot even see it.
# This script does not exit until the grandchild has confirmed the escape --
# otherwise the descendant would still be in this process group when the gate
# cleans up, and the gate would (correctly) reap it instead of reporting a
# leak. Its stdout/stderr are redirected away so the gate's reader threads
# still reach EOF: the only thing the survivor keeps holding is the inherited
# liveness descriptor.
#
# Nothing here asserts a state; the gate observes one. The survivor exits on
# its own, so the test never strands a process.
set -euo pipefail
ready="$(mktemp "${TMPDIR:-/tmp}/gbe-leak.XXXXXX")"
ruby -e 'Process.setsid; File.write(ARGV[0], "detached"); sleep 3' "$ready" >/dev/null 2>&1 &
deadline=$((SECONDS + 10))
while [ ! -s "$ready" ]; do
  [ "$SECONDS" -lt "$deadline" ] || { echo "descendant never left the process group" >&2; exit 3; }
done
rm -f "$ready"
exit 0
