# Sprint 118 Candidate024 bounded generic-receiver diagnostic

Sprint: #118; Story: #20; Story-ID: `405d0d96bb28`.

Candidate024 freezes canonical `bashy` `4e5db5d1a6aa43539626f25e1fce0c3ba99ec723` and canonical `sh` `e3615678760246e61ffd079300204f18bccd1e2a`, with the unchanged declared sibling pins. Its authenticated manifest is `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-024/candidate.json` (`2aef622e6c5db1a04b168e1fc508dd125c80ab7ef10eacbeab8183bc37eefd01`). The frozen tree is `/private/tmp/s118-runtime-024`.

This is a bounded diagnostic replay of exactly `examples/generics/generics.go` and `examples/range-over-iterators/range-over-iterators.go` in oracle, interpreted, and compiled modes. It executed all six observations; it did not run the other 83 rows and makes no Go-by-Example parity claim.

| mode | pass | mismatch | unspawned |
| --- | ---: | ---: | ---: |
| oracle | 2 | 0 | 0 |
| interpreted | 0 | 2 | 0 |
| compiled | 2 | 0 | 0 |

The exact six-row summary is [`sprint118-candidate024-ledger.tsv`](sprint118-candidate024-ledger.tsv). Interpreted `generics` exits 1 with `BASHPP-EGENERIC-CONSTRAINT: []string does not satisfy constraint for S in SlicesIndex`; interpreted `range-over-iterators` exits 2 with `BASHPP-ESELECTOR-TYPE: assignment parent is not struct storage`. Both oracle and compiled observations pass.

Raw JSONL, the source-hash-bound `subset-inventory.tsv`, freeze record, and retained stage streams are under `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-024/`. `gbe-subset.jsonl.fail` has SHA-256 `487d225f2ff8fc0d7002dc294e7a2b2ffc7726f803a462f2d1840e86307a6dc2` and root digest `07858fc7e7dce884e536538d4166de1e6c2670590262cdb3758e243627a011c5`. The retained footprint is 188 KiB after reproducible binaries, staging inputs, and caches were pruned.

The standalone `validate-bounded-evidence.rb` authenticates the reviewed candidate and independently checks the exact two-row inventory, repository sources, retained streams, six attempts, public summary, and externally pinned evidence/root digests. Its tamper selftests cover source, inventory, retained-stream, candidate-table, and recomputed-root attacks. No production gate or validator accepts a bounded inventory.
