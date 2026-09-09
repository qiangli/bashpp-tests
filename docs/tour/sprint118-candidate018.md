# Sprint 118 candidate018 — complete Tour regression, one preserved semantic failure

Dated 2026-09-09. A fresh candidate018 execution recorded all **97 programs in
each of three modes: 288 PASS and 3 preserved FAIL observations**, verdict
FAIL. The full run took5m18.901s under a concurrently loaded host. The
independent offline semantic gate reproduced exactly those three findings plus
the FAIL verdict (223ms) and nothing else; the retained artifact/source-map
audit passed with zero integrity findings (739ms; both retained checks962ms).

The single failing program is `_content/tour/concurrency/goroutines.go`. The
reviewed `say_interleaving` comparator adjudicates it against repeated
executions of the very native binary the baseline stage just built: all 7
native oracle repeats in this run measured goroutine multiplicity 4
(`hello=5, world=4`, oracle_distinct_stdout=1), while every authoritative mode
draw — **including the native Go baseline itself** — printed `hello=5,
world=5` (multiplicity 5), outside the measured native range4..4. The three
FAIL rows carry the exact status
`FAIL:semantic:goroutine_multiplicity:5_outside_native_range_4..4`. They are
semantic-adjudication outcomes, not integrity failures, and the identical
native baseline failure carries no Bash++-specific regression signal. Per the
retention contract the failures are preserved verbatim: no rerun, no retuned
comparator, no widened range, no exclusion, and no source or candidate edit.

The [mode ledger](sprint118-candidate018-ledger.tsv) records all291
observations; versus candidate017 only the three goroutines.go rows changed.
The [inventory ledger](sprint118-candidate018-inventory-ledger.tsv) accounts
for all168 source rows:96 program PASS terminals,1 preserved FAIL terminal,
and71 precise existing fragment NOT-APPLICABLE terminals. All93 runnable
programs executed in three modes. The four build-only programs completed their
prescribed check/build phases without body execution. There are no new
exclusions or source adaptations.

The retained audit verified all574 declared stages,77 additional native oracle
observations for11 source-bound semantic contracts,1,302 raw stream files,
388 artifact references, and97 full source maps through the shared strict
source-map validator. All1,787 unique retained files matched their recorded
bytes and hashes; the candidate was reauthenticated after execution and all
original sources were reverified unchanged on the way out. The crawler
comparator still enforces its exact graph and causal ordering; exit status and
stderr remain exact.

The [receipt](sprint118-candidate018-receipt.json) binds frozen sh
`071f2409490641f3ae64ad45560164ca8f60506d`, Bashy
`118bb3f6841a57a7010b7858bf02564c445416f7`, and Tour harness
`d728cdda6de7096c59859e06aebd2366ed55a47d`.
Candidate manifest SHA256: `a927efce4f80e392f78c9552e0a0f6f3465f1921d1a8fcc3ae7976e02250fdd2`.
Raw-ledger SHA256: `c639ef4a27c35bdf771862f8a7c88a321fe64d012fb321f3200c68733a47cddb`.
Authenticated root: `b0f6e0c0585b5d077d182111e402bab60dc65d1b75bce2ddf1400b681be6bf33`.

Original Go bodies were interpreted through GoSource; native dependency calls
grant no native original-body execution credit. Compiled artifacts ran with
empty PATH and a runtime directory without compilation inputs, as declared by
the unchanged contract. This is not an operating-system sandbox claim.
[Source reconciliation](sprint118-reconciliation.md) preserves the reviewed
website/helper pins, all original program hashes, BSD notices, and exact
fragment reasons.

Story4 (`759341a95870`) does not meet its complete Tour acceptance criteria on
candidate018: the three failing observations remain open and preserved. No
story status was mutated and no new sprint-wide release is claimed. The Go by
Example018 replay and the complete official-Go corpus remain separate open
obligations. Earlier Tour ledgers (candidate013 through candidate017) remain
intact.
