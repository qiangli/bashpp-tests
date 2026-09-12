# leaf-153 runs — Sprint 153 candidates on the run-0 denominator

All runs: one coordinator, fresh `/srv/sprint153`, `GOMAXPROCS=2 GOFLAGS=-p=2`,
the unchanged upstream 60 s deadline, `bashy` `963ef4b` with the shell runtime
at the pinned candidate (`tools/upstream-harness/backend-pin.tsv`
`shellrt_commit`). Manifests are partition-v9 emits of each run's unchanged
events (`r1c/`, `r1d/`; `r1a/`, `r1b/` are v7/v8 emits — the v9 rules only
move `goroutine stack exceeds` → 153 and `unknown field` → 151).

| run | candidate (`sh`) | input | PASS both | 153 | 151-shaped | notes |
|---|---|---:|---:|---:|---:|---|
| r0 (`../leaf-153r0/`) | `e0764249` (cand. 4 of S152) | 192 union | 4 | 136 | 4 | the denominator |
| r1a | `b6b31327` | 136 | 29 | 94 | 13 | 4a bridge values + 4b evaluator + output |
| r1b | `4260767f` | the 107 r1a non-PASS | +10 | 77 | 19 | + S153.2 bridge callbacks/writers/methods, S153.3 |
| r1c | `61ae717d` | 136 | 43 | 74 | 19 | + evaluator pass 2, call-path performance |
| r1d | `61ae717d` | 136 | 43 | 74 | 19 | the required repeat: **42 roots pass both runs**; `atomicload.go` (r1c only) and `fixedbugs/issue22781.go` (r1d only) each passed once — both finish in ~9 s locally and sit at the 60 s bound on the 2-core host |

Residue on the final candidate (union of r1c/r1d, 75 roots in 153): 17
deadline (fib family ~22–25×, `issue79186` ~256×, `divconst`/`modconst`,
`stack.go`, the two load-sensitive roots, and 4 that are really C1b/C2/C3
bridge residue), 2 Go-stack exhaustion (`peano`, `closure`), 12 retained
callbacks (`SetFinalizer`, `testing.AllocsPerRun`, `reflect.MakeFunc` — by
design or unbounded), 12 self-check panics, 10 exact-output rows, 4
unregistered generic bridge types, 3 bridge writeback rows, 4 compiled rows
(`bug367`, `issue29919`, `issue42401`, `issue52856`), 2 `scalar call
interrupted`. The 4 compiled linker/emitter rows (`issue29919`, `issue19467`,
`issue20014`, `rangegen`) are recorded for 152 in
`sh/interp/testdata/sprint153/compiled/FINDINGS.md`.
