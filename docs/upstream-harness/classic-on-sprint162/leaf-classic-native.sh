#!/bin/bash
# Sprint: #162; Story: S162.6; Story-ID: 5c6251698ece
#
# leaf-classic-native.sh — the hermetic SERIAL Bash 5.3 gate (bashy `make
# test-bash`, tools/bash53suite) run natively on a Linux leaf host, Bash++ OFF
# and Bash++ ON, against the published base trees, in a fresh directory, under
# the host's single-coordinator lock. This is the Linux confirmation step of
# S162.6: the darwin observation (container gate: ON = cprint FAIL + procsub
# TIME) is re-measured with the same fixture runner and the same selector
# (BASHY_BASHPP=1 in the environment of the fixture runner, exactly what
# `make test-bash-container-bashpp` passes into the container).
#
#   usage: leaf-classic-native.sh <n>
#   env:   LEAF_BASE (default /srv/sprint162), LEAF_SDK (default /srv/sprint142)
#
# Output: $LEAF_BASE/classic-<n>/ — logs/*.log, logs/status.txt, debug-*/
# (bash53suite's want/got pairs for every failing fixture), and the manual
# procsub probe (a SIGQUIT goroutine dump of the hung shell).
set -u
base=${LEAF_BASE:-/srv/sprint162}
sdk=${LEAF_SDK:-/srv/sprint142}
n=${1:?usage: leaf-classic-native.sh <n>}
dir=$base/classic-$n
if test -z "${CLASSIC_LOCKED:-}"; then
	test -e "$dir" && { printf 'classic: %s exists (fresh name required)\n' "$dir" >&2; exit 2; }
	mkdir -p "$dir/logs"
	exec flock "$base/leaf.lock" env CLASSIC_LOCKED=1 LEAF_BASE="$base" LEAF_SDK="$sdk" "$0" "$n"
fi
cd "$dir" || exit 2
export PATH=$sdk/authenticated-sdk/bin:$PATH GOTOOLCHAIN=local GOFLAGS=-mod=mod GOMAXPROCS=2
unset BASH_TEST_SKIP BASHY_BASHPP
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a logs/status.txt; }
log "start classic-$n on $(uname -srm), $(go version)"
for r in bashy sh coreutils readline filebrowser; do
	test -d "$r/.git" || git clone -q "$base/base/$r" "$r"
	log "$r $(git -C "$r" rev-parse HEAD)"
done
cd bashy || exit 2

# 1. focused OFF (builds bin/bash + bin/bash.real, fetches the SHA-verified
#    fixture tree into the user cache, builds recho/zecho/xcase).
log "focused OFF: make test-bash TESTS='cprint procsub'"
make test-bash TESTS="cprint procsub" > ../logs/focused-off.log 2>&1
log "focused OFF rc=$? $(grep '^Results:' ../logs/focused-off.log)"

# 2. focused ON with a ps watcher (where does procsub sit while it hangs?).
mkdir -p ../debug-focused-on
(
	for i in $(seq 1 16); do
		sleep 5
		printf '=== t+%ds ===\n' $((i * 5))
		ps -eo pid,ppid,pgid,etime,stat,wchan:24,args | grep -E '[b]ash|[p]rocsub|[c]print' || true
	done
) > ../logs/focused-on-ps.txt 2>&1 &
watcher=$!
log "focused ON: BASHY_BASHPP=1 make test-bash-run TESTS='cprint procsub'"
BASHY_BASHPP=1 BASH53_DEBUG_DIR=$dir/debug-focused-on make test-bash-run TESTS="cprint procsub" > ../logs/focused-on.log 2>&1
log "focused ON rc=$? $(grep '^Results:' ../logs/focused-on.log)"
kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null

# 3. manual procsub probe: the fixture the way bash53suite launches it (same
#    env, idle-pipe stdin, cwd = tests), Bash++ ON, `-x` with PS4 carrying the
#    fixture line so the last executed line is in the log, a process-tree
#    snapshot at t+15 s, SIGQUIT at 30 s (a goroutine dump if the runtime still
#    owns the signal; the shell normally does, so KILL follows 5 s later).
tests=$(cd external/bash-5.3/tests && pwd)
sh_bin=$PWD/bin/bash
probe() { # probe <log> [selector env...]: one launch, 30 s bound, SIGQUIT dump
	out=$1; shift
	mkfifo "$dir/idle.fifo"
	sleep 3600 > "$dir/idle.fifo" & idle=$!
	(
		cd "$tests" && env -i PATH="$tests:/usr/bin:/bin:/usr/local/bin" HOME="$HOME" \
			THIS_SH="$sh_bin" _="$sh_bin" BUILD_DIR="$(dirname "$tests")" \
			BASH_TSTRAW=/tmp/classic-tstraw-$$ BASH_TSTOUT=/tmp/classic-tstout-$$ \
			BASH_SETPGRP=1 BASHY_SIGNAL_PAYLOAD="$sh_bin.real" GOTRACEBACK=all "$@" \
			PS4='+${LINENO}: ' timeout -s QUIT -k 5 30 "$sh_bin" -x ./procsub.tests < "$dir/idle.fifo"
		printf '\n[probe exit %s]\n' "$?"
	) > "$out" 2>&1 &
	probe_pid=$!
	sleep 15
	{ printf '=== process tree at t+15s ===\n'; ps -eo pid,ppid,pgid,stat,wchan:24,args | grep -E '[p]rocsub|[b]in/bash|[t]imeout'; } > "$out.ps" 2>&1
	wait "$probe_pid"
	kill "$idle" 2>/dev/null; wait "$idle" 2>/dev/null
	rm -f "$dir/idle.fifo" /tmp/classic-tstraw-$$ /tmp/classic-tstout-$$
}
log "manual procsub ON: (cd tests; BASHY_BASHPP=1 GOTRACEBACK=all timeout -s QUIT -k 5 30 bin/bash ./procsub.tests) stdin=idle pipe"
probe ../logs/procsub-on-sigquit.txt BASHY_BASHPP=1
log "manual procsub ON done: $(grep -c '^goroutine ' ../logs/procsub-on-sigquit.txt) goroutines dumped, $(tail -n1 ../logs/procsub-on-sigquit.txt)"
log "manual procsub OFF (control): same launch without the selector"
probe ../logs/procsub-off-control.txt
log "manual procsub OFF done: $(tail -n1 ../logs/procsub-off-control.txt)"

# 4. the full 86 serial, OFF then ON.
log "full OFF: make test-bash-run"
make test-bash-run > ../logs/full-off.log 2>&1
log "full OFF rc=$? $(grep '^Results:' ../logs/full-off.log)"
log "full ON: BASHY_BASHPP=1 make test-bash-run"
BASHY_BASHPP=1 BASH53_DEBUG_DIR=$dir/debug-full-on make test-bash-run > ../logs/full-on.log 2>&1
log "full ON rc=$? $(grep '^Results:' ../logs/full-on.log)"
grep -E '^\s+(FAIL|TIME|SKIP)' ../logs/full-off.log | sed 's/^/full OFF: /' | tee -a ../logs/status.txt
grep -E '^\s+(FAIL|TIME|SKIP)' ../logs/full-on.log | sed 's/^/full ON: /' | tee -a ../logs/status.txt
log "done classic-$n"
