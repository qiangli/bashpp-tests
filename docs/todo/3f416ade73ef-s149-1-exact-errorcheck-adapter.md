---
id: 3f416ade73ef
kind: task
title: S149.1 exact errorcheck adapter
seq: 36
status: done
priority: p0
created: 2026-09-10T21:22:30.735828Z
sprint: 149
closed: 2026-09-11T18:44:26.045648Z
---

Packet 149.1; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.1.json; SHA b97ec6e5e167cddd4553fe2f4795039a46f35779bd41a8e030fb4ccaf0ce4f81; count 144. Use the Sprint 157 upstream Go harness as the only recipe and diagnostic authority. Execute the exact upstream-selected Bash++ check/compile phase and positioned diagnostic comparison for every ID; no probe or native tested-source execution earns PASS. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

CLOSES WITH: docs/upstream-harness/errorcheck-matrix.tsv (root-list digest = manifest) + tools/upstream-harness/errorcheck-gate.sh on the build-gate.sh shape, both modes; exit 0 green; exit 3 honest with every non-green root ledgered as product in docs/upstream-harness/residuals.tsv; exit 1 seam defect keeps the story open. Seam files (testdata/backend, testdata/instrumented, backend-verify*.go, backend-pin.tsv, backend.md) are edited only by the seam owner sprint149-manager. Plan: docs/sprint-149-master-execution-plan.md.
