# Sprint 118 complete official-root replay — product-all-008

The complete replay is **FAIL**. It accounted for every one of the 3,495 immutable inventory roots without a cap, shard, resumed row, duplicate or missing ID. The directory name `product-all-008` identifies the run; its runtime is frozen **candidate006**, not runtime candidate008. Later runtime improvements do not change these results.

| Axis | PASS | FAIL | Upstream skip | Total |
|---|---:|---:|---:|---:|
| Historical testdir |604|2061|61|2726|
| Typechecker |570|171|2|743|
| Test packages |0|26|0|26|
| Total |1174|2258|63|3495|

Execution took 4,196.77 seconds and exited 1. The 63 skip rows join exact native observations and original input hashes; their applicability still needs adjudication and they earn no product credit. All original program, test, subtest and callback bodies must execute in their claimed product mode.

This is complete static-root accounting, not complete execution of every upstream recipe or dynamically generated program. There are 2,157 unfinished phase references across 1,188 roots. Of 63 declared generator mode lineages, 34 were actually observed and 29 were unexecuted after earlier failures. No failed parent or missing child received successful coverage credit.

## Authentication and independent review

- Frozen sh: `194d246ebc67d122c0e0f9a028302c5df3dd48bf`.
- Runtime candidate manifest SHA-256: `b4cf7401f24a3d57110c4e4f02c62242c435846344b54af8dc915401c5e97df4`.
- Reviewed executor: `bc2e99cac20cb4db5dc0754f28be84b523de3f00`.
- Offline module manifest SHA-256: `a886a3618bcacccbb5df4030ad9e0f58442f3440a75dab3b6e62e6e0a4550dd6` (19 modules, 4,391 files).
- Source archive SHA-256: `7002403d7cc44529ef6d26f69a44818263395ead7c16c05a5808ae047ebeb0e5`.
- Final ledger SHA-256: `47d938ae72720293753cf4a4da80dfe6ec491c9421c2a182015f159c885305f2`.
- Summary SHA-256: `62834ef509a03cd43b5d45ddf86acbb4a95787713f8c4eae8ce8be4caaab9aef`.
- Context SHA-256: `f2dd853258f41301a4e2b29d0e04c701cbc370e22da3aa6b0a71f49edef76594`.

The independent manager retained-evidence gate passed in 16.345 seconds: exact inventory membership, root/context seals, native joins, 40,842 file/absence records and 13,227 unique root-linked captures. There were 13,215 exited captures and 12 deadlines, with no leaked or failed-launch captures. Producer post-run source and module integrity both passed. This integrity PASS does not change product acceptance FAIL.

Raw evidence and summary: `~/.bashy/sprint118/evidence/go-full/product-all-008/`.
Commands, audit script, detailed phase counts and native skip joins: sibling `product-all-008-control/`.
Independent gate: `~/.local/state/bashy/sprint118-evidence/go-full-008-retained-manager-gate.json`.

The completed disposable build cache was cleared only after completion and no-open-file verification; ledger, context and summary hashes were preserved. Completed native artifacts were transparently compressed at the filesystem level with per-file logical-byte, mode and SHA-256 checks. Their paths and contents remain available for audit.

All full-corpus acceptance stories remain open. Follow-up work separates runtime defects, stale candidate006 failures already fixed in later candidates, exact upstream recipe gaps and diagnostic-adapter defects; each requires a fresh independently gated result.
