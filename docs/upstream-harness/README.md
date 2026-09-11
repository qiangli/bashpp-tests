# S157.1: authenticated upstream Go testdir seam

Story `b7560ec00ec1` keeps Go 1.27's own
`src/cmd/internal/testdir/testdir_test.go` as the semantic authority. The frozen
copy is byte-for-byte upstream Go 1.27.0, SHA-256
`54900709a1fae5f469aa7bf59b22660f6fb9eb169e84f9c0d9760f0fe38444f4`.
The BSD license is retained beside it.

The only behavioral integration is the reviewed unified diff
`tools/upstream-harness/testdata/instrumented/testdir_test.go.patch`, SHA-256
`b4e84ccac3d203b06e6e21141263d5be766a2f640cf64c657f05b73cdb523829`.
It is 37 localized hunks (72 additions and 27 removals) in the original control
flow. It does not replace or copy the action switch. The plain event writer is
`bashpp_events_test.go`, SHA-256
`73c2f0c6be29269be4914dd110274061195a60288c02123da542b3822cda9c83`.
All three identities are fail-closed pins in `pin.tsv`.

`tools/upstream-harness/gate.sh` is the executable contract. It:

1. authenticates the frozen source, patch, Go event hook, Go 1.27 runner source, and
   every selected matrix input;
2. applies the patch to a fresh copy and supplies both patched runner and event
   writer through `go test -overlay`;
3. runs the unmodified and instrumented harnesses with the same Go 1.27 tool,
   corpus bytes, flags, and subtest selector;
4. compares the actual `go test -json` terminal verdict for every subtest and
   validates the event grammar and case-specific decisions.

Run it from anywhere in this repository:

```sh
tools/upstream-harness/gate.sh
```

`GO127_TOOL` may name the reviewed Go 1.27 binary. `GO_CORPUS_ROOT` may name an
official source tree. If the source-tarball cache is absent, the gate may use an
installed Go source tree only after every selected root and companion proves
byte-identical to the explicit Go 1.27 matrix digest. The harness and compiler
remain Go 1.27 in either case.

## Where authority remains

The patch observes the upstream decisions at their existing sites:

| Concern | Upstream decision site | Event |
|---|---|---|
| directive/action | first eligible comment, `splitQuoted`, unchanged action switch | `selection` |
| applicability/skip | `shouldTest` result and `skip` action | `selection` with reason |
| flags/env/timeout | existing recipe flag loop | `selection` |
| command/cwd/env | existing `runcmd` and asmcheck `exec.Command` sites | ordered `phase`, including structured action and recipe flags |
| compile inputs/program argv | arguments passed explicitly by each switch/helper call site | `phase` |
| directory companions | results already returned by `goDirPackages`, or `gos`/`asms` already selected by builddir | `companions` |
| `go run` recipe operands | the already-parsed recipe operand slice at the exact `go run` call site | leading `.go` compile inputs and remaining program argv; never filesystem-probed |
| generated files | immediately after upstream's successful writes | `generated` |
| golden output | `checkExpectedOutput`, after upstream resolves presence/absence and bytes | `comparison` |
| diagnostics | `errorCheck`, after upstream collects its exact source pairs | `comparison` |
| assembly | each selected environment comparison, plus every target/no-check bypass | `comparison` / `bypass` |
| verdict/terminal | the unchanged caller around `test.run`, including deferred Skip/Fatal observation | `verdict` / `terminal` |

The event schema is `bashpp-tests/upstream-testdir-event/v1`. Each JSON line is
a typed record with upstream subtest identity and a dense per-subtest `order`.
Phase records include phase kind, exact process argv, compile inputs, program
argv, cwd, command-specific environment delta, and timeout. Selection records
include action, applicability, recipe values, environment delta, and expected
error behavior. Comparison and terminal records preserve the upstream result.

For `cmplxdivide.go`, upstream hands `cmplxdivide1.go` to `go run` as a parsed
recipe operand. At that exact command boundary, the seam records both files as
compile inputs and records an empty program argv. It does not probe or select
any corpus path.

## Deliberate boundary

This story adds no planner, backend, packet, hash-chain, cleanup, timeout, or
adversarial evidence framework. Events are plain observation data. Story
S157.2 will consume them for the Bash++ backend. The independent observer in
S157.3 will be Go/shell-only and will not decide recipe semantics. Converting
the Go harness to Bash++ remains future work outside Sprint 157.

The matrix is structural rather than a corpus claim: nine cases cover the two
required anchors, compile, expected compile error, directory/package selection,
generated output, asmcheck bypasses, explicit skip, and build-constraint
exclusion. `issue21808.go` proves the upstream combined bytes have length five
(`A\n\nB\n`); byte-ordered capture remains a later Go/shell integration job.

## S157.1 verification

The local command `bashy gate --command 'tools/upstream-harness/gate.sh'`
passed in 27.245 seconds. On 2026-09-11 at 05:38:52Z, the same gate passed on
the authorized Linux host from fresh `/srv/sprint157/s157.1`, using
`go1.27.0 linux/amd64` at SHA-256
`1db869c560a193573a71be466a34e0d4abb7792d78165c6102cdda069276a3a8`
and the frozen upstream runner at the pinned SHA-256 above. Coordinator PID
973620 was the sole retained authoritative run; PID 972459 had already exited
and been reaped. All 9/9 native and instrumented terminal verdicts matched,
and a post-run process-table check found no surviving gate or test process.
