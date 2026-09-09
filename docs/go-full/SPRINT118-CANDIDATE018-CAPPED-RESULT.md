# Sprint 118 candidate018 official-Go capped attempt

On 2026-09-09, candidate018 ran against the immutable 3,495-root official-Go
inventory for the manager-approved 1,800-second wall-clock window. The driver
was terminated by the cap with exit status 143. This is a retained partial
attempt, not a complete corpus result and not an acceptance claim.

The run attempted 1,298 roots: 1 package root and 1,297 testdir roots. It did
not reach 2,197 roots: 25 package, 1,429 testdir, and all 743 typechecker roots.
The attempted testdir roots produced 581 PASS, 686 FAIL, and 30 UPSTREAM_SKIP
verdicts. The package root failed. There are 633 unfinished phase references
on attempted roots and 5,488 phase obligations on roots not reached by the cap,
for 6,121 missing phase references in total.

The [complete-attempt report](sprint118-candidate018-capped-attempt.json) and
[3,495-row accounting ledger](sprint118-candidate018-capped-ledger.tsv) retain
an explicit terminal state for every inventory root. The ledger SHA-256 is
`f85bee883ccb1bd0fb984ce0f9e741ae178e4ebf9f268be1d04047bfbd5240d5` and
the report SHA-256 is
`1776b75c8acffa5a1d05dfa1b1d79e176c9cb755522d8234656e3a87c50a8b19`.
The raw retained `roots.jsonl` remains outside Git at
`/Users/qiangli/.bashy/sprint118/evidence/go-full/product-all-018/roots.jsonl`,
SHA-256 `4b66857a9374c6b6600b493b7e78a723a0cec24dbc0b8750c364db44b2fc365f`.

The attempt binds candidate manifest
`a927efce4f80e392f78c9552e0a0f6f3465f1921d1a8fcc3ae7976e02250fdd2`,
frozen sh `071f2409490641f3ae64ad45560164ca8f60506d`, and Bashy
`118bb3f6841a57a7010b7858bf02564c445416f7`. Original source bytes were not
rewritten, and native-only execution received no product credit. Story 17 and
the sprint-wide acceptance story remain open.
