# Sprint 118 candidate022 Tour certificate

The complete unfiltered Tour executor passed candidate022 with all 291
required observations:

- baseline: 97 pass
- interpreted: 97 pass
- compiled: 97 pass
- semantic rows: 11, with 77 native oracle runs

The authenticated candidate uses `sh`
`69579ce6a96a53918bbe05214d77c32d5135c516` and `bashy`
`67886176d8a50c555714e97a96ce57ee4835479f`. Its candidate manifest is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/candidate.json`
with SHA-256
`5e336da824fc062d07c0428ae6a7e4b8c6ec8ac6ac56bd14312bdf1157d72eb9`.

The retained ledger is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/tour-results.jsonl`.
It contains 306 JSONL records, has SHA-256
`d88148897fed9289cbf514c58e47dc4cc4cef29af4e04e0e2836e68c7bad354c`,
and its independently reconstructed root is
`7ed32790650624062368691670d8abd73d535fb31dfaac341c5750a74b1d0548`.

The run used:

```sh
BASHPP_BIN=/private/tmp/s118-runtime-022/bashy/bin/bashy \
TOUR_CANDIDATE_MANIFEST=/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/candidate.json \
TOUR_EXECUTOR_RESULTS=/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/tour-results.jsonl \
TOUR_EXECUTOR_EVIDENCE=/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/tour-results \
bash tools/tour/run-executor.sh
```

The retained ledger was then audited offline with the same result:

```sh
TOUR_EXECUTOR_RESULTS=/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/tour-results.jsonl \
TOUR_EXECUTOR_EVIDENCE=/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/tour-results \
bash tools/tour/validate-executor.sh
```
