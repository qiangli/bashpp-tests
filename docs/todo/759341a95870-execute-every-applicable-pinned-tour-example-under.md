---
id: 759341a95870
kind: task
title: Execute every applicable pinned Tour example under Go and Bash++
seq: 4
status: assigned
priority: p1
created: 2026-09-03T09:57:58.477362Z
weave: 6
assignee: qiangli
sprint: 98
---

Depends on the pinned 168-row x/website inventory delivered in fd676b7 and parser/evaluator/compiler foundations. Build a deterministic executor that copies all 93 applicable and 4 build-only official programs with BSD provenance, provisions official golang.org/x/tour helper module dependencies, runs the declared pinned Go baseline, Bash++ interpreted, and Bash++ compiled modes, and records exit/stdout/stderr with explicit normalization. The gate must fail on missing, PLANNED, unexpected N/A, or mismatched results. It may land infrastructure before language support, but cannot close until all declared rows pass.
