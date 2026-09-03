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

## Gates

```sh
tools/tour/validate.sh                                   # offline
TOUR_ROOT=<module cache dir or git clone> tools/tour/validate.sh
tools/tour/refresh.sh                                    # intentional re-pin
```

`TOUR_ROOT` mode re-derives the inventory from a local source (module cache
directory or git clone at the pinned commit) and diffs it against the
checked-in denominator. The refresh extractor is itself fail-closed:
unresolved `.play`/`.image` references, unknown present directives, missing
`go.mod`/`LICENSE`, a `.go` file without the oracle's `//go:build … OMIT`
first line, or a program that is neither `.play`-referenced, a solution, nor
the reviewed UI-served sandbox aborts the derivation.
