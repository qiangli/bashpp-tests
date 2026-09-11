---
id: 4716cabd8357
kind: task
title: S149.9 exact errorcheckwithauto adapter
seq: 44
status: done
priority: p0
created: 2026-09-10T21:22:30.91603Z
sprint: 149
closed: 2026-09-11T18:44:26.177272Z
---

Packet 149.9; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.9.json; SHA b2fc08c2e4db1b622ec31693aa02c8a63ce95b4c0110f133872db6fc80dfcfc2; count 3. Use the Sprint 157 upstream Go harness as the only recipe and diagnostic authority. Execute the selected Bash++ phase and include the upstream-required automatic diagnostics without relaxing multiplicity or positions. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/errorcheckwithauto-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/errorcheckwithauto-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
