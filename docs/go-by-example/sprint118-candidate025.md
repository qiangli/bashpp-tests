# Sprint 118 Candidate025 bounded recursion diagnostic

Sprint: #118; Story: #22; Story-ID: `6fd56605a361`.

Candidate025 freezes canonical `bashy` `0740303ef6240799aa7e5595f7d7fcaba505a49a` — the published commit that bumps the `sh` pin to `05be162749be637d215a244639906a33603c3dea` for recursive-func identity — with the unchanged declared sibling pins (`coreutils ec91ea45`, `filebrowser cde11469`, `readline b958823b`). Its authenticated manifest is `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-025/candidate.json` (`3f74313ced28b23ee6e7bf738915db884ec7edb80015c191ad762241a390d213`). The five-repository frozen tree is `/private/tmp/s118-runtime-025`; its launcher hashes to `454c25a8cfb70a45e2bcb4fe57f64e7726164ed1ec8b7e46f3c243f4b87930a4` and its `.real` payload to `57a8b7680573866bb430ce31e91909d3c80a24db614aa3d99af830c8a6b4e7b7`.

This is a bounded diagnostic replay of exactly `examples/recursion/recursion.go` in oracle, interpreted, and compiled modes. It executed all three observations; it did not run the other 84 rows and makes no Go-by-Example parity claim.

| mode | pass | mismatch | unspawned |
| --- | ---: | ---: | ---: |
| oracle | 1 | 0 | 0 |
| interpreted | 1 | 0 | 0 |
| compiled | 1 | 0 | 0 |

The exact three-row summary is [`sprint118-candidate025-ledger.tsv`](sprint118-candidate025-ledger.tsv). All three observations pass: every mode exits 0, and the interpreted and compiled normalized stdout/stderr and filesystem effects are byte-identical to the oracle.

Raw JSONL, the source-hash-bound `subset-inventory.tsv`, freeze record, and retained stage streams are under `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-025/`. `gbe-subset.jsonl.pass` has SHA-256 `9fc7ce20e0a4152c7af85a5df8bfb59e2a77b2f7b3bcbfd02b954d8d7afb6564` and summary-bound root digest `af459aa1743b6378c30539b1b28b5e13219ef65dc39b2e0f1f8215e90c89307a`. The retained footprint is 104 KiB after reproducible binaries, staging inputs, and caches were pruned.

The standalone `validate-bounded-evidence.rb` authenticates the reviewed candidate and independently checks the exact one-row inventory, repository sources, retained streams, three attempts, public summary, and externally pinned evidence/root digests. It is now candidate-aware and authenticates both the Candidate024 two-row diagnostic and this Candidate025 one-row diagnostic; the shared append-only `candidates.tsv` is bound by its current digest and by re-deriving each reviewed row, so appending Candidate025 does not invalidate the older bounded run. `bounded-evidence-selftests.rb` runs the source, inventory, retained-stream, candidate-table, and recomputed-root tamper checks against both diagnostics. No production gate or validator accepts a bounded inventory, and `gate.rb`, `validate-candidate.rb`, `validate-evidence.rb`, and `validate.sh` are byte-identical.
