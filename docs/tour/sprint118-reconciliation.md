# Sprint 118 Tour provenance review

Story `2daf9ef04ad4` requested website commit
`9f4a41694f5dd210de4ab12c86c0331739266182`, permitting a justified newer reviewed
pin. The retained implementation commit `e7c4a6e` adopted website commit
`c4a9d59f9775d994f1700d18fa37414c3c85fa7b` on 2026-09-03, replacing the
repository's earlier x/tour inventory. Sprint 118 retains that reviewed pin.
The website module supplies the lesson assets behind the `go.dev/tour` URL;
the separately pinned x/tour module supplies helper imports where the lessons
use them. The URL itself is not a source repository.

The manager independently verified the downloaded website module archive
against the pinned module-content sum
`h1:sKWEVclFcb47eMWJscLT/RC45vMFwwzgvPlhWHGFXSE=`, using the Go module
`dirhash.Hash1` framing over all 3,283 archive entries. Extraction from those
authenticated archive bytes reproduced the complete checked-in inventory
byte-for-byte. All 97 vendored program files also matched the archive exactly.

The resulting obligations are:

| Classification | Rows | Sprint execution obligation |
|---|---:|---|
| Applicable program | 93 | Native Go, Bash++ interpreted, and compiled artifact |
| Build-only program | 4 | Native build, semantic check, and compiled build; no body execution |
| Inline lesson fragment | 62 | Retain provenance and fragment classification |
| Explicit upstream `nobuild` program | 9 | Retain upstream directive and fragment classification |

[fragment-audit.tsv](fragment-audit.tsv) identifies all 71 fragment rows.
Each of the nine program exclusions has an explicit `nobuild` directive
in its original first line. `OMIT` alone does not exclude a program;
the runnable lesson files also use that build tag.

[sprint118-provenance.json](sprint118-provenance.json) records archive,
extractor, and inventory identities. The manager's retained gate is
`tour-provenance-manager-gate.json`, with complete extraction evidence under
`tour-provenance-001`. The inventory can be reproduced using
`bash tools/tour/refresh.sh --inventory-only AUTHENTICATED_WEBSITE_MODULE_ROOT`;
the argument is the module root containing `_content/tour`, not its
`tour` subdirectory. Authenticate the archive against the pinned content sum
before trusting a module-cache directory or comparing extracted files.

This review establishes source provenance and the pinned inventory denominator.
Execution parity remains a separate requirement of the parent stories.
The historical inventory phase token containing `transpile-build-run` for
build-only rows does not authorize running those bodies; the current executor
contract must end that phase after the build.

