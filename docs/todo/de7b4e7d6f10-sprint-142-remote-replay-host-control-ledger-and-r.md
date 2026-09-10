---
id: de7b4e7d6f10
kind: task
title: Sprint 142 remote replay-host control ledger and resource preflight
seq: 27
status: todo
priority: p0
created: 2026-09-10T11:43:14.032527Z
assignee: qiangli
sprint: 142
---

Support umbrella Story #175 from the narrow bashpp-tests repo. Produce docs/go-full/SPRINT142-BOOTSTRAP.md and valid docs/go-full/sprint142-preflight.json. Independently reconcile the 3,495-root inventory (2,726 testdir + 743 typechecker + 26 legacy), current candidate provenance, retained evidence, local disk status, and existing DigitalOcean replay host 598793199 / vsc-s129-shell-20260908 (Linux amd64, 2 vCPU, 4 GiB, 80 GB). Record measured GO/NO-GO status, exact blockers, safe cleanup recommendations, and remote transfer/build/run prerequisites. Never use protected bashy.dhnt.io; do not delete evidence or modify product implementation/tests. Sprint 142 owns all closure; do not defer to Sprints 143-145.
