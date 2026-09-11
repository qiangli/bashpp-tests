---
id: 5b4efc2910e6
kind: task
title: S157.4 differential migration gate and Ruby retirement decision
seq: 57
status: todo
priority: p0
created: 2026-09-11T03:23:41.296124Z
sprint: 157
---

Run the representative matrix through unmodified upstream native Go, the instrumented upstream planner/native backend, and the Bash++ backend. Compare plans, terminals, diagnostics/output, runtime, code size, maintenance surface, and measured agent/time cost. Identify exactly which Ruby components remain reusable evidence utilities and which semantic components must be deprecated or removed. Produce the go/no-go decision that alone unblocks Sprints 149/150.
