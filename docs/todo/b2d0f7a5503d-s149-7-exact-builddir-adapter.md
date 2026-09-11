---
id: b2d0f7a5503d
kind: task
title: S149.7 exact builddir adapter
seq: 42
status: done
priority: p0
created: 2026-09-10T21:22:30.871924Z
sprint: 149
closed: 2026-09-11T18:44:26.134202Z
---

Packet 149.7; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.7.json; SHA 87d03b0c95b1c3319f1ab595738a750e3739d2ef69c2b49932f5b41ffb92afe3; count 2. Use the Sprint 157 upstream Go harness as the only recipe authority. Honor its selected members, order, import configuration, and artifacts through Bash++ without execution or native tested-source substitution. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/builddir-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/builddir-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
