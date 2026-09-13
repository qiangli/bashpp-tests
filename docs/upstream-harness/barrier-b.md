# Barrier B — Sprint 155 (S155.0, `189482e458a9`)

One fresh run of `corpus-gate.sh` from `/srv/sprint155/barrier-b` on the
authorized Linux host, 2026-09-12 22:24:36Z–23:48:58Z (1 h 24 min), exit 3,
**zero seam failures, zero surviving processes**. Harness `cae8610` (the
S155.0 pin commit) on the **published integrated candidate** — the umbrella
pins after Sprints 151–154 and 160: Bash++ `548c3a4` (sha256 `9f18849d…`),
shell runtime `e7cd317e`, coreutils `4cb658d4`; Go 1.27.0 linux/amd64 at the
Sprint 142 authenticated SDK (binary sha256 `1db869c5…`, the Sprint 157
freeze); `GOMAXPROCS=2`, `GOFLAGS=-p=2`; backend-lane deadline 60 s; upstream
`-t` timeouts preserved. Measurement only: this run opens nothing.

## Result as the gate counts it (899 typechecker leaves)

| Runner | native PASS / SKIP | interpreted PASS / FAIL / SKIP | compiled PASS / FAIL / SKIP | PASS (both) | FAIL | SKIP | total |
|---|---|---|---|---:|---:|---:|---:|
| testdir | 2689 / 37 | 1875 / 814 / 37 | 2530 / 159 / 37 | 1839 | 850 | 37 | 2726 |
| typechecker | 897 / 2 | 879 / 18 / 2 | 879 / 18 / 2 | 879 | 18 | 2 | 899 |
| package | 26 / 0 | 0 / 26 / 0 | 0 / 26 / 0 | 0 | 26 | 0 | 26 |
| **total** | | | | **2718** | **894** | **39** | **3651** |

Barrier A on the Sprint 150 candidate was 2083 / 1529 / 39 on the same
counting. Partition v10.4 (unchanged rules, re-run by the gate at
`manifests/`, copied here as `barrier-b/active-*`):

| Owner | Barrier A (v10.4 re-emit) | **Barrier B** | compiled-FAIL roots | interpreted-only |
|---|---:|---:|---:|---:|
| 151 type/evaluator | 856 | **511** | 71 | 440 |
| 152 lowering | 210 | **19** | 19 | 0 |
| 153 runtime/output/perf | 153 | **105** | 7 | 98 |
| 154 diagnostics/parser | 180 | **7** | 6 | 1 |
| unclassified | 20 | **26** | 7 | 19 |
| retained (product-declared) | 110 | **226** | 93 | 133 |
| **total** | 1529 | **894** | **203** | **691** |

The compiled lane is close (159 testdir + 18 typechecker + 26 package =
203 FAIL); the interpreted lane carries the residue (691 roots fail
interpreted only).

## The finding that changes the denominator: 156 native-only typechecker leaves

`corpus-verify.go` (S155.7, first run against real events) reports
**312 native tested-source executions credited in the backend lanes** —
156 typechecker leaves × 2 modes. They are exactly the leaves with **no
`types-backend` record in either product lane**: `TestInstanceInfo` (68),
`TestObjectString` (34), `TestInstantiatedObjects` (22),
`TestInstantiateEquality` (22), `TestGCSizes` (4), `TestAtomicAlign` (4),
`TestHasher` (2) — Go's unit tests of the checker *API*, which never reach
the one substituted `conf.Check` call. The seam exercises the fixture
families only: `TestCheck` 148 + `TestFixedbugs` 548 + `TestSpec` 26 +
`TestExamples` 16 + `TestLocal` 5 = **743** — the Sprint 142 inventory.
Since Barrier A the gate has counted all 899 leaves and credited the 156 as
product PASS in both modes; the honest product denominator is
**3,495 roots = 2,726 + 743 + 26; 3,456 native-applicable; 39 skips**
(the two typechecker skips, `TestFixedbugs/issue78346.go` in both
packages, are inside the 743). The list of 156 is in
`corpus-verify.summary.txt`.

Restated on the product denominator:

| | PASS (both) | FAIL | SKIP | native-only (zero credit) | roots |
|---|---:|---:|---:|---:|---:|
| Barrier A (150 candidate) | 1927 | 1529 | 39 | 156 | 3495 (+156) |
| **Barrier B (published candidate)** | **2562** | **894** | **39** | 156 | 3495 (+156) |

## Under the Sprint 155 mode rule (D3)

Compiled mode is required for every native-applicable root; interpreted
mode for every root except those whose upstream expectation is a compiler
artifact (`-m` / `-live` / `-d=` optimizer diagnostics, asmcheck `-S`),
which the backend declares `unsupported` at the seam by recipe-flag rule.
From the manifests: 161 roots carry an interpreted compiler-artifact row;
126 of them fail interpreted only (zero credit, not FAIL), 35 also fail
compiled (FAIL). So:

- **blocking FAIL = 203 compiled + 565 interpreted-only non-artifact =
  768 roots**;
- zero-credit interpreted compiler-artifact rows = 126 roots;
- 39 upstream skips; 156 native-only leaves excluded from product credit.

**Barrier B is red. Sprint 155.1–155.6 do not open.** The `active-15N`
manifests here are the input of the successor repair round.

## What is in the 768

- **151 (511 roots; 71 compiled)**: the type/evaluator residue Sprint 151
  recorded — checker verdicts (incl. the 28 gc-only checks `go/types`
  cannot express), evaluator builtins/collections/exprs, generics,
  pointers/nil, bridge/import, converter forms. Includes the **26 package
  roots** (both modes: interpreted "explicit package set not supported",
  compiled `use of internal package … not allowed`).
- **153 (105 roots; 7 compiled)**: the interpreted deadline family
  (fib-shaped, ~22–256× over the 60 s bound — design-level per PERF.md),
  stack exhaustion, retained callbacks, self-check panics, exact output.
- **retained compiled (93)**: `LOWER-EUNSUPPORTED` body-less function
  declarations (transpile), cgo `import "C"` / `runtime/cgo`, backend
  `unsupported generate phase` (compile input outside the working copy)
  and `unsupported execute phase` (module package) — product FAIL under
  D3, not exclusions.
- **152 (19)**, **154 (7)**, **unclassified (26)**: small; by manifest.

## corpus-verify.go against real events

First run against real streams (`corpus-verify.summary.txt`): the native
lane, the 3,651 unique IDs and the 39-skip set verify; the 312 native
executions are the real finding above. The other violation shapes are
the verifier's record model, not the run: 1,200 `invalid event JSON`
(a field typed as string where the stream carries an object), the
per-phase accounting (multi-package `compiledir`/`rundir` roots emit one
backend record per package compile plus link/execute; the verifier expects
one per phase name), 12 `types-backend execution … has no Go terminal`
and 4 `duplicate ID` in the typechecker streams — to be fixed or explained
by the verifier owner against these streams (S155.7 follow-up).

Evidence: `/srv/sprint155/barrier-b/{evidence,manifests,logs,verify.out,
verify-manifest.sha256}` on the authorized host (build caches removed;
`/srv/sprint142`–`154`, `157` untouched). Event streams copied to the test
venue for the verifier follow-up.
