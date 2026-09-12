# leaf-153 run 0 — the Sprint 153 denominator on candidate 4

Input: `roots-r0.tsv` — the 192-root union of Barrier A's `active-153-manifest.tsv`
and the 153 rows moved in by the 151/152 leaf runs (`leaf-151/`, `leaf-151r2/`,
`leaf-152r0/`, `leaf-152r1b/`). Candidate 4: sh `e0764249`, bashy `963ef4b`,
`bashy.real` sha256 `ba50a56d…` (the Sprint 152 run-1d binary). One coordinator,
fresh `/srv/sprint153`, `GOMAXPROCS=2 GOFLAGS=-p=2`, upstream 60 s deadline.
14:58Z–15:22Z, exit 3, survivors 0 (`status.txt`).

Result: 192 roots → 4 PASS both modes · **153: 136** · 151: 4 · 154: 11 ·
retained: 35 · 152: 0. Manifests here are the partition-v7 emit of the run's
unchanged events (v7 = cgo roots retained by D1, and a leading-path-only
GOROOT strip so a goroot path quoted inside a message no longer truncates the
diagnostic).

What left 153 on re-measure, as predicted by the plan: the 37 compiled
`panic: nil pointer dereference` rows were the emitter crashing on body-less
function declarations; `sh` `1f674e4c` turns them into
`LOWER-EUNSUPPORTED: function declaration without body` (retained), so those
roots are now `retained` (compile-only roots) or 154's (`errorcheck -m` roots
whose interpreted row is a missing diagnostic). 11 cgo roots are retained.
`64bit.go`, `reorder.go`, `typeparam/issue48042.go`, `fixedbugs/issue47087.go`
now fail first with a 151 evaluator diagnostic.

153's 136 roots by mechanism (149 rows: 139 interpreted, 10 compiled):
dependency bridge 82 (slice retention 28 · type registration 16 · worker
build 10 · callbacks/writer 23 · methods 5) · deadline 22 (21 interpreted +
`rangegen.go` compiled) · evaluator semantics 25 · exact output 10 ·
compiled-mode runtime 7 (`bug367`, `issue29919` `missing a.init`,
`issue42401`, `issue52856`, `issue19467` frames, `issue20014` output,
`rangegen`).
