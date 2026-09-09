# Sprint 118 candidate021 Go-by-Example replay

Candidate021 is the current frozen runtime candidate for Story 3. It uses
`sh` `05c215e870270163a2e999bd6263f213e1e684db` and `bashy`
`9df0f148d82905d15b9af56405e8cf3cb8879bc7`. Its manifest is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-021/candidate.json`
with SHA-256
`cd6d16511fbfc7c771c7f0d5ff91584a152a7c08d3c86f1890f734f73c2b6770`.

The complete authenticated replay recorded all 255 required observations:

- oracle: 85 pass
- compiled: 85 pass
- interpreted: 57 pass, 24 mismatch failures, 4 normalization failures
- missing or unspawned: 0

This is four interpreted passes better than candidate018. The new passing
programs are arrays, base64 encoding, custom errors, and recover. Candidate020
briefly tested a generic receiver conversion and exposed two compiled-mode
regressions; that conversion was reverted before candidate021 was built. A
candidate020 JSON streaming mismatch was also shown to be order-sensitive:
candidate021 produced the alternate permitted map order in both native and
compiled modes and passed that row.

The retained evidence is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-021/gbe-full.jsonl.fail`.
Its file SHA-256 is
`361784b500fd0d5b03617dd0de6ce7087cc46dd22948703537d8889bdcf47766`
and its authenticated root digest is
`c005009bb0cef9e0ab16b2560bf4aeeb55180d63ad7b64f64c32a06f89285f98`.
`tools/go-by-example/validate-evidence.rb` independently reconstructed the
255-attempt denominator, verdicts, and root and passed after the root was added
to `evidence-roots.tsv`.
