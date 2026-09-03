# go.dev/tour Inventory — golang.org/x/website pin

Sprint 98 Story #1 pins the official go.dev/tour source as a bounded
denominator for tour example/page programs. This is provenance and inventory
metadata only; it is not a Bash++ parity claim.

## Pin

The authoritative Tour ships inside the `golang.org/x/website` module
(https://go.googlesource.com/website). Acquisition is reproducible and does
not depend on the live website:

```sh
go install golang.org/x/website/tour@v0.0.0-20260903033311-c4a9d59f9775
go list -m -json golang.org/x/website@latest   # resolves version + commit
```

- module version: `v0.0.0-20260903033311-c4a9d59f9775`
- commit: `c4a9d59f9775d994f1700d18fa37414c3c85fa7b`
- go.mod sum: `h1:sKWEVclFcb47eMWJscLT/RC45vMFwwzgvPlhWHGFXSE=`
- license: BSD-3-Clause (upstream `LICENSE` is preserved verbatim at
  `tour/LICENSE`; the executable denominator is vendored under `tour/`)

The tour binary's lesson assets are embedded from `_content/tour`
(`content.go`: `//go:embed _content/tour`); the inventory denominates those
assets. The retired `golang.org/x/tour` repository and its Gin tutorial are
out of scope for this pin.

## Inventory

`tests/tour/inventory.tsv` — 168 rows, every example/page program in the
pinned tree:

- 106 `.go` programs under `_content/tour`:
  - `lesson_play_program` — referenced by a `.play` directive in a lesson
    article (paths resolve relative to `_content/tour/`)
  - `exercise_solution_program` — official solutions under `solutions/`
  - `ui_sandbox_program` — `welcome/sandbox.go`, served directly by the tour
    UI as initial editor content (reviewed allowlist in the extractor)
- 62 `article_inline_block` rows — every tab-indented snippet inside the
  seven `.article` lesson files (static prose, never executed by the tour)

Classification mirrors the upstream oracle `content_test.go`: every file's
first line must be a `//go:build` comment containing `OMIT`; `nobuild`
files are exercise skeletons; `norun` files build but are not executed.
Applicability is classified only against the standing Sprint 98 exceptions
in `standing-exceptions.tsv` (`none`, `fragment`). Official
`golang.org/x/tour` helper packages are reproducible module dependencies, not
an exclusion; programs importing them remain in the executable denominator.

| applicability | rule | exception |
|---|---|---|
| `applicable_go_program` | builds and runs (OMIT only, stdlib only) | none |
| `build_only_go_program` | `//go:build norun` — oracle builds, does not run | none |
| `excluded_fragment` | `nobuild` skeleton, or article inline prose block | fragment |

## Differential result schema

`differential-schema.tsv` names three modes — `baseline` (pinned Go),
`bpp_interpreted` (Bash++ interpreted), `bpp_compiled` (Bash++ compiled) —
and is the single source of truth: `tools/tour/validate.sh` loads both the
mode vocabularies and the applicability→schema coupling from it. Every row's
differential column must exactly match the coupling for its applicability,
so a row cannot stay applicable while quietly carrying a `not-run` mode.
`PLANNED` is not a valid tour inventory state, and no row may be omitted
silently: the pin's `inventory_data_sha256` freezes all 168 rows.

## Go baseline runner — runner infrastructure, not parity evidence

Sprint 98 Story #5 (weave 9, superseding rejected weave 6) delivers the
deterministic Go-baseline executor for the executable denominator (93
applicable + 4 build-only rows). It executes the declared `baseline` mode
ONLY; the Bash++ modes stay declared in the differential schema and are
deliberately not run — no result it writes is a claim about Bash++.

```sh
tools/tour/run-baseline.sh        # explicit execution step (networked when
                                  # the pinned toolchain/helper module is
                                  # not already in the module cache)
tools/tour/validate-results.sh    # offline gate, wired into harness/run.sh
tools/tour/tamper-tests.sh        # negative self-tests for every gate
```

- **Toolchain pin** — `docs/tour/toolchain.tsv` records the exact identity
  (the full `go version` output) and the SHA-256 of the executing go binary,
  one row per measured platform. The runner resolves the toolchain via
  `GOTOOLCHAIN=go1.27.0` and fails closed unless both identity and checksum
  match; a platform without a row is unsupported, not degraded. The results
  gate independently rejects records produced under any other toolchain.
- **Helper modules** — `docs/tour/helpers.tsv` pins the official
  `golang.org/x/tour@v0.1.0` module (both h1 sums, BSD-3-Clause), which the
  pinned x/website go.mod itself requires; `pic`, `reader`, `tree` and `wc`
  are the only non-stdlib imports in the executable denominator and are
  provisioned as module dependencies from these sums, never vendored.
- **Provenance** — every copied program travels with the upstream LICENSE in
  the scratch module root, and is verified against the inventory row's byte
  count, SHA-256 and read-only `0444` mode before it can build. `TOUR_ROOT`
  must therefore be the module-cache materialization of the pin, not a
  writable git clone (clone-based inventory re-derivation remains available
  in `tools/tour/validate.sh` via `TOUR_ROOT`).
- **Oracle semantics** — mirrors upstream `content_test.go`: applicable rows
  build AND run and must exit 0; `norun` (build-only) rows build and are
  never executed; `nobuild` rows are excluded fragments and are not copied.
- **Strict UTF-8** — captured stdout/stderr are validated as strict UTF-8;
  invalid bytes REJECT the row (`fail:invalid-utf8`) and are never replaced
  or transliterated. The results file itself must be strict UTF-8.
- **Bounds and cleanup** — every child runs in its own process group with
  `/dev/null` stdin; expiry TERMs and then KILLs the whole tree (so spawned
  grandchildren die too), and the group is swept even after a clean exit so
  a program cannot leak stragglers. All child I/O uses regular files — no
  pipe exists that could block or leak — and the scratch run root is removed
  on every exit path.
- **Results** — `tests/tour/results.tsv` records per row: source bytes, sha,
  mode, the schema-coupled baseline token, build/run exits, stream byte
  counts and sha256s, the strict-UTF-8 verdict and the outcome.
  `docs/tour/baseline-pin.tsv` binds the records hash to the pinned
  inventory revision, toolchain checksum and helper module.
  `tools/tour/validate-results.sh` re-proves all of that offline on every
  harness run and fails closed on missing, duplicate, unexpected (excluded
  or unknown paths), tampered, non-pass, PLANNED, or unbound records.

## Committed corpus

The pin used to be metadata-only: every executable byte lived in a per-host
module cache, and this file said so out loud. That made the corpus
unreproducible without a network and made the BSD-3-Clause claim a promise
about bytes the repository did not actually carry — redistribution requires
the license to travel with the code it covers.

[`tour/`](../../tour) now vendors the **executable denominator** verbatim:

- **97 `.go` programs** — every `applicable_go_program` (93) and
  `build_only_go_program` (4) inventory row — at their upstream
  `_content/tour/...` paths, copied byte-exact from the pinned module
  materialization.
- **`tour/LICENSE`** — the upstream BSD-3-Clause LICENSE, verbatim.

Not vendored, on purpose: the 9 `nobuild` exercise skeletons and the 62
article inline blocks (both `excluded_fragment` — the oracle's own
`content_test.go` never executes them), the `.article` lesson prose, the
static web assets, and any upstream code outside `_content/tour`.

`docs/tour/corpus.tsv` pins what the inventory join cannot: the corpus root,
the LICENSE digest, and the file counts. `tools/tour/validate-corpus.sh` is
the offline gate, wired into `harness/run.sh`: it re-proves the inventory
against the pin's frozen hash first, then demands **path-set equality in both
directions** (missing files, extra files, same-count renames, and smuggled
excluded fragments all fail — a count-only check lets every one of those
through), rejects symlinks and non-regular files standing in for sources,
and verifies every committed byte count and SHA-256 against its inventory
row. With `TOUR_ROOT` set it additionally byte-compares every corpus file
against the pinned source materialization — the proof an offline hash cannot
give, and the only thing that catches an attacker who edits a source *and*
repins the inventory hash (the reviewed pin is the trust anchor; that
residual is asserted explicitly in `tools/tour/corpus-tamper-tests.sh`, all
18 fail-closed probes).

## Gates

```sh
tools/tour/validate.sh                                   # offline
TOUR_ROOT=<module cache dir or git clone> tools/tour/validate.sh
tools/tour/validate-corpus.sh                            # offline (harness-wired)
TOUR_ROOT=<module cache dir> tools/tour/validate-corpus.sh
tools/tour/validate-results.sh                           # offline (harness-wired)
tools/tour/run-baseline.sh                               # explicit baseline execution
tools/tour/tamper-tests.sh                               # fail-closed self-tests
tools/tour/corpus-tamper-tests.sh                        # fail-closed corpus self-tests
tools/tour/refresh.sh                                    # intentional re-pin
```

## Three-mode JSONL evidence

Sprint 98 / Story #4 records exactly 97 programs by three modes (291
attempts) in `tests/tour/evidence.jsonl`. Its manifest binds the inventory,
the accepted pinned-Go observation file and pin, the exact Go 1.27 binary
(cross-checked against `docs/tour/toolchain.tsv`, not just self-consistency —
a Go 1.26 binary rejects), the exact Bashy executable, and the versioned
normalizer checksum. Each attempt retains base64 raw stdout and stderr,
spawn/state/exit facts, and derived normalized bytes and hashes.

