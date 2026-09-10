---
id: b5d3bd1bd24c
kind: task
title: Authenticate relocated SDK and replay complete official Go obligations
seq: 17
status: todo
priority: p1
created: 2026-09-09T06:36:02.000807Z
assignee: qiangli
sprint: 119
---

Moved from Sprint 118 Story #17 by user direction on 2026-09-09. Sprint 118 completed/continues the Tour and Go-by-Example lanes; the official full-Go replay is intentionally deferred to Sprint 119. Reuse the retained Sprint 118 authenticity baseline: Candidate018 replaces stale published-002 references; frozen read-only root /private/tmp/s118-runtime-018; manifest /Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-018/candidate.json SHA a927efce4f80e392f78c9552e0a0f6f3465f1921d1a8fcc3ae7976e02250fdd2; launcher /private/tmp/s118-runtime-018/bashy/bin/bashy; sh 071f2409490641f3ae64ad45560164ca8f60506d; bashy 118bb3f6841a57a7010b7858bf02564c445416f7. First authenticate a current candidate binding without editing frozen evidence, then run all 3495 official-Go roots with GOMAXPROCS=2 and GOFLAGS=-p=2. Retain complete-attempt evidence and exact missing/phase counts; do not claim completion from a capped or partial run. No original-source rewrite or native-only product credit. Delivery commits: Sprint: #119; Story: #17; Story-ID: b5d3bd1bd24c. Cross-reference: Sprint #118 upstream-go deferral and docs/sprint-118-handoff.md.
