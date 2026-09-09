# Sprint 118 Candidate023 Go-by-Example replay

Candidate023 freezes `bashy` `e723079e208b103dd06617c4473f6c50c7649ed7` and `sh` `70ec295a837dbe9feb6dde193d5517c95032fda0`, with the unchanged declared sibling pins. The authenticated manifest is `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-023/candidate.json` (`cd50537018bc1f72d22c564ec9dbdf93dd7e8081562b0ddbbc722f28723a258c`); independent candidate authentication passed. The five-repository frozen tree is `/private/tmp/s118-runtime-023` and is read-only.

One unfiltered run recorded all 255 attempts against the Story18 hashes: classification `9ef2a995041b76e921759d7ec73a77532f368cc581625a376b5894925e79b8a1` and corpus `add688b034869ae4b5401507c41d301670d972663d6e2c1fd7cea2f8ce017e3a`. The retained raw ledger is `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-023/gbe-full.jsonl.fail` (SHA-256 `fff84f34a7954670f6d221ea703e3eac16144b8aec2e02565bb3ff482f979fca`), with anchored root `731b5d3d29f540e39c9325b744ad6194c571254165190b8b8a92b81ae67a157d`.

- oracle: 85 pass
- compiled: 85 pass
- interpreted: 59 pass, 21 mismatches, 5 normalization failures
- attempts/executed/missing: 255/255/0

[`sprint118-candidate023-ledger.tsv`](sprint118-candidate023-ledger.tsv) retains every attempt. Independent evidence validation passed. Port 8090 was free before the run and free after release.

The compiled hypothesis held after `new(value)` plus `map_order`; interpreted remains 59/85, so Story3 stays open.
