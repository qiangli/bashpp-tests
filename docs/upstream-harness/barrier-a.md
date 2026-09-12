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
