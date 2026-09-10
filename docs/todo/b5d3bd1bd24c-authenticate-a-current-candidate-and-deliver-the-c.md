---
id: b5d3bd1bd24c
kind: task
title: Authenticate a current candidate and deliver the complete official-Go baseline replay
seq: 17
status: assigned
priority: p0
created: 2026-09-09T06:36:02.000807Z
weave: 60
assignee: qiangli
sprint: 142
---

Sprint 142 candidate and complete-replay parent. FIRST DELIVERY in this run is read-only launch readiness: authenticate current published sh/bashy heads against retained Candidate040 provenance; reverify relocated Go 1.27 darwin/arm64 SDK, source archive, native oracle, complete 3495 inventory, module context, runner hashes, port 8090 availability, and actual df capacity with an untouched 4 GiB reserve. Prepare a new immutable candidate manifest and exact uncapped/unsharded/unresumed launch command, but DO NOT launch product.rb until the #24 subset runner is integrated and the manager authorizes the exclusive 2.5h slot. Never edit Sprint 118 evidence. Later this story binds the initial and final complete replays. SCOPE: bashpp-tests candidate/authentication/preflight assets only; no sh implementation. Commit named files with Sprint: #142, Story: #17, Story-ID: b5d3bd1bd24c.
