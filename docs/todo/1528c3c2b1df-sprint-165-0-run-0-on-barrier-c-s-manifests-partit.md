---
id: 1528c3c2b1df
kind: task
title: 'Sprint 165.0: run 0 on Barrier C''s manifests, partition v10.6 if proven, Barrier D at the end'
seq: 73
status: todo
priority: p0
created: 2026-09-13T09:06:27.607173Z
sprint: 165
---

Harness owner. (1) Run 0: re-measure Barrier C's owner manifests (docs/upstream-harness/barrier-c/) on the frozen candidate integ-3 per owner with verdicts, on sprint162-leaf via leaf-submit.sh; (2) partition v10.6 only if an event proves a rule wrong (nul1's class=position is a misread: errorCheck normalises the working-copy path; classify by verdict); (3) keep the leaf/barrier tooling (leaf-run.sh, rebuild-candidate.sh, leaf-submit.sh, barrier-run.sh) as the only way work reaches a host; (4) at the end: freeze, rebuild-candidate integ-N on the certification host, barrier-run.sh barrier-d, corpus-verify.go, manifests, barrier-d.md with the C→D movement table. RULES: exact upstream Go 1.27 harness is the authority; harness/tests Go or Bash only; product fixes = general Go mechanisms in sh/{gosource,interp,lower} from outside-corpus reproducers under <seam>/testdata/sprint165/<mechanism>/ with a DRIVING TEST and the negative set; never keyed to a fixture/expected string; never permissive; never a timeout raise; never edit sh/gosource/internal/gcsyntax; keep Options.CheckAfterSyntaxErrors. Rows recorded by ID in #162 (D1–D7) are never relabeled. Verify: focused go test -count=1, then the FULL sh gate go test -short ./interp/ ./lower/ ./gosource/ ./syntax/ (lower's parity tests are the classic-isolation gate; 8 GoSource* interp tests are pre-existing darwin failures), gofmt, git diff --check; then a subset leaf — workers ship a bundle + root TSV, ONLY the manager submits (leaf-submit.sh on sprint162-leaf). Trailers Sprint: #165 / Story / Story-ID as the last paragraph.
