---
id: a49d5becc121
kind: task
title: 'Sprint 165.6: classic gate OFF/ON 86/86 on every candidate (regression guard)'
seq: 74
status: todo
priority: p1
created: 2026-09-13T09:06:27.632152Z
sprint: 165
---

Regression guard, not a repair: the hermetic container classic gate (bashy make test-bash-container and -bashpp, podman machine on the darwin test host) on every integrated candidate before it is leafed; both must stay 86/86 (Sprint 162 fixed procsub/histexpand: the shell-opened process-substitution FIFO — sh interp/sprint162_classic_test.go is the isolation contract). Record each run's identity (sh/bashy/coreutils shas) with the counts. RULES: exact upstream Go 1.27 harness is the authority; harness/tests Go or Bash only; product fixes = general Go mechanisms in sh/{gosource,interp,lower} from outside-corpus reproducers under <seam>/testdata/sprint165/<mechanism>/ with a DRIVING TEST and the negative set; never keyed to a fixture/expected string; never permissive; never a timeout raise; never edit sh/gosource/internal/gcsyntax; keep Options.CheckAfterSyntaxErrors. Rows recorded by ID in #162 (D1–D7) are never relabeled. Verify: focused go test -count=1, then the FULL sh gate go test -short ./interp/ ./lower/ ./gosource/ ./syntax/ (lower's parity tests are the classic-isolation gate; 8 GoSource* interp tests are pre-existing darwin failures), gofmt, git diff --check; then a subset leaf — workers ship a bundle + root TSV, ONLY the manager submits (leaf-submit.sh on sprint162-leaf). Trailers Sprint: #165 / Story / Story-ID as the last paragraph.
