---
id: fa07603b71dc
kind: task
title: 'Final verification: Go by Example corpus under examples/'
seq: 3
status: doing
priority: p1
created: 2026-09-03T09:45:35.902827Z
assignee: qiangli
sprint: 118
---

Candidate021 is the accepted stable baseline. Its authenticated 255-observation replay records oracle 85/85, compiled 85/85, and interpreted 57/85, leaving 28 interpreted failures. Evidence is retained under /Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-021; the authenticated root is c005009bb0cef9e0ab16b2560bf4aeeb55180d63ad7b64f64c32a06f89285f98. Post-candidate fixes through sh f1ed249d cover new(T), variadic range, named scalar map keys, and slices.Equal/Sort. Freeze and authenticate Candidate022, register it without mutating the frozen tree, then rerun all 85 rows and 255 observations with port 8090 exclusively owned. Retain every failure and keep this story open until all applicable interpreted rows pass.
