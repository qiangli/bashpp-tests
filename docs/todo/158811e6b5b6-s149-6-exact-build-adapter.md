---
id: 158811e6b5b6
kind: task
title: S149.6 exact build adapter
seq: 41
status: done
priority: p0
created: 2026-09-10T21:22:30.850662Z
weave: 120
assignee: claude-fable5
sprint: 149
---

Packet 149.6; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-149.6.json; SHA bbddc30d7b8a9edfd6f21c117347fcb55c011a232f0c0539ff72a5bf8417c0cf; count 4. Use the Sprint 157 upstream Go harness as the only recipe authority. Apply its selected flags, environment, build constraints, and artifact contract through Bash++ without executing the body. Extend only the shared Go backend/event seam. Harness and harness tests must be Go or Bash only.

Closed with the exact build-only seam verified in both modes. Three roots pass;
`abi/bad_select_crash.go` remains an honestly non-green Bash++ product failure
(`unsupported type *ast.BasicLit`) in both modes, not an adapter failure.
