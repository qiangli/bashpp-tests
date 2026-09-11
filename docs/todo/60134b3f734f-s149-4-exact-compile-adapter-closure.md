---
id: 60134b3f734f
kind: task
title: S149.4 exact compile adapter closure
seq: 39
status: todo
priority: p0
created: 2026-09-10T21:22:30.805735Z
sprint: 149
---

Packet 149.4; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.4.json; SHA c0e995c192ef18baffa3419fdd7ba20e550f41170370a15d7332c3126f96fb6e; count 28. First Sprint 149 implementation story. Use the Sprint 157 upstream Go harness as the only recipe authority and send its exact selected inputs through Bash++ compile/check paths. Preserve flags, artifacts, maps, diagnostics, and compile-only behavior without executing init or main. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/compile-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/compile-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
