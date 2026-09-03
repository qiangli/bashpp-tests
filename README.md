# bashpp-tests — Go 1.27 profile & POSIX 1003.1-2016 conformance suite for Bash++

This suite implements **Test-Driven Development (TDD)** for **Bash++** in `bashy`, maintaining the enumerated **Go 1.27 profile** against official Go tests (`../go/test/`), **POSIX 1003.1-2016 (IEEE Std 1003.1-2016 / VSC-PCTS2016)**, and **GNU Bash 5.3**.

> **Headline goal:** validate `bashy`'s `bash++` extensions against the
> **enumerated `go1.27-profile-v1`** — the Go-1.27-shaped constructs the design
> of record actually claims — alongside the GNU Bash 5.3 gate and the POSIX
> 1003.1-2016 baseline.
>
> **Not** "Go 1.26 compliant/conformant", which this file used to say. Go 1.27
> is an upstream *language coordinate*, not a promise to accept arbitrary Go
> source: `package`, `goto` and labels are permanent shell fallback, and every
> other construct is delivered by a named phase. The claim is the profile, and
> the profile is enumerated in
> `../docs/bashpp-posix-superset-syntax.md` §Committed Start Sites.

---

## 2-Tier Test Scope & Coverage Matrix

To maximize language fidelity while avoiding irrelevant host runtime internals, the suite adopts a 2-tier scope strategy:

| Tier | Source Directory | Included Scope | Purpose & Rationale |
|---|---|---|---|
| **Tier 1 (Mandatory)** | **`../go/test/`** | Language-spec corpus — see the denominator note below | `for`, `if`, `switch`, `range`, `defer`, `struct`, `map`, `slice`, `interface`, generics, `go f(x)`, `chan`, `select`, `clear()`, `:=`. Scope is the enumerated `go1.27-profile-v1`, not the whole language. |
| **Tier 2 (Selective)** | **`../go/src/`** | **Exposed Utility Packages** (~150 `*_test.go` files) | Validates standard library utility packages exposed to `bash++` scripts via builtins & the Go bridge: `encoding/json`, `strings`, `bytes`, `sync`, `math`, `time`. |
| **Excluded** | **`../go/src/`** | Internal compiler & host OS runtime (`runtime`, `syscall`, `cmd/compile`, assembly) | Internal Go host implementation details not surfaceable to shell scripts. |

---

## TDD Workflow & Cycle (Red → Green → Refactor)

1. **🔴 Red Phase (Write 1:1 Test First):**
   - Add 1:1 adapted test fixtures from `../go/test/` directly into `bashpp-tests/tests/`.
   - Action headers (`// run`, `// errorcheck`, `// build`) are parsed automatically by `harness/run.sh`.
   - Run `harness/run.sh` to confirm expected test failure for unimplemented Go features.

2. **🟢 Green Phase (Implement Engine Support):**
   - Implement syntax tokens in `sh/syntax` (`LangBashPP`), type evaluation in `sh/expand` (`Object`), and goroutines/channels in `sh/interp`.
   - Pass tests in both interpreted mode (`bashy --bashpp`) and transpiled mode (`bashy transpile -> go build`).

3. **🔵 Refactor Phase:**
   - Optimize AST evaluation, channel synchronization, and memory allocations while keeping the full test suite green.

---

## 5-Layer Testing Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│                   Layer 1: Measured Superset Gate                       │
│  Assert zero regressions on GNU Bash 5.3 (86/86) & POSIX 1003.1-2016  │
│  with bashy --bashpp and bashy --posix --bashpp                       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│              Layer 2: Dual-Mode Execution Verification                 │
│   Byte-identical output: Interpreted (bashy) vs Transpiled (go build) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│               Layer 3: Go 1.27 Profile Conformance                     │
│   1:1 Parity with ../go/test/ (for, chan, select, defer, clear, etc.) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│               Layer 4: Auto-JSON OS Boundary Verification              │
│   Native Go objects <--> JSON auto-serialization across pipes/binaries │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│            Layer 5: Compiler Diagnostics & Negative Checks             │
│   1:1 // errorcheck validation for unassignable/invalid Go constructs  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Key References

