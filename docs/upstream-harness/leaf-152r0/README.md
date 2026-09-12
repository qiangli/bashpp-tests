# leaf-152 run 0 — the Sprint 152 denominator on the Sprint 151 candidate

Input: `../leaf-152/roots-r0.tsv` (249 roots: Barrier A active-152 ∪
leaf-151r2 moves ∪ `dwarf/linedirectives.go`). Candidate: bashy `963ef4b`
(`bashy.real` sha256 `c877b61f…`, rebuilt fresh in `/srv/sprint152` and
byte-identical to the Sprint 151 candidate), shell runtime `e484a22b`, Go
1.27.0 linux/amd64, `GOMAXPROCS=2 GOFLAGS=-p=2`, 60 s bound. Harness
`3887d59` ran the gate; the manifests here were re-emitted from the run's
unchanged events with the v5 partition rules (`3dea223`: `retained` owner,
build-header skip, source-map rule). 2026-09-12 08:53Z–09:10Z, exit 3, zero
seam failures, no survivors.

| lane | terminals | non-PASS |
|---|---:|---:|
| native | 249 | 0 |
| interpreted | 249 | 109 |
| compiled | 249 | 113 |

**115 of 249 roots pass both modes; 134 do not.** Ownership of the 134:
152 = **84**, 154 = 23, retained = 23, 151 = 1, 153 = 1, unclassified = 2.

The 84 that 152 owns, by first-line mechanism (rows, both modes listed):
asmcheck `opcode not found` / interpreted `unsupported` on the same root —
55 roots (all H1 of `sh/lower/testdata/sprint152/fidelity/FINDINGS.md`: the
`-S` listing prints `origin:line[generated:line]`, which upstream `asmCheck`
cannot index; the opcodes themselves were verified identical);
`MustValue returns 1 value` tuple lowering — 9; unused aliased imports — 8;
`invalid column number: 0` line directives — 5; `LOWER-EUNDEFINED` /
`LOWER-ETYPE` singletons — 7; user `//line` pass-through — 2; runtime-shaped
(`panic:`) — 2, to be triaged toward 153.

**The Barrier A cluster of 111 literal relative imports is 0 rows here** —
it was measured before S151.1 linked the package map at lowering time.
