# S157.2: direct Bash++ backend

Story `31520c72b5e0` keeps the authenticated Go 1.27
`cmd/internal/testdir` runner as the sole recipe authority. Two small patches
attach at its existing `planExec`/`runcmd` boundary. They do not select tests,
parse recipes, infer companions, or reproduce the action switch.

For an upstream `execute` phase, the backend receives the exact
`compileInputs` and `programArgv` slices already selected by the Go runner.
Interpreted mode invokes:

```text
bashy --bashpp --source=go --check --go-file <input> [...]
bashy --bashpp --source=go --go-file <input> [...] [-- <program argv>]
```

Compiled mode invokes `bashy transpile --bashpp --source=go` with the same
repeated `--go-file` inputs, builds the generated Go source with the pinned Go
1.27 tool and caller-supplied pinned shell runtime, and executes that artifact
with only `programArgv`. The original native Go command is never executed in a
backend phase. A minimal shell coordinator keeps check/run and
transpile/build/run inside the upstream command timeout boundary; it receives
only those direct-source commands, never the upstream native argv. A phase
without Go source inputs, a non-Go input, or a recipe phase without direct
run-program meaning fails explicitly as unsupported. Sprint 149 adds two
narrow exceptions: an upstream `compile` action's `compile` phase runs Bash++
check-only in interpreted mode, or transpile-with-map then pinned-Go build-only
in compiled mode. It never executes the generated program. Story S149.6 extends
the same seam to the upstream `build` action's single compile/build-only phase:
one selected root, an empty program argv, and the exact upstream flags and
environment. Interpreted mode is Bash++ direct `--check` only and explicitly
records that the check interface has no compiler or artifact semantics.
Compiled mode transpiles with `--map` and runs one pinned Go 1.27 `go build` of
the generated module with the upstream go-command recipe flags passed verbatim
(for example the exact `-gcflags=-l=4`; never rewrapped as compile-tool flags
and never `all=`), writing the artifact to the upstream working directory as
`a.exe`. The upstream-selected runenv owns `GOEXPERIMENT` and is preserved
unchanged. The artifact is never executed.

Story S149.4 closes the same `compile` exception over the authenticated
packet-149.4 root list (`docs/upstream-harness/compile-matrix.tsv`, 28 roots,
`tools/upstream-harness/compile-gate.sh`). One bounded seam correction came out
of that run: upstream hands `-p=<importpath>` straight to `go tool compile`,
but the pinned `go build` of the generated module owns `-p` itself, so
forwarding it through `-gcflags` relinked `main` into that package. The flag is
now retained as evidence only and the backend event declares the deviation.
Every other upstream compile flag (`-N`, `-l`, `-B`, `-c=N`, `-d=…`,
`-dynlink`, `-goexperiment`, `-godebug`) still passes through unchanged. The
packet is honestly non-green: three roots fail in both modes on
`unsupported LabeledStmt` and two fail in compiled mode on a lowering panic;
all five are recorded in `docs/upstream-harness/residuals.tsv` with a direct
reproducer and are owned by the product-fix sprints.

On 2026-09-11 at 13:04Z one coordinator ran `compile-gate.sh` from a fresh
`/srv/sprint149/s149.4` checkout on the authorized Linux host (Go 1.27.0
linux/amd64 at the pinned SHA-256, Bash++ `118bb3f` Linux binary SHA-256
`ee3aaae272fec8ddfaaf3b9a6f6bb8facd763b6383b80c7de37386ff8e927d13`, shell runtime `6e6f364f`, `GOMAXPROCS=2`, `POSIXLY_CORRECT` unset):
48 `COMPILE-ONLY-PASS` rows, exactly the same five product roots, no seam
`FAIL`, exit 3, and no surviving test, compiler, or Bash++ process. The
retained log is `/srv/sprint149/s149.4/compile-gate-linux.log`.

## Sprint 149 static seams

Stories S149.1–S149.3 (with S149.5, S149.7–S149.10 riding on them) extend the
same `planExec` seam to every static action of the packet inventory, using the
Bash++ identity `be20731` (which carries the explicit package map of
`docs/bashpp-import-resolution.md`) and shell runtime `828e5b33`. One
localized observation was added at the upstream decision site:
`compileInDir` now hands `planExec` the package identity upstream itself
chose — the `-D` base and the `-p` path — as a `packageIdentity`, recorded on
the phase event. Nothing else about the instrumented runner changed and its
native equivalence stays 9/9.