- [**`TDD_PLAN.md`**](TDD_PLAN.md): Detailed TDD methodology, 1:1 test parity plan, and tiering matrix.
- [**`PLAN.md`**](PLAN.md): Conformance architecture and dual-mode runner specification.
- [**`harness/run.sh`**](harness/run.sh): Master test runner script.

## Spelling: exact Go, no substitutes

Constructs are written in **exact Go**. `go f(x)`, not `go routine { … }`;
`defer f(x)`; `x, err := f()`; `make(chan T, n)`; `select { … }`. The two-word
and builtin-style forms an earlier draft of this suite used —
`go routine`, `gather`, `call` — were **abolished** by the L4 addendum in
`../docs/bashpp-posix-superset-syntax.md`, which is the design of record.

The reason is now measured rather than argued: `go build ./...` **parses** in
bash 5.3 while `go worker(a, b)` is **already a syntax error**, so the collision
the two-word form was invented to avoid is resolved by the parens. See
`tools/startsites/` for the derivation.


## The Tier-1 denominator is currently unverifiable

This suite used to claim a Tier-1 corpus of **3,404 `.go` files** under
`../go/test/`. That was an unverifiable provenance number. Sprint 98 pins the
first bounded official corpus slice to **Go 1.27.0 source** and records a
machine-readable `go/test/**/*.go` inventory in
[`docs/go-corpus/inventory.tsv`](docs/go-corpus/inventory.tsv). The derived
fail-closed denominator for that release is **3,398 `.go` files**.

Recorded rather than quietly dropped, because a denominator nobody can check is
the exact shape of a number that drifts into being quoted as fact. The honest
workflow is now:

- `tools/go-corpus/refresh.sh` is the explicit networked refresh step. It
  downloads the pinned Go source archive, verifies the published SHA-256,
  regenerates the inventory, and validates it against the extracted tree.
- `tools/go-corpus/validate.sh` is the normal offline gate. It checks the
  checked-in pin and inventory on every harness run and fails closed on a
  missing, duplicate, malformed, or count-changing row.

The inventory is provenance and a denominator, not a parity claim. Adapted
fixtures still declare `supported` or `planned` in `tests/manifest.tsv`; no
unimplemented upstream test is counted as passing merely because it appears in
the official corpus inventory.

Sprint 98 Story #1 also pins the official go.dev/tour source — the
`golang.org/x/website` module at version
`v0.0.0-20260903033311-c4a9d59f9775` (commit
`c4a9d59f9775d994f1700d18fa37414c3c85fa7b`, acquired via
`go install golang.org/x/website/tour@v0.0.0-20260903033311-c4a9d59f9775`).
Lesson assets are the programs embedded from `_content/tour`. The tour
denominator is recorded separately under `docs/tour`, `tests/tour`, and
`tools/tour` to avoid mixing it with the Go corpus files owned by run #2.
The fail-closed inventory contains **168 rows**: 106 `.go` programs (lesson
`.play` programs, exercise solutions, and the UI-served sandbox) plus 62
inline lesson-prose blocks from the seven `.article` files, classified
against the upstream `content_test.go` oracle semantics. Applicability is
classified only against the standing Sprint 98 exceptions in
`docs/tour/standing-exceptions.tsv`, and the tour differential schema names
pinned Go, Bash++ interpreted mode, and Bash++ compiled mode explicitly.
`PLANNED` is intentionally invalid in this inventory.

## The Go oracle now actually runs

Pinning an inventory answers "what is in the corpus". It does not answer "what
does the corpus do", and the previous slice could not: it read each file's
`// run` / `// errorcheck` / `// compile` header and stopped there. A contract
like that derives every number it reports from the same row it is supposed to be
checking, so a green run and an empty run look identical from the outside.

