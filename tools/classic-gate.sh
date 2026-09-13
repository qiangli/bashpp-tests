#!/usr/bin/env bash
# Sprint: #155; Story: S155.8; Story-ID: f9942bd4459a
#
# Reproduce the Sprint 147 Classic substrate input check against immutable,
# caller-selected trees. A failing lane is evidence: record it once, continue
# through every lane, name all failures, and return 1 without retrying.
set -euo pipefail

usage() {
	printf 'usage: %s --bashy DIR --sh DIR --coreutils DIR --out DIR\n' "${0##*/}" >&2
	exit 2
}

bashy_tree= sh_tree= coreutils_tree= out=
while test "$#" -gt 0; do
	case "$1" in
		--bashy|--sh|--coreutils|--out)
			test "$#" -ge 2 || usage
			case "$1" in
				--bashy) bashy_tree=$2 ;;
				--sh) sh_tree=$2 ;;
				--coreutils) coreutils_tree=$2 ;;
				--out) out=$2 ;;
			esac
			shift 2 ;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done
test -n "$bashy_tree" && test -n "$sh_tree" && test -n "$coreutils_tree" && test -n "$out" || usage

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for tree in "$bashy_tree" "$sh_tree" "$coreutils_tree"; do
	git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 || { printf 'classic-gate: not a Git tree: %s\n' "$tree" >&2; exit 2; }
done
bashy_tree=$(CDPATH= cd -- "$bashy_tree" && pwd)
sh_tree=$(CDPATH= cd -- "$sh_tree" && pwd)
coreutils_tree=$(CDPATH= cd -- "$coreutils_tree" && pwd)

if test -e "$out" && test -n "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"; then
	printf 'classic-gate: output directory is not empty: %s\n' "$out" >&2
	exit 2
fi
mkdir -p "$out/logs"
out=$(CDPATH= cd -- "$out" && pwd)
identities="$out/.identities.tsv"
lanes="$out/.lanes.tsv"
: > "$identities"
: > "$lanes"

# An inherited skip would invalidate both 86-fixture denominators. This gate
# never sets or forwards BASH_TEST_SKIP.
unset BASH_TEST_SKIP

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	else shasum -a 256 "$1" | awk '{print $1}'
	fi
}
one_line() { "$@" 2>&1 | awk 'NR == 1 { print; exit }'; }
identity() { printf '%s\t%s\n' "$1" "$2" >> "$identities"; }

identity schema classic-gate-v1
identity bashy_commit "$(git -C "$bashy_tree" rev-parse HEAD)"
identity sh_commit "$(git -C "$sh_tree" rev-parse HEAD)"
identity coreutils_commit "$(git -C "$coreutils_tree" rev-parse HEAD)"
identity go_version "$(one_line go version)"
identity go_env "$(go env GOOS GOARCH | awk 'BEGIN{s=""} {s=s $0 "/"} END{sub(/\/$/,"",s); print s}')"
identity platform "$(one_line uname -a)"
identity bashy_binary "$bashy_tree/bin/bashy.real"
if test -f "$bashy_tree/bin/bashy.real"; then
	identity bashy_binary_sha256 "$(sha256 "$bashy_tree/bin/bashy.real")"
else
	identity bashy_binary_sha256 missing
fi
identity bash_test_skip unset

failures=
run_lane() {
	lane=$1 kind=$2 cwd=$3 command_text=$4
	shift 4
	log="$out/logs/$lane.log"
	printf '\n===== %s =====\n%s\n' "$lane" "$command_text"
	set +e
	( cd "$cwd" && unset BASH_TEST_SKIP && "$@" ) 2>&1 | tee "$log"
	rc=${PIPESTATUS[0]}
	set -e

	denominator=0 passed=0 failed=0 skipped=0 timed_out=0 unit=commands
	case "$kind" in
		classic)
			set -- $(awk '/^Results:/ {p=$2; f=$4; s=$6; t=$8} END {gsub(/[^0-9]/,"",p); gsub(/[^0-9]/,"",f); gsub(/[^0-9]/,"",s); gsub(/[^0-9]/,"",t); print p+f+s+t, p+0, f+0, s+0, t+0}' "$log")
			denominator=$1 passed=$2 failed=$3 skipped=$4 timed_out=$5 unit=fixtures ;;
		posix)
			denominator=$(awk '/startsites: (POSIX GATE OK|POSIX GATE FAILED)/ {for(i=2;i<=NF;i++) if($i ~ /^shapes[,.:]*$/) n=$(i-1)} END {gsub(/[^0-9]/,"",n); print n+0}' "$log")
			failed=$(awk '/^LEAK[[:space:]]/ {n++} END {print n+0}' "$log")
			passed=$((denominator - failed)); unit=shapes ;;
		gotest)
			passed=$(awk '/^(ok|\?)[[:space:]]/ {n++} END {print n+0}' "$log")
			failed=$(awk '/^FAIL[[:space:]]/ {n++} END {print n+0}' "$log")
			denominator=$((passed + failed)); unit=packages ;;
	esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$lane" "$command_text" "$denominator" "$unit" "$passed" "$failed" "$skipped" "$timed_out" "$rc" "logs/$lane.log" >> "$lanes"
	if test "$rc" -ne 0; then failures="${failures}${failures:+,}$lane"; fi
}

