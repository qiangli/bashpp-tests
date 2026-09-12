# Barrier A — Sprint 151 (S151.0, `fd3a390ec1f2`)

One fresh run of `corpus-gate.sh` from `/srv/sprint151/barrier-a` on the
authorized Linux host, 2026-09-12 01:15Z–02:50Z, harness `5a6254d` with
the pins overridden for the run to the **frozen Sprint 150 candidate**
(Bash++ `be20731` sha256 `9d6adf35…`, sh `828e5b33`; Go 1.27.0 linux/amd64
at the Sprint 142 authenticated SDK; `GOMAXPROCS=2`, `GOFLAGS=-p=2`;
backend-lane deadline 60 s). Exit 3, **zero seam failures, zero surviving
processes**. A first attempt (23:36Z–01:07Z) was killed when the interpreted
lane was found unbounded (`test/deferfin.go` at 62 min) — the deadline is
the fix; its log is retained as `logs/corpus-linux.attempt1.log`.

| Runner | native PASS/non-PASS | PASS | FAIL | SKIP | total |
|---|---|---:|---:|---:|---:|
| testdir | 2689 / 37 | 1289 | 1400 | 37 | 2726 |
| typechecker | 897 / 2 | 794 | 103 | 2 | 899 |
| package | 26 / 0 | 0 | 26 | 0 | 26 |
| **total** | | **2083** | **1529** | **39** | **3651** |

Under the exact upstream runners the corpus is 3,651 roots; the Sprint 142
inventory selected 743 of the 899 typechecker leaves. PASS = both modes
pass. Interpreted non-PASS: 1265 / 105 / 26; compiled: 785 / 105 / 26.

Partition (`partition-emit.go` at `active-*` below, applied to the retained
evidence; first-line rules, lower sprint wins for a root whose modes
classify differently): **151: 955 · 152: 234 · 153: 162 · 154: 120 ·
unclassified: 58** (`active-unclassified.tsv` is the manager's hand-triage
list, kept visible rather than forced). Root-list digests in
`active-rootlists.tsv`.

Movement of the 392 Sprint 142 seed roots (packets 151.1–151.5): 355 stay
in 151, 25 → 153 (all from 151.5: bridge lifecycle), 2 → 154, 10
unclassified, 0 PASS — the frozen candidate is the Sprint 142 one for them.

Evidence: `/srv/sprint151/barrier-a/{evidence,logs,manifests-v4}` (build
caches removed). The Sprint 151 leaf runs on the new candidate use
`BASHPP_CORPUS_ROOTS=docs/upstream-harness/active-151-manifest.tsv`.

## Leaf 151, run 1 — the Sprint 151 candidate

`BASHPP_CORPUS_ROOTS=active-151-manifest.tsv` (955 roots) on Bash++
`963ef4b` (sha256 `45ac52dc…`) / sh `180852d0`, harness `65c5c20`, same
host and knobs, 2026-09-12 03:08Z–04:04Z, exit 3, zero seam failures, zero
survivors. Native lane 829 / 101 / 25 (one package root of the 26 is not in
this leaf). Result: **88 PASS (both modes)**; interpreted non-PASS 829 → 731
(testdir), compiled 829 → 212; typechecker 101/101 and packages 25/25 still
non-PASS. Partition of the 867 failing roots: 151: 833 · 152: 9 · 153: 16 ·
154: 4 · unclassified 5 (`leaf-151/`). The package-map refusal class
(140 roots at Barrier A) is gone — S151.1's mechanism. `leaf-151/rebind.tsv`
re-binds the 833 remaining roots to the five cards by first line: checker
verdict 247 · evaluator builtins/collections/exprs 208 · generics/interfaces
109 · pointers/nil/selectors 89 · bridge/import policy 43 · converter forms 39
· goto/labels 38 · other 60.

## Leaf 151, run 2 — after wave 3

Same 955 roots, Bash++ `963ef4b` rebuilt on sh `e484a22b` (sha256
`c877b61f…`), harness `e5214bc`, 2026-09-12 05:59Z–06:55Z, exit 3, zero seam
failures, zero survivors. **197 PASS (both modes)** — 0 on the frozen
candidate, 88 after wave 2, 197 after wave 3. Interpreted non-PASS 731 → 622
(testdir), 99/101 typechecker, 25/25 packages; compiled 212 → 166. Partition
of the 758 failing roots: 151: 698 · 152: 14 · 153: 26 · 154: 7 ·
unclassified 13 (`leaf-151r2/`). Per run-1 cluster: checker verdict 247 →
236 (28 are gc-only checks go/types cannot express; 99 are the typechecker
harness's own `assert`/`trace` builtins and tab-indented notes; 3 wording →
154) · evaluator builtins/collections/exprs 208 → 203 · generics/interfaces
109 → 71 · pointers/nil/selectors 89 → 75 (23 need nil-deref to enter the Go
panic/recover path, 13 nil into scalar-only consumers) · bridge/import policy
43 → 43 · converter forms 39 → 32 · goto/labels 38 → 6 (2 body-less
declarations, 3 multi-package compiledir, 1 other) · other 60 → 57.
Per-cluster findings: `sh/gosource/testdata/sprint151/{checker,generics,
pointers,goto}/FINDINGS.md`. Rows that left 151 did so through these
manifests; the 698 that remain are Sprint 151's recorded residue for the
151–154 integration run.
