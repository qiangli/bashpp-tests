# The Go oracle

The `tests/_oracles/` note describes the differential method this suite is built
on: run the Go program with a pinned toolchain as an **oracle**, run the
independently authored bash++ form, compare observable behaviour. That method
needs a trustworthy left-hand side. This directory is it.

`tools/go-oracle` executes a reviewed, bounded tranche of the official Go 1.27.0
test corpus with the pinned Go 1.27.0 toolchain and writes one machine-readable
record per file. **No claim about Bash++ is made here, and none may be derived
from these results.** Everything below is a statement about what upstream's own
tests do under upstream's own compiler.

## Scope: seven of upstream's seventeen actions

> This is a **bounded seven-action tranche**. It is **not** upstream's runner
> (`src/cmd/internal/testdir/testdir_test.go`, historically `test/run.go`), and
> a green result here says nothing about the ten actions it does not execute.

| executed here (7) | deliberately not executed (10) |
|---|---|
| `run`, `build`, `errorcheck`, `compile`, `compiledir`, `rundir`, `runoutput` | `asmcheck`, `builddir`, `buildrun`, `buildrundir`, `errorcheckandrundir`, `errorcheckdir`, `errorcheckoutput`, `errorcheckwithauto`, `runindir`, `skip` |

The reasons are recorded one per action in `unsupportedActions`
(`tools/go-oracle/recipe.go`), printed by `run.sh`, published in the run summary
under `unsupported_actions`, and pinned in `pin.tsv`. `checkActionCoverage`
re-derives upstream's action vocabulary from the **pinned runner source** and
fatals unless the seven and the ten together are exactly that vocabulary — so a
new upstream action cannot slip in unclassified, and this tranche cannot drift
into implying a full `run.go`.

Offering an unimplemented upstream action to the driver is a fatal error that
names the action, the reason, and the seven that *are* executed. It is never a
skip and never an N/A.

## What was wrong with the previous shape

The corpus work before this slice classified each file from its action header —
`// run`, `// errorcheck`, `// compile` — and stopped. That contract cannot
distinguish a green suite from an empty one, because every count it printed was
read out of the same inventory row it was meant to be checking. It also could
not tell you whether `compiledir` means anything at all, since nothing ever
compiled a directory.

This slice deletes that idea rather than extending it. A file counts as executed
only when a process was spawned for it, and the argv, exit code, wall duration
and produced artifact of that process are in the output.

## Semantics

The action semantics are the upstream runner's. That runner was
`GOROOT/test/run.go` historically and is
`GOROOT/src/cmd/internal/testdir/testdir_test.go` as of Go 1.21. The driver is a
clean-room reimplementation of it, restricted to the tranche-1 action set, and it
**refuses to run** unless that upstream file is byte-identical to the one it was
written against — see `semantics_sha256` in `pin.tsv`. Semantic drift is
fail-closed, not silent.

| action | what actually happens |
|---|---|
| `run` | `go tool compile` → `go tool link` → execute; output compared to `<name>.out` |
| `build` | `go build -o a.exe <file>` |
| `errorcheck` | `go tool compile -e -d=panic -C`; compilation **must** fail, and every `// ERROR "regex"` must match a real diagnostic — with unannotated diagnostics failing just as loudly |
| `compile` | `go tool compile` on the single file |
| `compiledir` | every package of the sibling `<name>.dir`, in lexicographic file order, through a generated `importcfg` |
| `rundir` | as `compiledir`, then link the last package and run it; output compared |
| `runoutput` | run the file, treat its **stdout as a Go program**, write it to `tmp__.go`, run *that*, compare its output |

Upstream structure is preserved rather than flattened. Directory grouping is a
real dependency-ordered package sequence, not a bag of files. Generator semantics
really generate: the `runoutput` artifact recorded in the results is the
generated program, not the file that printed it. Only the upstream `dirs` list
counts as a test location, so a `.dir` subdirectory is treated as inputs and is
rejected if it appears in a tranche.

Files in upstream's `types2Failures` set are expected to fail, and a pass there
is reported as a failure — the oracle agrees with upstream about which red is the
correct red.

## What is asserted, not merely recorded

An earlier shape of this driver *measured* every artifact and *asserted* none of
them: a compile that exited 0 and wrote nothing was recorded as
`artifact_bytes: 0` next to `status: "pass"`, because the measurement and the
verdict were independent numbers. Every compile, link and build step now declares
what it must produce, and the claim is checked after the process exits:

| kind | asserted |
|---|---|
| `goarchive` | exists, regular file, non-empty, begins `!<arch>\n` (`go tool compile` output, both `.o` and `.a`) |
| `executable` | exists, regular file, non-empty, native object format (ELF / Mach-O / PE), mode `+x` |
| `gosource` | exists, regular file, non-empty — the `runoutput` `tmp__.go`. Deliberately *not* required to compile: a generator that emits broken Go is a real finding, and swallowing it here would hide it |