`bpp_compiled` is a real three-stage pipeline, not a single command: bashy
**transpiles** the pinned Go source, the exact pinned Go 1.27 toolchain
**builds** the transpiled output, and the resulting binary is **executed**.
The recorded raw/state/exit belong to whichever stage is authoritative — the
first stage that fails to produce its declared artifact, or the executed
binary itself when every stage succeeds — never just the transpiler's own
output.

Evidence generation requires a clean, published, reproducible Bashy binary
(`bashy self fetch`, or any build whose `--version` names a release tag with
no `-dirty` suffix); a workspace dev build is refused before a single
attempt runs. `BASHPP_BIN` must be set explicitly — there is no dev-binary
fallback.

`tools/tour/validate-evidence.sh` runs two independent layers, neither of
which trusts the producer:

- **Structural** — revalidates the accepted baseline, decodes every raw
  stream, runs the pinned normalizer again, rebuilds comparison outcomes,
  coverage, summary, evidence root and verdict, and checks mode-specific
  executable/command binding (including the transpile/build/run pipeline
  binding for `compiled`). This alone cannot detect a ledger whose raw bytes
  were copied between rows — a copy is internally consistent, so every
  recomputed hash still balances. Builder provenance is re-derived from the
  live binaries, not the manifest: the Go builder's `go version` output and
  the bashy `--version` output are both re-executed and cross-checked against
  `docs/tour/toolchain.tsv` and the published-release/dirty parse, so a Go
  1.26 builder, a dev/dirty bashy, or a fabricated version string paired
  with a true checksum is refused however internally consistent the ledger is.
