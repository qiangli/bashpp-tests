# Sprint 118 candidate017 — complete Tour parity preserved

Dated 2026-09-09. Fresh candidate017 execution passed all **97 programs in each
of three modes: 291 PASS, zero FAIL**. The manager's full run took4m35.871s;
the independent offline semantic gate and retained artifact/source-map audit
also passed. The manager separately repeated both retained checks in457ms.

The [mode ledger](sprint118-candidate017-ledger.tsv) records all291 observations.
The [inventory ledger](sprint118-candidate017-inventory-ledger.tsv) accounts for
all168 source rows:97 program PASS terminals and71 precise existing fragment
NOT-APPLICABLE terminals. All93 runnable programs executed in three modes.
The four build-only programs completed their prescribed check/build phases
without body execution. There are no new exclusions or source adaptations.

The retained audit verified all574 declared stages,77 additional native oracle
observations for11 source-bound semantic contracts,1,302 raw stream files,
388 artifact references, and97 full source maps through the shared strict
validator. All1,787 unique retained files matched their recorded bytes and
hashes. The crawler comparator still enforces its exact graph and causal
ordering, with no arbitrary sorting. Exit status and stderr remain exact.

The [receipt](sprint118-candidate017-receipt.json) binds frozen sh
`037aaf8687e0aa049efb4f7a2dceb3a4941e9bbc`, Bashy
`fdd3fac99579b9b923c5c6389a943c986f697a80`, and Tour harness
`d728cdda6de7096c59859e06aebd2366ed55a47d`.
Candidate manifest SHA256: `bb531a83039cd10679b91a840c9196a64e3f89e449a049f22c216db498c2010e`.
Raw-ledger SHA256: `9f309052cc3c938b08f706a61e165c0bf0a2a8736f44bd844f30f71b9214f342`.
Authenticated root: `33c8721ec2dcff6804185568f8972088b68615cf76819cb0d103f9f5f3b83079`.

Original Go bodies were interpreted through GoSource; native dependency calls
grant no native original-body execution credit. Compiled artifacts ran with
empty PATH and a runtime directory without compilation inputs, as declared by
the unchanged contract. This is not an operating-system sandbox claim.
[Source reconciliation](sprint118-reconciliation.md) preserves the reviewed
website/helper pins, all original program hashes, BSD notices, and exact
fragment reasons.

Tour parity remains satisfied after the typed receive-capture correction.
This receipt makes no story mutations or new sprint-wide release claim.
The separate Go by Example017 replay remains FAIL, and the complete official-Go
corpus remains a separate open obligation. Earlier Tour ledgers remain intact.
