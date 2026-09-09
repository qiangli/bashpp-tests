# Sprint118 candidate013 — complete Tour replay

All97 original programs ran in each ofthree modes:291 observations plus77 native
semantic oracle observations. Native97PASS, interpreter94PASS/3FAIL, compiled97PASS.
All original source hashes and the frozen candidate reauthentication passed.
The offline manager gate independently reconstructed only the3 actual runtime
failures and the aggregate FAIL verdict; it reported no integrity findings.

Remaining interpreted failures: concurrency/mutex-counter.go (original method
launch resolution), solutions/binarytrees_quit.go (deferred close dispatch),
and solutions/webcrawler.go (structured pointer/map expression). Corrections are
reviewed separately against a later candidate; no observation here was upgraded.

Candidate sh8a3e3eef / Bashy8652407. Manifest SHA256:
4452dbe4c2c61bfe804259232d93fc37303c1204e97f7576e2a50c4b05bb1118.
Root:242ad9dda38017d32c1e82ed704898d9ed3aff852074588d3b06a59a8ae88fc4.
Ledger:`sprint118-candidate013-ledger.tsv`.
Raw:`~/.local/state/bashy/sprint118-evidence/runtime-integration-013/tour/results.jsonl`.

Compared with the reviewed candidate010 channel-contract replay:11 additional
interpreter passes. All97 native and97 compiled passes remain. Story4 stays open.
Original bytes were not rewritten and original program bodies were interpreted.