`errorcheck` declares no artifact, because an errorcheck file is *required* to
fail compilation; demanding an object would assert the opposite of its contract.

The regressions are `TestFakeGoProducesZeroArtifact` and
`TestFakeGoOmitsArtifactEntirely`: a sabotage toolchain that exits 0 for every
compile, link and build and writes a zero-byte file (or none at all). Every file
must fail, and it must fail *on the artifact*, with the recorded step exit still
0.

## Provenance

Three inventories, and **all of them are mandatory driver flags**. There is no
mode in which this driver produces results without them — an optional digest gate
is off in exactly the runs that most need it.

### 1. The corpus files — `docs/go-corpus/inventory.tsv`

Every `.go` file the driver reads (the test case *and* the members of its
`.dir`) is digest-checked before it is compiled, so a locally edited refresh
cache cannot be reported as an official-corpus result.

### 2. The auxiliary inputs — `aux-inventory.tsv`

The corpus inventory covers `test/**/*.go` and nothing else. That left every
other byte the driver *reads* unchecked, and a `.out` file **is** the expected
result — so an unchecked `.out` is an unchecked oracle. `aux-inventory.tsv`,
generated mechanically by `tools/go-oracle/select-aux.sh`, pins:

- `expected_output` — the sibling `<name>.out`, for every action that consumes
  one (`run`, `rundir`, `runoutput`). **`presence=absent` is a real assertion**:
  with no `.out`, upstream's rule is that the program must print *nothing*, so a
  `.out` created after review silently rewrites the expectation.
- `dir_manifest` — the sibling `<name>.dir` as a whole: the member count, and a
  digest over the sorted `"<relpath>\t<sha256>"` listing. This catches an
  **added** or **deleted** member, neither of which is an edit to any file the
  corpus inventory lists, and both of which change the package grouping or the
  compile order.
- `dir_input` — every non-`.go` member of a `.dir` (`.s`, `.h`, …), which the
  corpus inventory by construction cannot cover.

Reading a sidecar with no reviewed row is fatal. The tamper regressions are
`TestSidecarOutputMutationIsFatal`,
`TestSidecarAppearingWhereReviewedAbsentIsFatal`,
`TestSidecarDisappearingIsFatal`, `TestUnpinnedSidecarIsFatal`,
`TestDirMemberAddedIsFatal`, `TestDirMemberRemovedIsFatal` and
`TestNonGoDirInputIsDigested`.

### 3. The toolchain — `toolchain.tsv`

`go version` prints a string, and a five-line shell script prints it just as
convincingly — this package's own mutation tests forge it on purpose. So the
identity of the toolchain is established in three layers, and only the first is
the forgeable one:

1. **`go version`** — kept for a clear error message, explicitly not trusted.
2. **GOROOT source identity.** The candidate's own GOROOT must ship the
   byte-identical upstream sources of the pinned release: `VERSION`, `go.env`,
   `src/cmd/internal/testdir/testdir_test.go`, `src/runtime/proc.go`,
   `src/go/build/build.go`. Those digests come from
   `go1.27.0.src.tar.gz`, whose SHA-256 is published on go.dev/dl and verified by
   `tools/go-corpus/refresh.sh`. Platform-independent, and unsatisfiable by a
   script: a fake `go` has no GOROOT carrying the pinned upstream sources.
3. **Binary identity.** The resolved `go` must be a native executable whose
   SHA-256 equals the reviewed digest for this GOOS/GOARCH — recorded next to
   *two independent official origins*: the go.dev/dl published archive checksum,
   and the `golang.org/toolchain` module zip hash that `sum.golang.org` attests.

The `darwin/arm64` row was established by downloading
`go1.27.0.darwin-arm64.tar.gz`, confirming its published SHA-256, and observing
that its `bin/go` is byte-identical to the module-cache distribution's. **A
platform with no reviewed row is fatal, not skipped** — an unreviewed toolchain
is exactly what the gate exists to refuse.

## Upstream `go env` and timeout semantics

The tranche runs in the environment upstream's runner would give it, read from
the **pinned toolchain** via `go env -json` — not from the driver binary's own
`runtime.GOOS`, which is a different question that only coincides on a native
build:

- `GOOS` / `GOARCH` / `CGO_ENABLED` drive build-constraint evaluation.
- `GOEXPERIMENT` and `GODEBUG` are the *base* for the recipe's `-goexperiment`
  and `-godebug` flags, which **append** comma-separated exactly as upstream
  appends them. Replacing instead of appending would drop the toolchain's own
  setting and run the test in a different environment than upstream does.
