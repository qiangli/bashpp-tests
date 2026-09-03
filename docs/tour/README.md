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
- license: BSD-3-Clause (upstream `LICENSE` preserved in provenance; this
  repository vendors no upstream code, only hashes and metadata)

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

## Gates

```sh
tools/tour/validate.sh                                   # offline
TOUR_ROOT=<module cache dir or git clone> tools/tour/validate.sh
tools/tour/validate-results.sh                           # offline (harness-wired)
tools/tour/run-baseline.sh                               # explicit baseline execution
tools/tour/tamper-tests.sh                               # fail-closed self-tests
tools/tour/refresh.sh                                    # intentional re-pin
```

`TOUR_ROOT` mode re-derives the inventory from a local source (module cache
directory or git clone at the pinned commit) and diffs it against the
checked-in denominator. The refresh extractor is itself fail-closed:
unresolved `.play`/`.image` references, unknown present directives, missing
`go.mod`/`LICENSE`, a `.go` file without the oracle's `//go:build … OMIT`
first line, or a program that is neither `.play`-referenced, a solution, nor
the reviewed UI-served sandbox aborts the derivation.
