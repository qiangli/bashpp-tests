# Sprint 118 Candidate023 Tour certificate

The one complete unfiltered Tour execution retained all 291 observations plus semantic-oracle records (306 JSONL records total) at `/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-023/tour-results.jsonl`. Its file SHA-256 is `7747f3a6694b0320df8f1db940b3f98982f16c145662739f30734631e8a856a5` and canonical root is `8fce136a1cfe6a0a453e1e34fc30a8ea42c5646abe7883e08370a4f4fba1c27c`.

The Tour validator honestly returned FAIL: its `goroutine_multiplicity` semantic oracle observed four lines outside the native 5..5 range for `_content/tour/concurrency/goroutines.go` in baseline and compiled modes. This is retained; no replay was run. Port 8090 is released.
