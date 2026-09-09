# Sprint 118 candidate018 manager replay — one gain, corpus still FAIL

On 2026-09-09 the sprint manager reran the complete Go by Example gate at an
isolated evidence path after rejecting an agent run that overwrote its retained
ledger. The replacement run completed all **85 rows / 255 observations** in
276.287 seconds with no missing or unspawned attempts. The overall verdict is
**FAIL**.

| Mode | PASS | Mismatch | Normalization failure |
| --- | ---: | ---: | ---: |
| Native Go | 85 | 0 | 0 |
| Bash++ interpreted | 53 | 28 | 4 |
| Bash++ compiled | 85 | 0 | 0 |

The [255-row public ledger](sprint118-candidate018-manager-ledger.tsv) and
[receipt](sprint118-candidate018-manager-receipt.json) bind the complete run.
After its root was added to the reviewed evidence-root table, the unchanged
validator authenticated the retained FAIL evidence with denominator 255,
executed 255, and missing 0.

Compared with candidate017, interpreted
`examples/reading-files/reading-files.go` gained PASS. No prior PASS regressed,
leaving 32 interpreted failures: 28 mismatches and four normalization failures.
Native and compiled modes pass all 85 rows. The result therefore narrows the
current runtime backlog but does not meet Story 3 acceptance.

The run used frozen sh `071f2409490641f3ae64ad45560164ca8f60506d`, Bashy
`118bb3f6841a57a7010b7858bf02564c445416f7`, candidate manifest
`a927efce4f80e392f78c9552e0a0f6f3465f1921d1a8fcc3ae7976e02250fdd2`,
and harness revision `689ed71`. The retained raw ledger SHA-256 is
`7a343becdefd79a24a7806a667c750a7a3ea6dad3fd822346e1ecdb1944b938d`;
its authenticated root is
`77cece26e03c82ff256571e44a713c52adc29e45847bea4e19b6ba1b1195a119`.
Original source bytes and frozen candidate files were unchanged.