- **Diagnostics** (`errorcheck`, `errorcheckwithauto`, `errorcheckoutput`;
  phase `compile`): interpreted mode runs the Bash++ check interface on the
  exact upstream input (`check-diagnostics`); compiled mode transpiles with a
  map and invokes the generated file through the pinned compiler directly
  (`transpile-compile-diagnostics`). Both
  emit `file:line:col: message` on the upstream input path — the generated Go
  carries `//line` directives — so the unchanged upstream `errorCheck` applies
  its own expectations. The compile-tool flags `-e`, `-C`, `-d=` and
  `-p=` have no representation in either interface and are retained as
  evidence. `errorcheckoutput`'s generator step is the upstream `generate`
  phase, a `go run` with the execute phase's direct meaning.
- **Directory packages** (`compiledir`, `errorcheckdir`, `builddir`; every
  `compileInDir` phase): each package group is one invocation carrying
  `--go-import-base <-D> --go-import-path <-p>` and, as `--go-package
  path=files`, every earlier group of the same upstream test, in upstream
  order — the in-memory equivalent of the importcfg upstream accumulates.
  Relative imports are never resolved on disk. Interpreted mode is
  `check-package-map`; compiled mode is `transpile-compile-package-map`, and a
  lowered relative import that does not build is a retained lowering product
  failure. A non-Go companion (`.s`) has no Go-source meaning and is a
  retained product limitation, never a seam failure.
- **Assembly** (`asmcheck`; compiled mode only): the generated module is built
  with the upstream `-S=2` listing request and the upstream `-gcflags` merge
  (`transpile-build-assembly`); the listing cites the upstream input path
  through `//line`, so the unchanged upstream `asmCheck` indexes it.
  Interpreted mode records an explicit `unsupported` disposition: assembly is
  a compiler artifact.
- **Typechecker** (`cmd/compile/internal/types2` and `go/types`
  `check_test.go`; S149.10): a second frozen upstream runner pair under
  `testdata/upstream-types/`, each with a fifteen-line patch that replaces the
  one `conf.Check` call with the Bash++ check interface on the same files and
  the upstream-parsed `-lang`; flag parsing, build constraints, ERROR-comment
  collection and matching stay upstream's. `-fakeImportC` has no counterpart
  and `import "C"` is checked as an ordinary import (a retained product
  difference on `importC.go`). `tools/upstream-harness/typechecker-gate.sh`
  proves both patched runners native-equivalent with the backend off (10/10
  each) before replaying the 20 roots.

Every packet has its own authenticated matrix (`docs/upstream-harness/<action>-matrix.tsv`,
root-list digest = manifest, companion digests pinned) and gate
(`tools/upstream-harness/<action>-gate.sh`): exit 0 green, exit 3 with every
non-green root a product row in `residuals.tsv`, exit 1 a seam defect.

### Sprint 149 Linux evidence

On 2026-09-11 (17:59Z–18:40Z, plus a 43651cf re-run of the backend and
asmcheck gates) one coordinator ran every packet gate in sequence from a fresh
`/srv/sprint149/s149-static/bashpp-tests` checkout on the authorized Linux host
(Go 1.27.0 linux/amd64 at the pinned SHA-256; Bash++ `be20731`, Linux
`bashy.real` SHA-256 `9d6adf3591bfe8edab3c8d720622a34a1240ca7f0afbf3668c1e0c1ced4caf04`;
shell runtime `828e5b33`; `GOMAXPROCS=2`, `GOFLAGS=-p=2`, `POSIXLY_CORRECT`
unset; evidence retained under `/srv/sprint149/s149-static/tmp`, logs under
`/srv/sprint149/s149-static/logs`). The post-run process table held no test,
compiler or Bash++ process. Every packet kept its upstream contract with no
seam `FAIL`; the counts below are rows (root × mode):

