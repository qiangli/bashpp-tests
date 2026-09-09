# Retained source-map validator data

Sprint: #118; Story: #15; Story-ID: 6c22a04c63d6

`functions.generated.go.txt` and `functions.map.json` are byte-for-byte copies
from the first PASS row of the retained Sprint 118 `diagnostic-candidate-001`
results: `tour/_content/tour/basics/functions.go`. The original source remains
in the existing Tour corpus and is never modified by these tests.
`provenance.json` retains the original source, generated file and map digests,
candidate launcher/payload digests, and SDK identity. Tests check these digests
without accessing a host-specific evidence directory, network, compiler or CLI.
This fixture is validator data from a diagnostic candidate, not a new product
PASS or a claim of final corpus certification.

The two `empty-*.go` sources form a legitimate package with no declarations.
Their generated file was emitted by the actual gosource/lower library with
`RunMain: false` using sh commit `724f1d1b` and Go 1.27.0. The retained generator
`retain-empty.go.txt` serializes the actual source metadata and empty mapping
list into the CLI map schema. It explicitly rejects unexpectedly nonempty
mappings. To regenerate, run its copied `.go` file from that sh module with
this fixture directory as its single argument. This tests a real empty package
without requiring the execution CLI to accept a package lacking `main`.

The tests mutate temporary copies only. They reject missing, reordered,
duplicated and incomplete metadata/mappings, incorrect byte positions, and
same-size source/generated-file changes even when supplied hashes are stale.
