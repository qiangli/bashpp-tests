---
id: 1e87cb008ec3
kind: task
title: S149.2 exact compiledir adapter
seq: 37
status: done
priority: p0
created: 2026-09-10T21:22:30.757873Z
sprint: 149
closed: 2026-09-11T18:44:26.069711Z
---

Packet 149.2; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.2.json; SHA af691353b9a1e1e229b1b419f44adbae2f05ff91c2ce5a05708385b1c4019d9f; count 125. Use the Sprint 157 upstream Go harness as the only recipe authority. Consume its selected package groups, order, import configuration, inputs, and terminal comparison; run tested sources only through Bash++. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/compiledir-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/compiledir-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
