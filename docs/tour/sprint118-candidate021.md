# Sprint 118 candidate021 Tour certificate

The complete Tour executor passed candidate021 with all 291 required
observations:

- baseline: 97 pass
- interpreted: 97 pass
- compiled: 97 pass
- semantic rows: 11, with 77 native oracle runs

The authenticated candidate uses `sh`
`05c215e870270163a2e999bd6263f213e1e684db` and `bashy`
`9df0f148d82905d15b9af56405e8cf3cb8879bc7`. Its candidate manifest SHA-256
is `cd6d16511fbfc7c771c7f0d5ff91584a152a7c08d3c86f1890f734f73c2b6770`.

The retained ledger is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-021/tour-results.jsonl`.
Its file SHA-256 is
`ddd2ed8c9678bdcb9f9653232a963ee1a04a999b6f7fffd43ddc477cb82285c4`
and its independently reconstructed root is
`dd30dd70884d2dfa226ace1ced47411a76ffa1d6389abbc92fa0aefd205366e3`.
`tools/tour/validate-executor.sh` passed against the repository's own pinned
inventory, contracts, normalizer, corpus, and baseline.