`tools/go-oracle` closes that. It executes a reviewed, bounded tranche of the
pinned Go 1.27.0 corpus with the pinned Go 1.27.0 toolchain, following the
semantics of upstream's own runner (`src/cmd/internal/testdir/testdir_test.go`,
historically `test/run.go`), and writes one machine-readable record per file
carrying the command, exit code, duration, action and artifact. Tranche 1 is 35
files, five each across **run, build, errorcheck, compile, compiledir, rundir and
runoutput** — the seven actions this slice commits to executing rather than
classifying.

Four things this is **not**:

- It is not a Bash++ result. It is the left-hand side of the differential method
  described in [`tests/_oracles/README.md`](tests/_oracles/README.md): the
  trusted Go behaviour that a bash++ form will later be compared against. No
  parity is claimed by this slice.
- It is not the whole corpus. The tranche is 35 of 3,398 files, and the
  denominator reported is the tranche, never the corpus.
- **It is not upstream's runner.** Seven of upstream's seventeen actions are
  executed. The other ten — `asmcheck`, `builddir`, `buildrun`, `buildrundir`,
  `errorcheckandrundir`, `errorcheckdir`, `errorcheckoutput`,
  `errorcheckwithauto`, `runindir`, `skip` — are enumerated with their reasons in
  `docs/go-oracle/pin.tsv`, printed by the runner, and published in every result
  summary. The seven-plus-ten split is re-derived from the pinned upstream source
  on every run, so a new upstream action cannot slip in unclassified.
- It is not an adapter-limitations exercise. Nothing here is marked N/A; the
  seven actions are executed, and an unimplemented upstream action is a fatal
  error naming the action and the reason rather than a shrug.

Three things it now checks that a metadata-shaped driver cannot:

- **Artifacts are asserted, not just measured.** Every compile, link and build
  step declares what it must produce and is checked for it: existence, regular
  file, the right kind (Go object archive / native executable / Go source), and
  non-empty. A toolchain that exits 0 and writes a zero-byte object fails.
- **Every consumed byte is pinned.** The corpus inventory covers `*.go`;
  `docs/go-oracle/aux-inventory.tsv` covers the `.out` sidecars and the `.dir`
  manifests, *including the sidecars upstream deliberately does not ship* —
  "absent" is an assertion, because no `.out` means the output must be empty.
- **The toolchain is identified by checksum, not by `go version`.** That string
  is forgeable — this suite's own mutation tests forge it. The gate instead
  requires the pinned upstream sources inside the candidate's own GOROOT and a
  `go` binary whose SHA-256 matches the reviewed distribution digest, recorded
  next to both its go.dev/dl archive checksum and its `sum.golang.org`-attested
  module hash.

The driver fails closed when the record count does not equal the tranche, when no
file executed a command, and when no command was spawned at all — and every fatal
path still writes a machine-readable summary carrying the executed and failed
counts reached so far. See [`docs/go-oracle/README.md`](docs/go-oracle/README.md)
for the semantics table, the selection rule and the result schema.

Sprint 98 Story #5 supersedes the rejected weave 6 with **runner
infrastructure, not parity evidence**: `tools/tour/run-baseline.sh` executes
the pinned-Go baseline for the 93 applicable and 4 build-only rows under an
exactly pinned Go 1.27 toolchain (full identity + binary checksum in
`docs/tour/toolchain.tsv`) with the official `golang.org/x/tour` helper
module pinned in `docs/tour/helpers.tsv`, bounded process-tree cleanup,
strict-UTF-8 stream capture (invalid bytes are rejected, never replaced),
and per-row records in `tests/tour/results.tsv` bound by
`docs/tour/baseline-pin.tsv`. `tools/tour/validate-results.sh` re-proves
those records offline on every harness run, and
`tools/tour/tamper-tests.sh` proves the gates fail closed under tampering.
The Bash++ differential modes remain declared but unexecuted.
