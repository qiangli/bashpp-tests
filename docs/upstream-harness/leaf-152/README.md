# leaf-152 — Sprint 152 leaf runs

`roots-r0.tsv` is the run-0 input: the Barrier A `active-152-manifest.tsv`
(234 roots, measured on the frozen Sprint 150 candidate) ∪ the 14 roots
`leaf-151r2/active-152-manifest.tsv` moved in ∪ `testdir:dwarf/linedirectives.go`
(unclassified at Barrier A; a source-map root by its first line). The
`mode`/`first_line` columns are the Barrier A / leaf-151r2 observations and are
informational — the leaf form reads column 1 only and runs both modes.

Run 0 re-measures this set on the Sprint 151 candidate (`backend-pin.tsv`:
bashy `963ef4b`, shell runtime `e484a22b`) BEFORE any Sprint 152 product
edit: the active manifest predates S151.1's link-at-lowering-time, so its
largest cluster (111 literal relative imports) is expected to have collapsed.
Results land in `leaf-152r0/` per the leaf-151 shape.
