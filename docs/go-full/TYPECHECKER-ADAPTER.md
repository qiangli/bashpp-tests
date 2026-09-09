# Official Go type-checker recipe adapter

Sprint 118, Story #17 (`b5d3bd1bd24c`), umbrella Story `6f0c4d9a31be`.

The `typechecker` axis of `docs/go-full` holds **743** roots: every subtest of the
official `go/types` and `cmd/compile/internal/types2` check harnesses.

| family | roots | | runner | roots |
| --- | --- | --- | --- | --- |
| `TestFixedbugs` | 548 | | `src/go/types/check_test.go` | 371 |
| `TestCheck` | 148 | | `src/cmd/compile/internal/types2/check_test.go` | 372 |
| `TestSpec` | 26 | | | |
| `TestExamples` | 16 | | | |
| `TestLocal` | 5 | | | |

Every one of them carries the same two phase obligations, and until this change
all 743 were reported as unimplemented by `tools/go-full/product.rb`:

* `check-original-fixture`
* `match-source-positioned-diagnostics`

`tools/go-full/typechecker.rb` executes both for real.

## What the adapter actually runs

For each adaptable root, and for **both** candidate checking phases:

| mode | argv |
| --- | --- |
| `interpreted` | `bashy --bashpp --source=go --check <fixture>` |
| `compiled` | `bashy transpile --bashpp --source=go <fixture> -o <generated> --map <generated>.map` |

The fixture is the **complete original file, byte for byte**. It is copied into a
private work tree at its inventory-relative path, and its digest is checked
before the run, after the run, and again inside the matcher. No body is
forwarded from the native oracle, nothing is reformatted, regenerated, or
rewritten. `argv`, the full environment, `cwd`, the timeout, the exit status, the
signal, both stream files and the wall-clock duration are retained for every
phase. `GOMAXPROCS=2` and `GOFLAGS=-p=2` are pinned.

A root is `PASS` only when **both** modes independently satisfy **both**
obligations *and* the retained native observation for that root is `pass`. The
native go/types checker is never executed as the product: the pinned harness is
read only to derive the semantics ported below, and the native observation acts
as a gate, never as a source of diagnostics.

## The positioned matcher

`tools/go-full/typecheck-diagnostics` is a **new, separate** binary. The existing
`tools/go-full/diagnostics` testdir errorcheck matcher has different semantics
and is preserved unchanged.

It reads retained product evidence only — it never type-checks and never runs a
fixture. Its semantics are ported from the pinned SDK
(`/Users/qiangli/.bashy/sprint118/sources/go-full-sdk/root`, `go1.27.0`):

* `commentMap` is a direct port of `src/go/types/commentMap_test.go`, using the
  real `go/scanner`. The expected position of an `/* ERROR … */` annotation is
  the position of the **token immediately preceding it**, and automatically
  inserted semicolons never move that position. This is why the matcher is a Go
  program: those positions depend on real Go literal boundaries and real
  automatic semicolon insertion, and a re-implementation would drift silently.
* The comment selector is the harness regexp `^ ERRORx? `.
* `ERROR` patterns are substring tests, `ERRORx` patterns are regular
  expressions, both unquoted with `strconv.Unquote`, exactly as in `testFiles`.
* When several annotations on a line match, the one with the closest column is
  consumed, and the remaining delta must be within the root's
  `column_tolerance` — `0` for every `go/types` root, and the family delta
  (`20`, `50`, `100`, `125`) for the `types2` twins, mirroring each runner's
  `colDelta`.
* Secondary clarifications are dropped exactly as `Config.Error` drops them:
  a message containing `": \t"` (for example `p.go:14:2: \tT3 refers to T4`) is
  attached to its primary error and is neither matched nor counted as an
  unexpected diagnostic.

### What can never produce a PASS

* an exit status on its own — the status must agree with the annotation count,
  *and* the full diagnostic set must match;
* any observed diagnostic that consumes no annotation;
* any annotation left unreported;
* a column outside the root's tolerance;
* any output line that is not a positioned diagnostic for the fixture (a panic,
  a usage message, a stray banner);
* a diagnostic attributed to a file outside the fixture;
* a deadline, a signal, a launch failure or a surviving descendant;
* a fixture or a captured stream whose digest changed at any point.

## Unsupported exact recipe options

**80** of the 743 roots use recipe options this adapter cannot execute. They
`FAIL` with both obligations named in `unfinished_phases` and the exact reason
listed in `unsupported_recipe_options`. They are **not** converted into a new
skip, and the 743 denominator is unchanged.

| unsupported option | roots | why |
| --- | --- | --- |
| `harness-flag:-lang` / `-goexperiment` / `-fakeImportC` | 68 | the first-line flags comment (`parseFlags`) mutates the harness `Config`; the candidate frontend exposes no equivalent |
| `build-tag-applicability:<file>` | 20 | `shouldTest` gating decides applicability from `GOOS`/`GOARCH`/release tags |
| `joint-multi-file-package-check` | 8 | the package is formed from several files checked together |

(Counts overlap: 16 roots carry both a flags comment and a build constraint.)

The remaining **663** roots are executed for real.

## Bounded control result

A bounded control over the first 40 adaptable `go/types` roots, using the frozen
`candidate006` build and the pinned SDK, produced **31 PASS / 9 FAIL**. The
failures are genuine product gaps, reported with exact repros, not waivers:

* `undefined: assert` — `TestCheck` runs `DefPredeclaredTestFuncs()`; the
  candidate frontend has no equivalent, so fixtures that call `assert`/`trace`
  emit diagnostics no annotation covers;
* `expr3.go` — 177 required errors are not reported at all;
* `literals.go` — a fixture with no annotations is rejected with exit 2.

This is a bounded sample. **No claim is made here about all 743 roots, about the
`typechecker` axis as a whole, or about the full 3495-root corpus.** The complete
ledger is produced only by a full `product.rb` run.

## Resume

The adapter is **fail-closed** for resume. `tools/go-full/resume.rb` has no
independent validator for a `typechecker_evidence` terminal, so those roots are
always re-executed without credit until one is reviewed. The new matcher sources
are included in the checkpoint `tools` digest, so this harness change produces a
new run context: earlier receipts cannot be upgraded into credit for it.

## Tests

* `tools/go-full/typecheck-diagnostics/main_test.go` — commentMap positions,
  ERROR/ERRORx, column tolerance, extra and unreported diagnostics, secondary
  clarifications, unexplained output, foreign files, tampered fixtures and
  streams, abnormal termination, unsafe selectors.
* `tests/go-full/typechecker_test.rb` — the `parseFlags` port, the unsupported
  option partition of the full 743 denominator, and bounded integration controls
  that run the real frozen candidate against real fixtures: a positive fixture
  with no annotations, a negative fixture matched exactly in both phases, a
  negative fixture the candidate does not satisfy, byte-identity of the checked
  input, and tampering of a retained fixture and of a retained stream.
