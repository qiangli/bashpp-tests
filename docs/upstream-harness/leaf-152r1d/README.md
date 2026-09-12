# leaf-152 run 1d — the 18 run-1c roots on candidate 4 (final Sprint 152 leaf)

Input: `../leaf-152/roots-r1d.tsv`. Candidate 4: bashy `963ef4b` on shell
runtime `e0764249` (`bashy.real` sha256 `ba50a56d…`) — C11 source-order
emission, `any`/`F[T]` as written, C8 import spelling with alias-on-
collision, C9 tuple split re-fused, const initializers as written for
import-using consts, mapped alias/`main` identifiers; harness `3a9dba7`.
2026-09-12 13:53Z–14:07Z, exit 3, zero seam failures.

| lane | terminals | non-PASS |
|---|---:|---:|
| native | 18 | 0 |
| interpreted | 18 | 12 |
| compiled | 18 | 8 |

Ownership (v6 rules): **152 = 10**, 151 = 4, both-mode PASS = 4
(`bug338`, `bug458`, `issue17270`, `issue28601` — the `unsafe.Sizeof`
const rows).

The 10 in 152: asmcheck — 6 roots (`clobberdead`, `comparisons`,
`issue60324`, `memops`, `switch`, `zerosize`), the same six patterns on
candidates 2, 3 and 4, so their cause is not among the eleven fidelity
classes and needs a per-root `-S` diff on candidate 4;
`fixedbugs/issue22344.go` compiled `declared and not used: x` (a use dropped
by the converter); `fixedbugs/issue24801.go` compiled `cannot declare main -
must be func` (the mapped-package `main` rename does not cover this shape);
`issue18149.go` / `issue22662.go` interpreted-mode user `//line` reporting
(interpreter — 153).

The 4 in 151, by first-line rule: `alias3.go` interpreted
`BASHPP-EINTERFACE-SIGNATURE` (the alias declaration now links; the
evaluator's method-set check is next); `bug479.go`, `issue15550.go`,
`issue30709.go` interpreted `BASHPP-ECONST-EXPR` — **a Sprint 152 regression
in interpreted mode**: keeping a const initializer in source form so the
generated Go keeps its `unsafe` import hands the interpreter an
`unsafe.Sizeof(...)` it cannot fold. Fix path: the interpreter's const
evaluator folds `unsafe.Sizeof/Alignof/Offsetof` (or the converter carries
the folded value beside the raw form and the interpreter prefers it).
