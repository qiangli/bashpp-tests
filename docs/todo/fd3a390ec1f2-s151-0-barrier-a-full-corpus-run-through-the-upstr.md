---
id: fd3a390ec1f2
kind: task
title: S151.0 Barrier A — full-corpus run through the upstream Go harness, active 151–154 manifests
seq: 58
status: assigned
priority: p0
created: 2026-09-11T23:15:16.554779Z
assignee: sprint151-manager
sprint: 151
---

Entry gate for Sprint 151 (docs/sprint-151-handoff.md §Entry gate; docs/sprint-151-master-execution-plan.md step 1). Authority: the exact upstream Go 1.27 harness (cmd/internal/testdir, go/types + types2 check_test, patched cmd/go) through the accepted 149/150 backend seam. Go or Bash only.

Deliverables (bashpp-tests):
1. tools/upstream-harness/corpus-gate.sh — the packet-gate shape with the per-packet selector dropped: three runners, both modes, the count 3,495 (2,726 testdir + 743 typechecker + 26 packages) as the authentication, same pin checks, same observer, exit 0 green / 3 product rows / 1 seam defect.
2. A small Go emitter that reads the observer events and writes the active Sprint 151–154 manifests (docs/upstream-harness/active-15N-manifest.tsv, root-list digest each) by the first-line rules that produced residuals.tsv; disjoint, complete over every non-PASS root; old-to-new root movement table.
3. One Linux run from a fresh /srv/sprint151/barrier-a on the authorized host: GOMAXPROCS=2, GOFLAGS=-p=2, 60 s phase bound, logs outside /tmp, clean process table after. Zero seam FAIL; a seam FAIL fails the barrier (fix the seam, restart from authentication).
4. backend.md §Sprint 151 (the corpus gate), README index, pins.

Not: any product fix, any fixture path, skip conversion, timeout increase, or relabel. Closes on the Linux run record + published manifests.
