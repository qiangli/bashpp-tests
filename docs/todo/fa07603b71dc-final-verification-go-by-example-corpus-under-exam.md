---
id: fa07603b71dc
kind: task
title: 'Final verification: Go by Example corpus under examples/'
seq: 3
status: done
priority: p1
created: 2026-09-03T09:45:35.902827Z
weave: 44
assignee: qiangli
sprint: 118
closed: 2026-09-10T07:28:41.663697Z
---

Candidate021 remains the accepted stable baseline: oracle 85/85, compiled 85/85, interpreted 57/85, root c005009bb0cef9e0ab16b2560bf4aeeb55180d63ad7b64f64c32a06f89285f98 under /Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-021.

Candidate022 is frozen at sh 69579ce6a96a53918bbe05214d77c32d5135c516 and bashy 67886176d8a50c555714e97a96ce57ee4835479f, covering the named post-candidate fixes (new(T), variadic range, named scalar map keys, slices.Equal/Sort) plus the follow-up numeric-slice correction that the bashy sibling pin requires. Manifest 5e336da824fc062d07c0428ae6a7e4b8c6ec8ac6ac56bd14312bdf1157d72eb9 is registered in candidates.tsv and independently re-derived by validate-candidate.rb; the frozen tree /private/tmp/s118-runtime-022 was made read-only after the build and was not mutated to register it. The full 255-observation replay ran with port 8090 exclusively owned: 255 attempt records, 254 executed, 1 unspawned; root 63cf7bf7a735959d66434eedb4c5ed431df19669289a05f127fb08d23605f8df, anchored in evidence-roots.tsv and re-verified by validate-evidence.rb. Every failure is retained under runtime-integration-022; see docs/go-by-example/sprint118-candidate022.md and sprint118-candidate022-ledger.tsv.

Candidate022 is NOT an unambiguous advance. Interpreted rose 57 -> 59 (enums, slices now pass). Compiled fell 85 -> 83, and exactly two rows moved:

1. Product regression to reverse. examples/pointers/pointers.go no longer transpiles: `p := new(42)` (Go 1.26 new-of-value, which the pinned oracle compiles) fails with `gosource: unsupported type *ast.BasicLit`. Cause is the `new` short-decl branch added by sh 47cce082, which routes every `new(...)` through the type path. Verified remedy, built and run in a scratch clone outside all frozen and tracked trees: guard the branch with `len(rhs.Args) == 1 && c.info.Types[rhs.Args[0]].IsType()` so a value argument falls through to the path candidate021 used. With the guard the row transpiles, builds and matches the oracle byte for byte; its interpreted verdict is unchanged.

2. Corpus classification defect, no schema decision taken here. examples/json/json.go is classified deterministic/none/none, but both of its map-encoding lines are emitted in Go map iteration order by encoding/json/v2 in the ORACLE itself (40 runs each: 35/5 and 34/6 splits). Every verdict this row has produced in any anchored chain has been a coin flip; candidate021's compiled pass and candidate022's compiled mismatch are both luck. The row needs behavior map_iteration with the licensed map_order normalization, as examples/range-over-built-in-types already has. Making that change re-baselines classification_sha256 and corpus_sha256 and invalidates every anchored root including 021 and 022, so it must be decided deliberately rather than absorbed into a candidate comparison.

Next: land the new-of-value guard in sh, decide the json classification, then freeze and authenticate Candidate023 and rerun all 85 rows and 255 observations with port 8090 exclusively owned. Retain every failure. This story stays open until all applicable interpreted rows pass and the compiled column is back at 85.

Manager update 2026-09-09 22:13 UTC: the new-of-value guard is pushed in sh 70ec295a837dbe9feb6dde193d5517c95032fda0 and pinned by bashy e723079e208b103dd06617c4473f6c50c7649ed7. Story #18 deliberately landed the JSON map_iteration/map_order rebaseline in bashpp-tests b68504d7f89d32591fbb2273b6f56027be705231 without rewriting Candidate021/022. Run 44 owns the serialized Candidate023 freeze and complete GbE/Tour replay; port 8090 was free at assignment.

Candidate023 is frozen/authenticated at those exact revisions in `/private/tmp/s118-runtime-023`; all declared sibling pins are preserved and the tree is read-only. Its one complete Story18-baseline GbE run independently validated 255/255 executed attempts: oracle 85, compiled 85, interpreted 59 (26 retained failures), root 731b5d3d29f540e39c9325b744ad6194c571254165190b8b8a92b81ae67a157d. The subsequent one complete Tour executor retained 291 observations plus semantic oracles but its validator failed honestly on baseline/compiled goroutine multiplicity (4 observed versus native 5..5). No reruns occurred; Story3 remains open.