| Packet | Gate | Exit | PASS | Product | Skip / bypass |
|---|---|---:|---:|---:|---:|
| 149.1 errorcheck (144) | `errorcheck-gate.sh` | 3 | 94 | 194 | 0 |
| 149.2 compiledir (125) | `compiledir-gate.sh` | 3 | 120 (119 interpreted) | 130 | 0 |
| 149.3 asmcheck (84, compiled only) | `asmcheck-gate.sh` | 3 | 18 | 57 | 9 bypass |
| 149.4 compile (28) | `compile-gate.sh` | 3 | 48 | 8 | 0 |
| 149.5 errorcheckdir (26) | `errorcheckdir-gate.sh` | 3 | 33 | 19 | 0 |
| 149.6 build (4) | `build-gate.sh` | 3 | 6 | 2 | 0 |
| 149.7 builddir (2) | `builddir-gate.sh` | 3 | 0 | 4 (`.s` inputs) | 0 |
| 149.8 errorcheckoutput (4) | `errorcheckoutput-gate.sh` | 3 | 2 | 6 | 0 |
| 149.9 errorcheckwithauto (3) | `errorcheckwithauto-gate.sh` | 3 | 1 | 5 | 0 |
| 149.10 typechecker (20, interpreted) | `typechecker-gate.sh` | 3 | 18 | 2 (`importC`) | 0 |
| S157 matrix | `backend-gate.sh` | 0 | native 9/9 | — | — |

Every product row is in `residuals.tsv` with its first diagnostic line and a
direct reproducer. The dominant classes are: relative imports the lowering
emits literally (compiled mode of every directory packet); diagnostics that
upstream's `// ERROR` expectations do not match (extra or differently worded
Bash++ diagnostics, missing escape-analysis and write-barrier diagnostics);
codegen the transpiled program does not reproduce (asmcheck); and language
gaps (`LabeledStmt`, labeled branches, range-assignment targets, struct type
expressions) plus two lowering nil-pointer panics.

The backend records one small JSON event for each observed upstream phase. The
event repeats the mode, structured action and recipe flags, source/argument
boundary, native argv evidence, tool identity, disposition, and declared
deviations. `backend-verify.go` checks the one-to-one phase/event identity and
the required canaries. Compiled compile results additionally prove the actual
generated source, map, and artifact by path, existence, size, and SHA-256. The
verifier does not make recipe decisions.

## Behavioral delta

`fixedbugs/issue21808.go` passes in both modes with the exact five-byte combined
output selected by the upstream comparison. `cmplxdivide.go` retains both Go
files as compile inputs and an empty program argv. Compiled mode passes. The
current direct interpreter exits 2 on its unsupported `complex128` collection
element; the upstream harness therefore reports an expected, honestly retained
failure. The other authenticated rows are either explicit unsupported backend
phases or unchanged upstream skip/bypass decisions.

The backend deliberately does not translate native Go flags for S157 execute
phases because the direct Go-source interface has no representation for them.
For compile-only recipes (`compile`, the errorcheck family, and directory
compile phases), compiled mode transpiles with a map and then invokes the
pinned `go tool compile` directly.  Its `compiler_argv` event field is the
upstream command with only the original Go inputs replaced by the generated
file: recipe flags, `-p`, and `-importcfg` therefore retain the authority's
meaning, and cmd/go cannot add `-complete`.  The unchanged upstream
`errorCheck` still judges diagnostics.  A subsequent directory link uses the
object from that compiler invocation; an executing body-less declaration thus
still fails at link/run as upstream would. The native argv is retained as
evidence. The backend also disables the upstream `go run` fast path while
backend mode is selected so that the existing source-execution plan reaches
the seam.

## Verification

`tools/upstream-harness/backend-gate.sh` first runs the S157.1 native-equivalence
gate, authenticates every source and patch, and then exercises all nine matrix
rows in each backend mode. `tools/upstream-harness/compile-gate.sh` (S149.4) replays the 28 packet-149.4
`compile` roots the same way, and the generic `verifyCompileRow` asserts one
compile-only phase, one Go input, empty argv, and check-only /
transpile-compile-only dispositions for every compile row (the S157 `bug020`
canary included). `tools/upstream-harness/build-gate.sh` (S149.6)
authenticates the packet-149.6 manifest root list
(`docs/upstream-harness/build-matrix.tsv`, four `build` roots) and replays those
exact roots through the same seam in both modes. `backend-verify.go` asserts for
each build root the exact verbatim go-command flags, the upstream-runenv
`GOEXPERIMENT`, the single-root/empty-argv boundary, the absence of any execute
phase or artifact execution, the cwd `a.exe` artifact with generated/map/artifact
proofs in compiled mode, and the actual upstream terminal. A retained Bash++
product failure keeps the packet honestly non-green (verifier exit 3, gate exit
3) without reclassification. It requires a non-POSIX startup environment because
the direct Go-source interface intentionally refuses POSIX mode; the environment
received at the seam is otherwise preserved.

