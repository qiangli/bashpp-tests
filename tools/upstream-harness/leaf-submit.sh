#!/bin/bash
# Sprint: #162; Story: S162.0; Story-ID: cda64bde8fea
#
# leaf-submit.sh — enqueue leaf work on a leaf host so it SURVIVES the caller's
# session. A worker that runs `ssh host 'leaf-run.sh …'` and then exits takes
# the remote job down with it (SIGHUP through the ssh session): Sprint 162
# lost four queued leaves and five candidate rebuilds that way in one hour.
# This wrapper detaches the job (setsid + nohup, stdin from /dev/null) and
# returns at once with the log path; poll $LEAF_BASE/leaf-<name>/logs/status.txt
# (or the job log) for the result.
#
#   usage: leaf-submit.sh <job-name> -- <command> [args...]
#          leaf-submit.sh rebuild-x   -- rebuild-candidate.sh x --sh-bundle /path
#          leaf-submit.sh leaf-x-r1   -- leaf-run.sh x-r1 /path/roots.tsv --candidate x
#          leaf-submit.sh chain-x     -- bash -c 'rebuild-candidate.sh x … && leaf-run.sh x-r1 …'
#
#   env:   LEAF_BASE (default /srv/sprint162); commands are resolved on PATH
#          and in $LEAF_BASE/bin.
set -eu
base=${LEAF_BASE:-/srv/sprint162}
name=${1:?usage: leaf-submit.sh <job-name> -- <command> [args...]}
shift
test "${1:-}" = "--" || { printf 'leaf-submit: expected -- before the command\n' >&2; exit 2; }
shift
test $# -gt 0 || { printf 'leaf-submit: no command\n' >&2; exit 2; }
case $name in */* | . | ..) printf 'leaf-submit: bad job name %s\n' "$name" >&2; exit 2 ;; esac
mkdir -p "$base/logs"
log=$base/logs/job-$name.log
if test -e "$log"; then printf 'leaf-submit: %s exists — job names are fresh by rule\n' "$log" >&2; exit 2; fi
export PATH=$base/bin:$PATH LEAF_BASE=$base
{
	printf 'job=%s submitted=%s argv=' "$name" "$(date -u +%FT%TZ)"
	printf '%q ' "$@"
	printf '\n'
} > "$log"
setsid nohup "$@" >> "$log" 2>&1 < /dev/null &
printf 'submitted job %s (pid %s): %s\n' "$name" "$!" "$log"
