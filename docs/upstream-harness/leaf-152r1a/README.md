# leaf-152 run 1a — the 55 asmcheck roots after the H1 listing fix

Input: `../leaf-152/roots-r1-asm.tsv` (the 55 `codegen/` roots 152 owned
after run 0). Candidate unchanged from run 0 (bashy `963ef4b` /
`c877b61f…`, sh `e484a22b`); harness `d8dfddf` — the backend now hands
upstream `asmCheck` the `-S` listing with the `origin:line[generated:line]`
suffix removed (run 125), after `backend-gate.sh` re-proved native
equivalence (9/9) on that hook. 2026-09-12 09:18Z–09:24Z, exit 3.

| lane | terminals | non-PASS |
|---|---:|---:|
| native | 55 | 0 |
| interpreted | 55 | 55 (declared `unsupported`: assembly is a compiler artifact) |
| compiled | 55 | **14** (was 55 at run 0) |

Ownership with the v6 rules: 152 = 14 (real pattern misses, every one a
class the emitter owner is removing — sinks/register allocation, `main`
rename, checked assertions, symbol spelling), retained = 41 (compiled PASS,
interpreted `unsupported`). The v6 rules skip the logged listing lines
(`STEXT`, `0x…`, position tails) that upstream prints before its verdicts,
and rank `retained` last so an unclassified failure is never absorbed.