The local gate passed through `bashy gate` in 47.885 seconds with Go 1.27,
Bash++ version `118bb3f`, and shell runtime commit
`01bbf2e957970e689b6ed2bf4f0a1633b99709a0`.

On 2026-09-11 at 07:06Z, one authoritative Linux coordinator passed the exact
reviewed candidate through `bashy gate` in 3m20.123s on
the authorized Linux host. It used:

- Go 1.27 Linux/amd64 binary SHA-256
  `1db869c560a193573a71be466a34e0d4abb7792d78165c6102cdda069276a3a8`;
- Bash++ source commit `118bb3f6841a57a7010b7858bf02564c445416f7`
  and Linux binary SHA-256
  `b5d2b6b30a4c890b9005b4acb58ea176b93208375b882c2de0e559b2e115b80d`;
- shell runtime commit `01bbf2e957970e689b6ed2bf4f0a1633b99709a0`;
- the authenticated Go 1.27 corpus and unchanged S157.1 runner pin.

The host's inherited `POSIXLY_CORRECT=1` was explicitly absent from the
authoritative gate environment. An earlier run retained that host selector and
failed interpreted mode exactly as Bash++ specifies; compiled mode and native
9/9 equivalence still passed in that diagnostic run. The accepted rerun had no
second coordinator, and the post-run process table contained no surviving gate,
test, compiler, linker, or Bash++ process.

## Sprint 150 dynamic and package seams

The package-test backend uses one library emission per tested package. It
classifies the exact `GoFiles`, `TestGoFiles`, and `XTestGoFiles` selected by
cmd/go as `--go-file`, `--go-test-file`, and `--go-xtest-file` respectively,
and invokes `transpile --go-library <dir>` once. The contract's `library`
lines are captured and checked for exactly one output for every selected
original, with the expected basename output; the overlay is generated from
those lines, never from a guessed file walk. The resulting overlay replaces
all package sources while cmd/go retains package identity, test enumeration,
flags, environment, and its native handling of `*_test.s` companions.

Stories S150.1–S150.8 extend the same `planExec` seam to every dynamic
action of the packet inventory and add a second frozen upstream runner for
package test bodies, on the unchanged identities Bash++ `be20731` and shell
runtime `828e5b33`. No `sh`/`bashy`/`coreutils` change was made. One rule
governs every new meaning: **the seam remembers what upstream handed it
earlier in the same test; it never looks for anything on disk.**

- **Ordinary run** (`run`; S150.6): the execute phase already had the direct
  meaning (`check-then-run`, `transpile-build-run`). Upstream's go-command
  recipe flags (`-gcflags=…`, `-race`, `-tags=…`; `-goexperiment` becomes
  runenv `GOEXPERIMENT`, preserved) are now passed verbatim to the pinned Go
  build of the generated module in compiled mode — the build action's
  convention — and remain declared evidence in interpreted mode.
- **Remembered program** (S150.5, reused by S150.1/S150.3): a compile phase
  that produces the program (buildrun's build-only phase; the last directory
  package of rundir/errorcheckandrundir) records, per upstream test, the
  files it was handed, the package map, and in compiled mode the artifact it
  built (`backendPrograms`, keyed like `backendPackages`). An **execute phase
  with no compile inputs** runs that program: `run-remembered-program`
  (the sources through the interpreter with only the upstream argv) or
  `run-artifact` (the built artifact with only the argv). The backend event
  carries a `program` record so the verifier proves the execute phase acted
  on exactly what the compile phase compiled.
