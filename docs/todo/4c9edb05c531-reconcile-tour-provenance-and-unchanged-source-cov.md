---
id: 4c9edb05c531
kind: task
title: Reconcile Tour provenance and unchanged-source coverage
seq: 14
status: done
priority: p1
created: 2026-09-09T03:33:39.776216Z
assignee: qiangli
sprint: 118
closed: 2026-09-09T04:30:34.411358Z
---

Audit existing 168 inventory rows, 97 original programs and pin history. Preserve source bytes, prove pinned upstream provenance, document story reconciliation and exact 71 fragment reasons. Own docs/tour/sprint118-reconciliation.md and supporting new audit file only; no tools/tour executor edits. Parents 2daf9ef04ad4 and 759341a95870.


Manager acceptance (Sprint 118): authenticated all 3,283 entries of the pinned website module ZIP against h1:sKWEVclFcb47eMWJscLT/RC45vMFwwzgvPlhWHGFXSE=; re-extraction reproduced all 168 inventory rows byte-for-byte and all 97 vendored programs matched exactly. Fragment audit retains 62 inline blocks and 9 explicit nobuild programs. Independent gate tour-provenance-manager-gate.json PASS; durable record docs/tour/sprint118-provenance.json. Parent corpus execution stories remain open; this closes provenance review only. Draft factual overclaims were rejected and replaced by the manager-verified report.