- **Process (replay)** — re-executes every one of the 291 attempts for real,
  against a freshly materialized module, using the exact pinned Go 1.27
  binary and the exact bashy binary named in the manifest, and requires the
  fresh spawn/state/exit (and, for the two Bash++ modes, the fresh
  normalized output) to match what the ledger recorded. A forged row's raw
  bytes did not come from executing *its own* bound command, so replaying
  that command reproduces different bytes and the row is rejected — the
  external attestation the structural layer alone cannot provide. Only
  pinned-Go baseline rows tolerate byte drift (official Go programs are not
  all deterministic), and only once their spawn/state/exit already match a
  fresh run.

A missing Bash++ compiler remains a checked-in, structurally valid `FAIL`
verdict rather than disappearing as a skip or an aborted run.

```sh
tools/tour/run-evidence.sh
tools/tour/validate-evidence.sh
tools/tour/evidence-selftests.sh    # real launch/deadline/process-tree probes
tools/tour/evidence-tamper-tests.sh # rejects synthetic equality AND full-ledger
                                    # baseline-cloning forgery (real per-row
                                    # commands, forged process/raw fields)
```

`TOUR_ROOT` mode re-derives the inventory from a local source (module cache
directory or git clone at the pinned commit) and diffs it against the
checked-in denominator. The refresh extractor is itself fail-closed:
unresolved `.play`/`.image` references, unknown present directives, missing
`go.mod`/`LICENSE`, a `.go` file without the oracle's `//go:build … OMIT`
first line, or a program that is neither `.play`-referenced, a solution, nor
the reviewed UI-served sandbox aborts the derivation.