- **Link** (`rundir`, `errorcheckandrundir`; S150.1, S150.3): upstream hands
  the link phase the object name of the last package it compiled (its own
  `.go`→`.o` rewrite) and any `-ldflags`. The seam checks that object is the
  remembered program and adopts it: `link-adopt-check` (an interpreter has
  nothing to link; the command is a no-op) or `link-adopt-artifact` (the
  pinned build of the last package's generated module already linked the
  program; the phase proves the artifact exists). `-ldflags` are evidence.
  Interpreted execution of a multi-package program is refused by the
  product (`--go-package … require --check or --go-list`) — the dominant
  product row of this sprint; a single-package `rundir` root passes end to
  end. Compiled mode stops at the first importing package's lowering
  (literal `./a`), the Sprint 152 row already recorded for compiledir.
  errorcheckandrundir needs nothing more: upstream owns the diagnostics
  pass, the "ignore failure of package n−1" rule, and its errorCheck
  comparison; an errorCheck failure after a clean phase is a product row
  because the comparison is on record.
- **Module program** (`runindir`; S150.2): upstream prepares a module
  (overlay copy + generated `go.mod`) and hands the seam one execute phase
  over `.` in that directory. `.` is resolved once by the pinned go command's
  **own** module policy — `go list -json -deps .` in that directory with the
  upstream environment — into the main package's Go files and the in-module
  dependency packages as an ordered explicit map (`--go-import-path` +
  `--go-package`). A package with `.s` or cgo files is a retained non-Go
  product limitation; the go command's build constraints decide which files
  exist on the run host. The event keeps upstream's `.` as its compile input
  and records the `go list` argv, directory, files and map.
- **buildrundir** (S150.4): every authenticated root carries a `.s` file, so
  upstream's first phase is `generate` over it (symabis) and stops at the
  seam's non-Go product limitation — the 149.7 builddir shape. The
  compile/link/execute meaning buildrundir would take (build-only, then the
  remembered program) exists but is untested by this packet.
- **Package test bodies** (S150.8): a second frozen upstream runner —
  `src/cmd/go/internal/test/test.go` of Go 1.27.0 under
  `testdata/upstream-go/` (BSD license retained), with a seven-line patch
  at the one site where the built test binary would be executed and an
  overlay file `testdata/go-backend/bashpp_backend.go` in package `test`.
  The unmodified cmd/go enumerates the original test bodies
  (`load.TestPackagesFor` → generated `_testmain.go`) and builds the native
  test binary; the patched site replaces the argv with the Bash++ form of
  that binary — the tested package with its in-package test files, the
  external test package, and `_testmain.go` as the main package, as an
  explicit package map with the exact test flags — so the native binary is
  never run in a backend lane. The enumeration count is read back from Go's
  own `_testmain.go` (tests, benchmarks, fuzz targets, examples); a zero
  enumeration, a package build, or a native run can never be PASS
  (`package-verify.go`). `package-gate.sh` builds the patched go command
  through `-overlay`, proves it native-equivalent with the backend off on
  `internal/types/errors`, and replays the 26 packages in both modes. With
  the product as it stands every package lands a product row at the Bash++
  invocation (interpreted: the map is refused at execution; compiled: the
  lowering or the map importer), and `cmd/internal/testdir` is additionally
  the runner itself.

### Sprint 162 package overlay

The compiled disposition is `transpile-overlay-go-test`.  For every Go file
cmd/go selected for the tested package — `GoFiles`, `TestGoFiles`, and
`XTestGoFiles` — the backend invokes Bash++ as a library at that package's
original import path and writes a `cmd/go -overlay` replacement at the
original SDK source path.  It then invokes the pinned `go test` with that
overlay and the original package/test flags.  Thus cmd/go creates and runs its
own `_testmain.go`, applies its own internal-import rule, and (for
`cmd/compile/internal/ssa`) assembles the two `*_test.s` companions natively.
That assembly is recorded as the explicit D3(b) deviation, not hidden as a
Bash++ execution.

The overlay proof event records the pinned Go binary, the overlay JSON and
digest, and each original/generated pair with the generated-file digest.  The
package verifier reads the overlay itself and rejects a result unless every
selected package Go file has a one-to-one generated replacement; a two-file
fixture covers the unmapped-sibling failure mode.

Every packet has its matrix (`docs/upstream-harness/<action>-matrix.tsv`;
`package-matrix.tsv` rows are Go packages pinned by a digest over their
`*.go` files) and gate (`tools/upstream-harness/<action>-gate.sh`), exit
0/3/1 as before. New verifier rows: RUN, BUILDRUN, RUNDIR, RUNINDIR
(`backend-verify.go`) and PACKAGE (`package-verify.go`).

