---
id: 4c0bc8255816
kind: task
title: 'Sprint 165.7: final official-Go certification from PUBLISHED commits (Sprint 155 runbook), after Barrier D'
seq: 75
status: todo
priority: p0
created: 2026-09-13T09:06:27.657279Z
sprint: 165
---

Entered ONLY when Barrier D shows zero blocking FAIL under Sprint 155 D3 with every remaining root recorded by ID. Then the Sprint 155 certification runbook verbatim (dhnt docs/sprint-155-master-execution-plan.md §Order 3-7, docs/sprint-155-certification-handoff.md): clean clones of the PUBLISHED pins on the certification host, one corpus-gate.sh run, Tour 291/291, Go-by-Example 255/255/0, classic gate on Linux, corpus-verify.go --expect-skips, off-runner bundle verification, final ledger. No rerun to hide a failure. RULES: exact upstream Go 1.27 harness is the authority; harness/tests Go or Bash only; product fixes = general Go mechanisms in sh/{gosource,interp,lower} from outside-corpus reproducers under <seam>/testdata/sprint165/<mechanism>/ with a DRIVING TEST and the negative set; never keyed to a fixture/expected string; never permissive; never a timeout raise; never edit sh/gosource/internal/gcsyntax; keep Options.CheckAfterSyntaxErrors. Rows recorded by ID in #162 (D1–D7) are never relabeled. Verify: focused go test -count=1, then the FULL sh gate go test -short ./interp/ ./lower/ ./gosource/ ./syntax/ (lower's parity tests are the classic-isolation gate; 8 GoSource* interp tests are pre-existing darwin failures), gofmt, git diff --check; then a subset leaf — workers ship a bundle + root TSV, ONLY the manager submits (leaf-submit.sh on sprint162-leaf). Trailers Sprint: #165 / Story / Story-ID as the last paragraph.