- The `run` fast path (skip the `go` command, compile and link directly) is taken
  only under upstream's full condition: no flags, empty `GO_GCFLAGS`, **and**
  `GOOS`/`GOARCH`/`GOEXPERIMENT`/`GODEBUG` all still unchanged. Dropping those
  four conditions silently runs a `-goexperiment` or `-godebug` test *without*
  its environment.
- `$GO_TEST_TIMEOUT_SCALE` multiplies every `-t N` recipe timeout, as upstream
  does; an unparseable value is fatal rather than silently 1.

All of it is republished in the summary's `go_env` block, so a result file states
the environment it was taken in.

## Every fatal path leaves evidence

`fatalf` writes the summary — verdict `fatal`, the reason, and the
executed/reported/pass/fail/skip counts reached so far — and prints it as one
JSON line on stdout, on **every** exit path. The results file written up to that
point is flushed too. A fatal run that produced only prose would force the next
reader to guess whether anything ran; `TestFatalPathsAlwaysEmitASummary` and
`TestFatalMidRunReportsWhatAlreadyExecuted` are the regressions.

## The denominator

`tranche-001.tsv` is the denominator. It is produced by a mechanical,
outcome-blind rule (`tools/go-oracle/select-tranche.sh`): within each action, the
first five inventory rows in lexicographic path order whose directory is an
upstream test directory. Nothing was chosen or dropped because of how it behaved.
A tranche curated by result would make its own green verdict meaningless, which
is the same defect as inferring a fixture's status from its outcome.

The driver fails closed on all three of:

- the number of records is not the number of tranche rows;
- no file executed a command;
- no command was spawned at all.

`tools/go-oracle/validate-tranche.sh` re-derives the selection and diffs it, and
cross-checks every row against the reviewed corpus inventory. Every corpus file
the driver reads — the test case *and* the files of its `.dir` — is digest-checked
against `docs/go-corpus/inventory.tsv` before it is compiled, so a locally edited
refresh cache cannot be reported as an official-corpus result.

## Running it

```sh
tools/go-corpus/refresh.sh          # networked, once: fetch and verify go1.27.0
tools/go-oracle/select-aux.sh .cache/go-corpus/go1.27.0 > docs/go-oracle/aux-inventory.tsv
tools/go-oracle/run.sh              # offline: gates, then execute the tranche
tests/go-oracle/validate_oracle.sh  # the self-tests, including the mutation suite
```

`select-aux.sh` is the only step that needs the refreshed corpus; its output is
reviewed and committed, and `validate-tranche.sh` re-checks it offline
afterwards.

`harness/run.sh` runs the oracle on every invocation and is fatal if it does not
execute cleanly. `GO_ORACLE=off` disables it, as a deliberate declaration that
the invocation is not checking the corpus.

Results land in `.cache/go-oracle/` (`GO_ORACLE_OUT_DIR` to relocate). They are
not committed: they are measurements of a particular host at a particular
moment, and a checked-in copy would drift into being quoted as a standing claim.

## Result schema (`bashpp-tests/go-oracle/v1`)

One JSON object per line of `tranche-001.results.jsonl`. Host-specific paths are
normalized to `$GOTOOL`, `$GOROOT_TEST`, `$CORPUS` and `$WORK` so two runs are
diffable; the real values are recorded once in the summary.

```json
{
  "path": "test/alias3.go",
  "dir": ".",
  "go_file": "alias3.go",
  "action": "rundir",
  "declared_action": "rundir",
  "recipe": "rundir",
  "status": "pass",
  "expect_fail": false,
  "command": ["$WORK/t-0012/a.exe"],
  "exit": 0,
  "duration_ms": 414,
  "artifact": "a.exe",
  "artifact_kind": "executable",
  "artifact_bytes": 2012866,
  "artifact_sha256": "fd10dd…",
  "steps": [
    {
      "command": ["$GOTOOL", "tool", "compile", "-e", "-D", "test",
                  "-importcfg=$WORK/t-0012/importcfg", "-o", "test/a.a",
                  "-p", "test/a", "$GOROOT_TEST/alias3.dir/a.go"],
      "dir": "$WORK/t-0012", "exit": 0, "duration_ms": 16,
      "artifact": "test/a.a", "artifact_kind": "goarchive",
      "artifact_bytes": 106244, "artifact_sha256": "441f59…"
    }
  ]
}
```

The example above is illustrative, not a recorded result.

`status` is the verdict (`pass`, `fail`, `skip`); `exit` is the raw exit code of
the decisive command and is deliberately *not* the verdict. An `errorcheck` file
that passes exits non-zero, because that is what passing means for it.

`skip` is only ever produced by a build constraint that excludes the host, and
carries the offending line in `skip_reason`. Nothing is skipped for being
unimplemented — there is nothing to implement here.
