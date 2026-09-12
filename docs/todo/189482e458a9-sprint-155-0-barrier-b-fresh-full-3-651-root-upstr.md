---
id: 189482e458a9
kind: task
title: 'Sprint 155.0: Barrier B — fresh full 3,651-root upstream-harness replay on the published integrated candidate (measurement only)'
seq: 62
status: todo
priority: p0
created: 2026-09-12T22:23:01.389283Z
sprint: 155
---

Dependency: none (D1, 2026-09-12). Candidate = the PUBLISHED umbrella pins after Sprints 151-154 and 160: bashy 548c3a4 / sh e7cd317e / coreutils 4cb658d4 / readline b958823 / filebrowser cde11469 / bashpp-tests 069edc5 + this story's pin commit (backend-pin.tsv bashpp_version + shellrt_commit). One fresh /srv/sprint155/barrier-b checkout on the authorized Linux host, one coordinator, tools/upstream-harness/corpus-gate.sh, GOMAXPROCS=2 GOFLAGS=-p=2, the 60 s backend-lane bound, upstream -t timeouts preserved, no cap/shard/resume/selection. Then partition-emit.go (v10.4 rules unchanged) regenerates the active-15N manifests for the integrated candidate; docs/upstream-harness/barrier-b.md records the run and the Barrier A -> B movement per owner; build caches removed; post-run process table clean. Exit: 3,651 terminal roots (2,726 testdir + 899 typechecker + 26 package), native lane 3,612 PASS + 39 SKIP, zero seam FAIL, manifests + summary committed. This story is MEASUREMENT ONLY: a zero-FAIL result under D3 opens 155.1-155.6; any product FAIL routes the regenerated manifests to a successor repair round and 155.1-155.6 stay todo. No product edit under this story. Harness boundary: Go or Bash only.
