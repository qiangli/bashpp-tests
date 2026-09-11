---
id: f3d6a18d5039
kind: task
title: 'Recipe-adapter closure: every testdir root reaches its declared terminal phase'
seq: 25
status: todo
priority: p1
created: 2026-09-10T09:03:08.897813Z
assignee: qiangli
sprint: 150
---

Sprint 150 integration ledger for exact recipe execution. Sprint 157 supplies the upstream Go harness and Sprint 149 supplies accepted static backend phases; Sprint 150 owns the remaining dynamic/package phases and the integrated 653-root proof. Exit only when every root executes its upstream-owned product contract with no harness first cause, then freeze the integrated candidate and regenerate active manifests for Sprints 151–154. All harness code and harness tests must be Go or Bash only.
