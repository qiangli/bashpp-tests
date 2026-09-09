---
id: 807fcefeec40
kind: task
title: 'Sprint 118: adjudicate Tour goroutine multiplicity window'
seq: 19
status: doing
priority: p0
created: 2026-09-09T22:32:55.51438Z
weave: 45
sprint: 118
---

Candidate023 retained 291/291 Tour observations but the offline gate failed two modes on _content/tour/concurrency/goroutines.go: baseline and compiled multiplicity 4 outside seven native oracle samples fixed at 5..5; interpreted passed. Analyze only retained Candidate018/021/022/023 evidence and current semantic comparator/oracle protocol. Decide and implement the smallest sound anti-flake contract that remains source-bound, requires exact hello/world membership and ordering constraints, cannot turn missing/extra arbitrary lines into PASS, and has negative-first selftests. Do not rerun Candidate023, edit product code/originals, loosen unrelated comparators, or rewrite old evidence. Document the decision and how historical ledgers validate under their original contract. Run Tour semantic/executor selftests and offline Candidate023 validation. Required trailers: Sprint: #118; Story: #19; Story-ID: 807fcefeec40.
