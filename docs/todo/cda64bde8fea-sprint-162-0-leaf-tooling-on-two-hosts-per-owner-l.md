---
id: cda64bde8fea
kind: task
title: 'Sprint 162.0: leaf tooling on two hosts, per-owner leaf re-measure of the Barrier B manifests on the published candidate, and Barrier C at the end'
seq: 69
status: todo
priority: p0
created: 2026-09-13T00:36:06.932874Z
sprint: 162
---

Harness owner for the round. (1) Port the /srv/sprint154/{leaf-run.sh,rebuild-candidate.sh} shape into the repo as tools/upstream-harness/leaf-run.sh and rebuild-candidate.sh (Go/Bash; parameterised by base dir, so the same scripts run on the certification host and on sprint162-leaf); (2) adopt S155.11's 743 product denominator once merged (the 156 native-only typechecker leaves are never in a leaf manifest); (3) leaf re-measure run 0 per owner on the published candidate (bashy 548c3a4 / sh e7cd317e / coreutils 4cb658d4; harness at the current bashpp-tests main) from docs/upstream-harness/barrier-b/active-15{1,2,3,4}-manifest.tsv + active-unclassified.tsv + the retained compiled rows, with the verdict column, so every story is staffed on a mechanism (the 151-154 rule: leaf re-measure first); (4) keep partition-emit rules v10.4 unless a rule is proven wrong by an event — movement only by manifest commit; (5) at the end: freeze the integrated candidate (pin commit), run Barrier C from fresh /srv/sprint162/barrier-c on the CERTIFICATION host (one coordinator, ~1.5 h), run corpus-verify.go on its events, emit manifests, write barrier-c.md with the B->C movement table. Exit: leaf-162r0 committed per owner; Barrier C run and recorded. RULES: Go or Bash only in every harness/test/validator (no other language added or executed); the exact upstream Go 1.27 harness is the only authority; never a permissive comparison, never behaviour keyed to a fixture path or expected string, never a timeout raise. Leaf runs use the sprint162-leaf droplet (same 2-vCPU shape as the certification host, pinned SDK at /srv/sprint142, base trees at /srv/sprint162/base; one coordinator at a time; GOMAXPROCS=2 GOFLAGS=-p=2; 60 s backend bound), NEVER the certification host (Barrier C only) and never the dev box. Kill exact pids only. Commit with trailers Sprint: #162 / Story: S162.<n> / Story-ID: <id> as the last paragraph.
