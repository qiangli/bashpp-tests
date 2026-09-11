---
id: 84295fc6a058
kind: task
title: S149.8 exact errorcheckoutput adapter
seq: 43
status: todo
priority: p0
created: 2026-09-10T21:22:30.894047Z
sprint: 149
---

Packet 149.8; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.8.json; SHA 82e8651253bc39f7a5a22d05ee82c07985b532bf231ba3e0bd20dfb1455c9c15; count 4. Use the Sprint 157 upstream Go harness as the only recipe and comparison authority. Execute the selected Bash++ phase and apply its exact diagnostic/output artifact and original positions; missing or extra output fails. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/errorcheckoutput-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/errorcheckoutput-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
