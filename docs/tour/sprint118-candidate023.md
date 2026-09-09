# Sprint 118 Candidate023 Tour certificate

The one complete unfiltered Tour execution retained all 291 observations plus semantic-oracle records (306 JSONL records total) at `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-023/tour-results.jsonl`. Its file SHA-256 is `7747f3a6694b0320df8f1db940b3f98982f16c145662739f30734631e8a856a5` and canonical root is `8fce136a1cfe6a0a453e1e34fc30a8ea42c5646abe7883e08370a4f4fba1c27c`.

The Tour validator honestly returned FAIL: its `goroutine_multiplicity` semantic oracle observed four lines outside the native 5..5 range for `_content/tour/concurrency/goroutines.go` in baseline and compiled modes. This is retained; no replay was run. Port 8090 is released.

Story 19 later superseded that sampled-range rule with the source-derived
prefix contract documented in
[`sprint118-story19-goroutine-contract.md`](sprint118-story19-goroutine-contract.md).
The sealed v1 findings above remain historical facts. Without rerunning or
rewriting Candidate023, the current offline gate first authenticates those v1
findings and then readjudicates the retained raw streams under v2; all 291
observations pass. The v2 source rule is the full scheduler-unpromised `0..5`
`world` prefix (Candidate023's four-line observations are one legal point in
that range).
