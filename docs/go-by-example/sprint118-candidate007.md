# Sprint 118 candidate007 — complete failing replay

Candidate manifest `e7ca9dd1b8f0bd1ec1737540dc0efb009f4ed0ba7def7d404f47bab26299e4df`
binds sh `4340d450` and Bashy `ea60f34`. No original example bytes changed.
All 85 rows have all three attempt records (255). The gate reports 253 spawned
attempts, two unspawned attempts and four incomplete mode results. This is FAIL.

| Mode | PASS | Mismatch | Normalization failure | Incomplete |
|---|---:|---:|---:|---:|
| Native oracle | 85 | 0 | 0 | 0 |
| Interpreter | 35 | 39 | 9 | 2 |
| Compiled | 83 | 0 | 0 | 2 |

All 29 candidate006 interpreter passes are retained. Six new passes are
http-client, sha256-hashes, string-functions, time-formatting-parsing,
url-parsing and writing-files. This does not establish full compatibility.

Signals and TCP server report input_mutation for interpreter and compiled modes.
A separately assigned lifecycle investigation must determine the exact cause;
no integrity guard, source pin or comparator is relaxed. The retained ledger is
historical evidence even after the defect is repaired. Corpus story #3 remains open.

Raw evidence, per-stage commands, artifacts and complete streams:
`~/.local/state/bashy/sprint118-evidence/runtime-integration-007/gbe/results.jsonl.fail`
and its adjacent `results.jsonl.work` directory. The committed parallel ledger
is `sprint118-candidate007-ledger.tsv`; failure taxonomy is adjacent to the raw
run under `taxonomy/`.

Root digest: `cb0cba13457bf13da68a1250276d4b2e2b13fc7d874570ddea1af2588db4fada`.
The repository anchor records this failing result, not a sprint closure.
