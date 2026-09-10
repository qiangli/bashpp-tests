# Sprint 118 Candidate027 bounded range-over-iterators evidence

Sprint: #118; Story: #3; Story-ID: `fa07603b71dc`.

Candidate027 freezes canonical `bashy` `f5d9d49cde6f73f4f69e77eebbbf801ffcde9117`, which pins canonical `sh` `d324dc32e25a8bbac95adba444723e0a40a568a6`, with unchanged sibling pins (`coreutils ec91ea45`, `filebrowser cde11469`, `readline b958823b`). Its authenticated manifest is `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-027/candidate.json` (`f86c94dffe4d734e00be21cf15a622a24072427653f2caeba8bb440fc77ba279`). The clean five-repository frozen tree is `/private/tmp/s118-runtime-027`; its tracked files are read-only, its launcher hashes to `454c25a8cfb70a45e2bcb4fe57f64e7726164ed1ec8b7e46f3c243f4b87930a4`, and its `.real` payload hashes to `d2da6d9cf2e369069c20c4b390092f6225ec8c36ac8349fca01ab64c4b139f3a`.

This bounded replay executed exactly the unchanged `examples/range-over-iterators/range-over-iterators.go` source (`2667` bytes; SHA-256 `7ee6216ba19fe8e06821e1e46391a5040f3ae29c289f477d17c6a5f1b8f60717`) in oracle, interpreted, and compiled modes. It did not run the other 84 rows.

| mode | pass | mismatch | unspawned |
| --- | ---: | ---: | ---: |
| oracle | 1 | 0 | 0 |
| interpreted | 1 | 0 | 0 |
| compiled | 1 | 0 | 0 |

The exact three-row summary is [`sprint118-candidate027-ledger.tsv`](sprint118-candidate027-ledger.tsv). Every mode exited 0, and interpreted and compiled normalized stdout, normalized stderr, and filesystem effects are byte-identical to the oracle.

The immutable receipt is `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-027/`. `gbe-subset.jsonl.pass` has SHA-256 `0424321650327bb8b03ed61abce40626d6cc8d607db319752b772f034fc1363c` and summary-bound root digest `1a5c5b733829aa611ad9f2658182f5dcd92a59255deb7f18c43fca727c852ee2`. The source-bound inventory has SHA-256 `ea0c1d26fefb6693673963029d386c1287db248a7a466252490d7cf547dc6afd`; the retained footprint is 104 KiB after reproducible binaries, staged source copies, caches, and telemetry were pruned while every referenced stage stream was retained.

The standalone bounded validator authenticates the exact historical `candidates.tsv` byte prefix ending at Candidate027, then independently checks the candidate, one-row inventory, repository source, retained streams, all three attempts, ledger, evidence digest, and root. Its tamper suite covers inventory/source changes, candidate-table suffix/prefix mutation, deletion, and reordering, retained-stream forgery, and a recomputed replacement root. Bounded evidence remains inadmissible to the production gate; `gate.rb`, `validate-candidate.rb`, `validate-evidence.rb`, and `validate.sh` are byte-identical.

This closes the last currently targeted Go-by-Example repair row. It is not a full 85-row replay and makes no full-parity claim: the authenticated full baseline remains Candidate023 at 59/85 interpreted passes, and a fresh full replay is deferred.