run_lane classic_off classic "$bashy_tree" \
	'make test-bash-container BASH53_OCI=podman' \
	make test-bash-container BASH53_OCI=podman
run_lane classic_on classic "$bashy_tree" \
	'make test-bash-container-bashpp BASH53_OCI=podman' \
	make test-bash-container-bashpp BASH53_OCI=podman

# Novi does not install a host Bash 5.3. Keep the supplied Darwin candidate in
# place and provide the parse-only GNU Bash oracle through one uniquely named
# container for this lane. Each exec is one distinct corpus probe; no failed
# probe or lane is retried, and cleanup names only our exact container.
host_arch=$(go env GOARCH)
bash53_oracle="$out/.bash53-oracle"
posix_runner="$out/.posix-runner"
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf '%s\n' 'exec podman exec -i "$CLASSIC_GATE_ORACLE" /usr/local/bin/bash "$@"'
} > "$bash53_oracle"
chmod +x "$bash53_oracle"
{
	printf '%s\n' '#!/usr/bin/env bash' 'set -u'
	printf '%s\n' 'name=$1; arch=$2; oracle=$3; candidate=$4; gate=$5'
	printf '%s\n' 'cleanup() { podman rm -f "$name" >/dev/null 2>&1 || true; }'
	printf '%s\n' 'trap cleanup EXIT INT TERM'
	printf '%s\n' 'podman run -d --rm --name "$name" --pull=missing --platform "linux/$arch" --network none --entrypoint /usr/local/bin/bash docker.io/library/bash:5.3 -c '\''while :; do sleep 3600; done'\'' >/dev/null || exit $?'
	printf '%s\n' 'CLASSIC_GATE_ORACLE=$name BASH53=$oracle BASHY=$candidate "$gate" --posix-gate'
} > "$posix_runner"
chmod +x "$posix_runner"
posix_container="classic-gate-posix-$$"
posix_command="podman run --name $posix_container docker.io/library/bash:5.3; BASH53=podman-exec:$posix_container BASHY=$bashy_tree/bin/bashy.real tools/startsites/classify.sh --posix-gate"
run_lane posix_isolation posix "$root" "$posix_command" "$posix_runner" \
	"$posix_container" "$host_arch" "$bash53_oracle" "$bashy_tree/bin/bashy.real" "$root/tools/startsites/classify.sh"
rm -f "$bash53_oracle" "$posix_runner"

run_lane bashy_go_lanes gotest "$bashy_tree" 'make test' make test
run_lane sh_short gotest "$sh_tree" 'go test -short ./...' go test -short ./...
run_lane coreutils_short gotest "$coreutils_tree" 'go test -short ./...' go test -short ./...

if test -n "$failures"; then
	identity result RED
	identity failed_lanes "$failures"
	identity exit_code 1
else
	identity result GREEN
	identity failed_lanes none
	identity exit_code 0
fi

{
	printf '# identities\nkey\tvalue\n'
	cat "$identities"
	printf '# lanes\nlane\tcommand\tdenominator\tunit\tpassed\tfailed\tskipped\ttimed_out\texit_code\tlog\n'
	cat "$lanes"
} > "$out/report.tsv"

awk -F '\t' '
	function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\r/, "\\r", s); gsub(/\n/, "\\n", s); gsub(/\t/, "\\t", s); return s }
	FNR == NR { key[++ni]=$1; val[ni]=$2; next }
	{ lane[++nl]=$1; cmd[nl]=$2; den[nl]=$3; unit[nl]=$4; pass[nl]=$5; fail[nl]=$6; skip[nl]=$7; tout[nl]=$8; rc[nl]=$9; logfile[nl]=$10 }
	END {
		printf "{\n  \"schema\": \"classic-gate-v1\",\n  \"identity\": {"
		for (i=1; i<=ni; i++) printf "%s\n    \"%s\": \"%s\"", (i==1 ? "" : ","), esc(key[i]), esc(val[i])
		printf "\n  },\n  \"lanes\": ["
		for (i=1; i<=nl; i++) {
			printf "%s\n    {\"name\":\"%s\",\"command\":\"%s\",\"denominator\":%d,\"unit\":\"%s\",\"passed\":%d,\"failed\":%d,\"skipped\":%d,\"timed_out\":%d,\"exit_code\":%d,\"log\":\"%s\"}", (i==1 ? "" : ","), esc(lane[i]), esc(cmd[i]), den[i], esc(unit[i]), pass[i], fail[i], skip[i], tout[i], rc[i], esc(logfile[i])
		}
		printf "\n  ]\n}\n"
	}' "$identities" "$lanes" > "$out/report.json"
rm -f "$identities" "$lanes"

if test -n "$failures"; then
	printf 'classic-gate: FAIL lanes: %s (recorded in %s)\n' "$failures" "$out" >&2
	exit 1
fi
printf 'classic-gate: PASS (recorded in %s)\n' "$out"