### Sprint 150 Linux evidence

On 2026-09-11 (20:06Z–20:59Z) one coordinator ran each packet gate as its
story landed, from a fresh `/srv/sprint150/s150-dynamic/bashpp-tests`
checkout (bundles, fast-forwarded through `e8c436f` → `9f679fc` → `787cede`
→ `c8988c0`) on the authorized Linux host: Go 1.27.0 linux/amd64 at the
pinned SHA-256; Bash++ `be20731` rebuilt on the host from the pinned source
with the authenticated Go — Linux `bashy.real` SHA-256
`9d6adf3591bfe8edab3c8d720622a34a1240ca7f0afbf3668c1e0c1ced4caf04`,
byte-identical to the Sprint 149 evidence binary; shell runtime `828e5b33`;
`GOMAXPROCS=2`, `GOFLAGS=-p=2`, `POSIXLY_CORRECT` unset; evidence retained
under `/srv/sprint150/s150-dynamic/tmp` (build caches removed), logs under
`/srv/sprint150/s150-dynamic/logs`. No test, compiler, patched-go or Bash++
process survived any run. Every packet kept its upstream contract with no
seam `FAIL`; counts are rows (root × mode):

| Packet | Gate | Exit | PASS | Product | Skip |
|---|---|---:|---:|---:|---:|
| 150.6 run (48) | `run-gate.sh` | 3 | 53 | 43 | 0 |
| 150.7 runoutput (1) | `runoutput-gate.sh` | 3 | 0 | 2 | 0 |
| 150.4 buildrundir (4) | `buildrundir-gate.sh` | 3 | 0 | 8 (`.s` inputs) | 0 |
| 150.5 buildrun (1) | `buildrun-gate.sh` | 3 | 1 (compiled) | 1 | 0 |
| 150.2 runindir (10) | `runindir-gate.sh` | 3 | 1 | 19 | 0 |
| 150.3 errorcheckandrundir (5) | `errorcheckandrundir-gate.sh` | 3 | 0 | 10 | 0 |
| 150.1 rundir (116) | `rundir-gate.sh` | 3 | 3 | 229 | 0 |
| 150.8 packages (26) | `package-gate.sh` | 3 | 0 (patched go native-equivalent: PASS) | 52 | 0 |
| S157 matrix | `backend-gate.sh` | 0 | native 9/9 | — | — |

Every product row is in `residuals.tsv` with its first diagnostic line and
a reproducer. The dominant class, by construction of the packet inventory,
is **the multi-package program**: interpreted execution of an explicit
package set is refused by the product (`--go-package … require --check or
--go-list`; 114 rundir + 26 package + 7 runindir interpreted rows, owner
151), and the lowering emits dependency imports literally (`relative import
paths are not supported in module mode`, `no required module provides
package …`; 109 rundir + 8 runindir compiled rows, owner 152). Only two
rundir roots and one runindir root are single-package programs, and they
pass. The remaining classes are the Sprint 149 ones: interpreter gaps
(`gosource: …`, `BASHPP-E…`), lowering type errors (`LOWER-ETYPE`), missing
`-m` diagnostics in the errorcheckandrundir pass (owner 154), `.s` inputs
(no assembler), and a handful of programs that ran to a wrong result
(inline_caller frame names, maymorestack stack size; owner 153).

One flake was observed and is recorded rather than hidden: the S157
`issue21808.go` ordered-output canary failed once in interpreted mode at
`9f679fc` (a 37-second run of a one-second program; stdout/stderr
interleave differed) and passed on the immediate re-run and on every other
run of the day. The canary is load-sensitive on the 2-core host; it is not
a seam defect of this sprint.

## Sprint 151 corpus lane and deadline

The seam is unchanged in meaning; Sprint 151 adds one bound and one lane.

- **Deadline (backend lanes only).** Upstream bounds a command only when the
  recipe says `-t N`; every other phase is `cmd.Run()` with no limit, which is
  right for the native compiler and wrong for a product under test that can
  hang — the first full-corpus attempt found `test/deferfin.go` running for an
  hour in interpreted mode. `backendPlan` now sets `planStep.deadline` (60 s;
  `BASHPP_TESTDIR_DEADLINE` overrides) and the backend patch feeds it to
  upstream's own timer when `tim == 0`, so a timed-out root ends as upstream's
  `errTimeout` ("command exceeded time limit"): a product row, owner 153,
  never a seam error. The native lane never sees the field.
