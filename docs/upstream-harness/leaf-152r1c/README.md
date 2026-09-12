# leaf-152 run 1c — the 23 run-1b roots on candidate 3

Input: `../leaf-152/roots-r1c.tsv`. Candidate 3: bashy `963ef4b` on shell
runtime `790dbbf3` (`bashy.real` sha256 `72768224…`) — adds the converter's
C3 (constants and var initializers as written), C1 (`//go:*` directives
through the converter), no aliases for unused imports, and Go-order tuple
splits; harness `a411b23`. 2026-09-12 12:25Z–12:43Z, exit 3, zero seam
failures.

| lane | terminals | non-PASS |
|---|---:|---:|
| native | 23 | 0 |
| interpreted | 23 | 14 |
| compiled | 23 | 16 |

Ownership (v6 rules): **152 = 18**, retained = 5 (asmcheck roots whose
compiled mode now passes: `append`, `condmove`, `issue59297`,
`regabi_regalloc`, `slices`-class rows), both-mode PASS = 0 of the 23 (every
root here was a residue root).

The 18, by mechanism, with the cause localized on this candidate:
`"unsafe" imported … and not used` — 8 roots: a `const x = unsafe.Sizeof(…)`
initializer is constant-folded, so the generated file no longer references
the import (C3 covered expressions and vars, not `const`); asmcheck — 6
roots (`clobberdead`, `comparisons`, `issue60324`, `memops`, `switch`,
`zerosize`): grouped specs (`var p1, p2, p3 T`) are split and declarations
re-ordered (C11, landed on the S152.1 polish branch after this candidate);
`alias3.go` (alias declaration across the package map) and
`fixedbugs/issue24801.go` (a non-function `main` in a non-main package
colliding after linking) — converter; `issue18149.go` / `issue22662.go`
interpreted-mode user `//line` reporting — interpreter, routed to 153.
