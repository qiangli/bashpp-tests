---
id: b7560ec00ec1
kind: task
title: S157.1 authenticate upstream Go harness and expose execution-plan seam
seq: 54
status: done
priority: p0
created: 2026-09-11T03:23:41.282339Z
sprint: 157
closed: 2026-09-11T05:26:54.497609Z
---

Locate and freeze the exact Go 1.27 upstream test harness sources used by the native oracle. Document directive parsing, recipe planning, companion files, applicability, expected diagnostics/output, environment, and terminal semantics. Add the smallest reviewed instrumentation/API that emits authenticated execution plans without changing native behavior. Differentially prove instrumented native planning/verdicts equal the unmodified runner on the representative matrix. No alternate recipe reimplementation.