- **Corpus lane.** `corpus-gate.sh` runs the three runners without a
  selector (see `README.md` §Sprint 151). Its native lane is the count
  authority: 2,726 testdir, 899 typechecker, 26 package roots; the backend
  lanes must produce the same counts. The Sprint 151 candidate on `main` is
  Bash++ `963ef4b` (bashy) on sh `0e9ee20f`; Barrier A itself ran on the
  frozen Sprint 150 candidate `be20731`/`828e5b33` with the pins overridden
  for that run only (recorded in the run's `status.txt`).

## Sprint 153 runtime lanes and partition v7–v9

The seam is unchanged. Sprint 153 adds nothing to the backend patch; what
changed is the partition and the product.

- **Partition v7–v9** (`partition-emit.go`): cgo roots are the `retained`
  disposition (`package requires cgo`, `unknown import path "C"` — also in
  its JSON-escaped go-list form — and the checker's `could not import C`):
  the pure-Go shell declares no cgo, and upstream's `shouldTest` includes
  them only because the native host has gcc. The GOROOT prefix is stripped
  from a LEADING path only — a goroot path quoted inside a message
  (`could not import C (go list failed using … /goroot/bin/go …`) was cutting
  the diagnostic down to `bin/go (GOROOT=…): exit status 1`, which misfiled
  three cgo roots as 153 and two `package test/a is not in std` rows as 154.
  Bridge writeback/mutation refusals and Go-stack exhaustion are 153 runtime
  rows; `unknown field` is a checker verdict (151).
- **Leaf form on the 153 denominator** (`docs/upstream-harness/leaf-153/`):
  five runs, one coordinator, 24 min each; the 60 s deadline roots dominate
  (17 × 60 s serial on two cores). Two roots that finish in ~9 s on a 12-core
  darwin host sit at the bound on the 2-core Linux host and flip between
  runs (`atomicload.go`, `fixedbugs/issue22781.go`) — the same
  load-sensitivity the S157 `issue21808.go` canary showed. A leaf's PASS count
  is therefore quoted as "pass both runs", never as one run's count.

## Sprint 154 — diagnostic fidelity and parser audit

Partition v10 (S154.0): every active row carries a `verdict` column read
from the upstream errorCheck output already in the go-test stream
(`missing=<n>;wording=<n>;extra=<n>;class=…`); rules key on the backend
event's `recipe_flags` and the verdict shape, never on expected strings.
Interpreted rows of `-m`/`-live`/`-d=<diagnostic>` errorcheck recipes are a
declared `unsupported` disposition ("optimizer diagnostics are a compiler
artifact") → `retained` (v10.1: `-d=ssa/check/on`, which upstream appends
to every errorcheck compile, and `-d=panic` carry no expectation; v10.2:
`-race` alone is not an optimizer recipe); a compiled `-m`/`-live` row with a
verdict is a lowering row (v10.3, measured: the generated module's notes
differ by `//line` position and emitted symbol name only); run-family rows
never fail on a diagnostic (v10.4). Typechecker rows whose extra message is
a tab-continuation or `undefined: assert|trace` are 154 (D2).

The typechecker runners (`testdata/types-backend/`) apply upstream
check_test's own secondary-error rule (`": \t"`, gotypes), join sub-errors
into types2's one-message shape, take a TAB-prefixed line as gc's
continuation, and pass `--go-test-builtins`, `--go-checker-branch-errors`
and `--go-check-after-syntax-errors` — the three facts of the runners'
environment the out-of-process check interface cannot know
(DefPredeclaredTestFuncs; parsing without CheckBranches; type-checking the
partial AST after parse errors). Unit tests run under the frozen Go 1.27
through the gate's overlay (`-run '^TestBashppParse'`).

Product (sh): gc's `cmd/compile/internal/syntax` is vendored as
`gosource/internal/gcsyntax` and is the syntax verdict; a multi-part
go/types sub-error renders in gc's shape. Leaf runs r0 → r1c
(`leaf-154r{0,1a,1b,1c}/`): 317 roots, 12 → 182 PASS; 154 = 160 → 4.
