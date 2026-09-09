---
id: b5d3bd1bd24c
kind: task
title: Authenticate relocated SDK and replay complete official Go obligations
seq: 17
status: todo
priority: p1
created: 2026-09-09T06:36:02.000807Z
assignee: qiangli
sprint: 118
---

Candidate018 replaces stale published-002 references. Frozen read-only root /private/tmp/s118-runtime-018; manifest /Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-018/candidate.json SHA a927efce4f80e392f78c9552e0a0f6f3465f1921d1a8fcc3ae7976e02250fdd2; launcher /private/tmp/s118-runtime-018/bashy/bin/bashy; sh 071f2409490641f3ae64ad45560164ca8f60506d; bashy 118bb3f6841a57a7010b7858bf02564c445416f7. First add exact reviewed candidate binding needed by official product validation without editing the frozen tree. Reuse authenticated relocated Go 1.27 SDK and retained native oracle. Run all 3495 roots with GOMAXPROCS=2 and GOFLAGS=-p=2; if the 30-minute cap ends first, retain a complete-attempt ledger and exact missing phase counts without claiming completion. No original-source rewrite, no native-only product credit, no push/merge/closure. Commit with Sprint: #118, Story: #17, Story-ID: b5d3bd1bd24c.
