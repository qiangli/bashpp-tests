---
id: fa07603b71dc
kind: task
title: 'Final verification: Go by Example corpus under examples/'
seq: 3
status: assigned
priority: p1
created: 2026-09-03T09:45:35.902827Z
weave: 5
assignee: qiangli
sprint: 98
---

Pin https://github.com/mmcgrana/gobyexample.git at exact commit 7d705626375ba0263b616865a286e1587d6989c8 (master observed 2026-09-03). Derive a fail-closed inventory of every program under examples/. Preserve upstream license/provenance. For each row record deterministic applicability or a standing reasoned exception; copy applicable examples; run with the pinned Go 1.27 toolchain and Bash++; compare exit status/stdout/stderr and any declared filesystem/network behavior with normalization only where explicitly licensed. No PLANNED, silent omissions, denominator caps, or blanket N/A. Gate is final verification after parser/evaluator/compiler support lands.
