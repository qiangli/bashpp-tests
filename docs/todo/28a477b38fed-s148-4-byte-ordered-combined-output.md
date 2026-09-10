---
id: 28a477b38fed
kind: task
title: S148.4 byte-ordered combined output
seq: 32
status: todo
priority: p0
created: 2026-09-10T21:21:58.835444Z
sprint: 148
---

Packet 148.4; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-148.4.json; SHA 2a5f736d560267caa155a942e2c8d326d6bb77b23a8f40b40980af5f3c99f841; count 1; ID testdir:fixedbugs/issue21808.go. Record ordering at child write/kernel shared-sink boundary, never reconstruct from two pipes. Depends 148.1-148.3. Own this exact root and ordered-output contract; localize first. The shared spawn/orchestration seam is reserved to the Substrate Integration Owner, who integrates the change. Repeated Linux baseline/interpreted/compiled bytes equal A\\n\\nB\\n and two-pipe reconstruction rejects. No corpus credit beyond exact selected root.
