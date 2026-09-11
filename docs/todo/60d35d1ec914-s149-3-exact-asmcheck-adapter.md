---
id: 60d35d1ec914
kind: task
title: S149.3 exact asmcheck adapter
seq: 38
status: todo
priority: p0
created: 2026-09-10T21:22:30.779758Z
sprint: 149
---

Packet 149.3; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.3.json; SHA 5c3fc60143b9fd87b88f9c21d546fe8eceeba803009580f01317d8c3a0add4a4; count 84. Use the Sprint 157 upstream Go harness as the only recipe and assembly-comparison authority. Compile Bash++-generated Go for the exact selected architecture and apply upstream expectations; invocation alone is not PASS. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/asmcheck-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/asmcheck-gate.sh on the build-gate.sh shape, compiled mode only (assembly is a compiler artifact; interpreted records unsupported); exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
