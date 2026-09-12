---
id: 0ec7d328c556
kind: task
title: S152.0 leaf-152 run 0 on the Sprint 151 candidate + partition-emit retained owner rule
seq: 59
status: todo
priority: p0
created: 2026-09-12T08:50:53.618043Z
sprint: 152
---

Harness owner story (Go/Bash only). (a) partition-emit.go: skip '# <module>' build-header lines when picking the first line; add owner value 'retained' for the backend's declared interpreted 'unsupported' disposition (asmcheck) and for non-Go/.s companion inputs; regenerate the active manifests from the Barrier A events and record old-to-new movement in the commit body (D2/D3/D4 of docs/sprint-152-master-execution-plan.md). (b) leaf-152 run 0: BASHPP_CORPUS_ROOTS = active-152 + leaf-151r2/active-152 + testdir:dwarf/linedirectives.go through corpus-gate.sh on the Sprint 151 candidate (sh e484a22b / bashy 963ef4b) from a fresh /srv/sprint152 on the authorized host, GOMAXPROCS=2 GOFLAGS=-p=2, 60 s bound; publish leaf-152r0/ manifests + per-mechanism summary. Exit: four disjoint manifests + retained listed; the real 152 denominator per mechanism. No product edits under this story.
