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

## Sprint 149 gates

`backend.md` §Sprint 149 static seams describes the extended seam. The
packet gates are `tools/upstream-harness/{compile,build,errorcheck,compiledir,
asmcheck,errorcheckdir,builddir,errorcheckoutput,errorcheckwithauto,
typechecker}-gate.sh`, each over `docs/upstream-harness/<action>-matrix.tsv`
(root-list digest = the Sprint 142 packet manifest; companion digests pinned).
`typechecker-gate.sh` uses the second frozen upstream runner pair under
`testdata/upstream-types/` (types2 and go/types `check_test.go`, BSD license
retained) with `testdata/types-backend/` patches and hooks, and
`types-verify.go`. `residuals.tsv` is the retained-failure ledger every
non-green gate points at. The S157 `final-gate.sh` is superseded for Sprint 149
because it asserts the Sprint 149 trackers are still `todo`.

## Sprint 150 gates

`backend.md` §Sprint 150 dynamic and package seams describes the extended
seam. The packet gates are `tools/upstream-harness/{run,runoutput,buildrundir,
buildrun,rundir,errorcheckandrundir,runindir,package}-gate.sh`, each over
`docs/upstream-harness/<action>-matrix.tsv` (root-list digest = the Sprint 142
packet manifest; `.out` golden files and `.dir` companions pinned).
`package-gate.sh` uses a third frozen upstream runner — Go 1.27.0's own
`cmd/go/internal/test/test.go` under `testdata/upstream-go/` (BSD license
retained) with the seven-line patch and overlay bridge under
`testdata/go-backend/` — built through `-overlay` and proven native-equivalent
with the backend off before the 26 packages are replayed; `package-verify.go`
is its verifier. `residuals.tsv` carries every non-green root of both sprints.

## Sprint 151 corpus gate and partition

`tools/upstream-harness/corpus-gate.sh` is Barrier A: the whole Go 1.27
corpus through the three frozen upstream runners (`cmd/internal/testdir`,
`go/types` + `types2` `check_test`, patched `cmd/go`) in three lanes —
**native** (backend unset; the count authority and the reauthentication of
the native oracle), then Bash++ **interpreted** and **compiled**. It is the
packet-gate shape with the per-packet selector dropped; each backend lane's
terminal count must equal the native lane's. `BASHPP_CORPUS_ROOTS=<active
manifest>` is the leaf form (per-runner `-run` selectors derived from the
root ids, counts authenticated against the manifest); `BASHPP_CORPUS_SMOKE`
exercises the plumbing and never yields a verdict. `partition-emit.go` turns
the per-mode `go test -json` streams into owner manifests by first-line rule
and writes `active-summary.tsv`. The owner values are 151–154, `package`, `retained`, and
`unclassified`; `retained` is a recorded disposition, never a pass and never
dispatchable. Root ids are `testdir:<path>`,
`typechecker:<package>/<Test>/<file>`,
`package:<importpath>`. Under the exact upstream runners the corpus is
2,726 + 899 + 26 = **3,651** roots (the Sprint 142 inventory selected 743 of
the 899 typechecker leaves). `backend.md` §Sprint 151 describes the
backend-lane deadline.

## Sprint 162 partition v10.5

v10.5 adds the package owner to the D0 rule ledger. Every package: root is
owned by package in both modes, independent of its diagnostic; the 26 roots
move from 151 (9), retained (16), and unclassified (1). A compiled row is
never retained: body-less declarations, phase-seam/non-Go inputs, cgo and
compiler-artifact (-m, -live, -d=) failures move to 152, while interpreted
compiler-artifact rows remain retained. The two interpreted
errorcheckandrundir optimizer rows whose flags are nested in -gcflags
(closure3.go and linkname.go) remain retained with their missing verdicts.

Barrier B owner movement is therefore: 151 511 -> 502 (9 package roots),
retained compiled 93 rows -> 0 (16 package rows and 77 compiled product rows
move out), package 0 -> 26, and 152 gains the non-package compiled product
rows from the retained lane in addition to its existing 19 roots. The copied
backend-event evidence needed to regenerate the full v10.5 manifests was not
present in this checkout; run 0 is the authoritative regeneration venue.
