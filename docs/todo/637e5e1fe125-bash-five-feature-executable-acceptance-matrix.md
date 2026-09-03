---
id: 637e5e1fe125
kind: task
title: Bash# five-feature executable acceptance matrix
seq: 6
status: todo
priority: p0
created: 2026-09-03T17:59:19.310797Z
assignee: qiangli
sprint: 113
---

Before Bash# implementation can close, add fail-closed tests for all five accepted features: keyword arguments, default parameters, deep readonly, exhaustive enums, and null-safety checking. For syntax features cover positive/near-miss/forced-shell/flag-off/unsupported-form under normal and POSIX; AST Walk Printer typedjson; type/diagnostic negatives; interaction with ordinary Go calls/types; exact lowering to ordinary Go; interpreted-vs-compiled parity. Deep readonly must test nested maps/slices/structs, aliases/subshells/imported values and mutation paths. Enums must test duplicate/invalid members and exhaustive/default/nested switch. Null safety must test flow narrowing, reassignment, dereference/index/call boundaries, false positives and check exit status. Wire corpus and tamper/denominator validation; no skips or PLANNED rows.
