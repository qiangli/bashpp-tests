---
id: 8ae8f1041a8f
kind: task
title: S149.10 typechecker option applicability execution
seq: 45
status: done
priority: p0
created: 2026-09-10T21:22:30.940287Z
sprint: 149
closed: 2026-09-11T18:44:26.198357Z
---

Packet 149.10; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.10.json; SHA 62500870440412ee29632af50526174f3655e913f6e0defe37b8705da3cc607a; count 20. Use Go's build-constraint/type-checking behavior and the Sprint 157 direct Go-source boundary as authority. Execute each original fixture through Bash++ with the exact selected options and diagnostics; a probe remains nonterminal. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/typechecker-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/typechecker-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
