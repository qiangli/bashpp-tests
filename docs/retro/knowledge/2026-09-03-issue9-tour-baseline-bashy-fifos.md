# Retro (Issue 9): tour baseline under bashy — FIFOs that never EOF

**Date:** 2026-09-03 · **Story:** docs/todo/4895df27bdb9-tour-executor-v2-go-1-27-exact-pin-and-fail-closed.md
**Outcome:** 97/97 pinned examples built/executed under go1.27.0; offline validator + 13 tamper probes green; harness wired.

## What the story asked for

Execute every applicable pinned tour example under a checksum-verified Go toolchain,
record build/run outcomes plus content hashes and file modes to TSV, gate those
results offline, prove the gate with tamper self-tests, and document the pins
(toolchain.tsv, helpers.tsv, baseline-pin.tsv).

## What actually happened

Each symptom looked like a bug in *my* script before it was a quirk of the runtime:

| Symptom | Suspected cause | Actual cause |
|---|---|---|
| Loop still running after all 97 rows processed | build hang, timeout logic | `while … done < <(cmd)` — bashy's process substitution creates a real FIFO (sh-np-…) whose writer never closes, so read never sees EOF and the loop parks forever |
| `bad substitution` at startup | my quoting | `${#var:-}` — invalid parameter expansion, bashy rejects it, plain bash tolerated my typo differently |
| `cp` failing mid-run | permissions | destination subdir never created (`mkdir -p` missing before copy) |
| Helper tests failing resolve | module mismatch | definition-order bug — helpers provisioned before `bounded_run`/GOWORK pruning existed |
| Omit-tagged files failing `go build ./...` | constraint bypass impossible | explicit-file build (`go build file.go`) evaluates `//go:build OMIT` off and compiles the single file |

## Why it took so long to see

The hang was **silent**: the 97 rows had all been written to records.tsv, ps showed
`bash.real` + `sh-np-` FIFO descriptors, and nothing errored. Two independent
observers (records count + ps) were needed before "still running" could be
attributed to the FIFO rather than the workload.

## Rules distilled

1. **Feed read-loops from materialized files, never process substitution** — under
   bashy, `< <(cmd)` parks on a FIFO with no writer EOF. `cmd > "$tmp"; done < "$tmp"`
   is semantically identical and terminates.
2. **Prefer explicit files over pipes between long stages** anyway: they double as
   run evidence (records.tsv) and are inspectable when a stage wedges.
3. **A silent still-running stage needs two observations before calling it hung** —
   output progress plus process/FIFO state — and a completed downstream artifact
   disproves a hang.
4. **Host binaries exec fine through bashy** (`go`, `pgrep`, `ps`, `stat`, `shasum`,
   `ruby`): when pure-Go userland semantics are doubtful, delegate to a real
   binary with `env`/absolute path rather than trusting the reimplementation.
5. **Invalid parameter expansions differ by runtime**: `${#x:-}` is a hard error in
   bashy where interactive bash reports it differently. Keep expansions boring in
   scripts meant to run under a bash reimplementation.
6. **Timeouts belong in the parent, not the child** — `timeout`/bounded run wraps
   each `go build`/`go run` so one wedged example cannot wedge the sweep, and the
   parent's own poll deadline (with SIGKILL escalation) bounds the wrapper itself.

## What to reuse next time

- The bashy hang signature: loop stalls at exactly-N-records + `sh-np-*` FIFO in ps.
- The four-file shape of a pinned baseline: pin (input identity) → run (records) →
  validate (offline gate) → tamper (gate proves itself). The gate must never call
  the network; tamper must prove each failure mode the gate claims to catch.
- GOROOT-foreign pins (`.cache/tour/pins`) give toolchain identity without touching
  `go env GOROOT`, and explicit-file builds make omit-tagged tour files compilable.
