---
id: f3d6a18d5039
kind: task
title: 'Recipe-adapter closure: every testdir root reaches its declared terminal phase'
seq: 25
status: todo
priority: p0
created: 2026-09-10T09:03:08.897813Z
assignee: qiangli
sprint: 142
---

Sprint 142 recipe-execution workstream. Make every applicable testdir root execute its exact upstream recipe and every declared phase through the Bash++ product path. Build on the authenticated compile adapter. Cover compile flags/artifacts, compiledir package order/import archives/link, rundir same-product dependencies, exact source-positioned diagnostics, asmcheck/build variants, generators/nested children with parent-child hashes, and package test harness mechanics. Native forwarding and probe-only evidence never count. Begin with architecture and a bounded first causal slice that is disjoint from #24 selection code; use retained full008 only to choose a reproducer and re-rank after the fresh baseline. SCOPE: bashpp-tests only; no sh or bashy. Commit named files with Sprint: #142, Story: #25, Story-ID: f3d6a18d5039.
