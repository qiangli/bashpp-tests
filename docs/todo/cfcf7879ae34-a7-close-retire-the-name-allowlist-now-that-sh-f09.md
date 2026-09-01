---
id: cfcf7879ae34
kind: task
title: 'A7 close: retire the NAME[...] allowlist now that sh f091034a landed'
seq: 1
status: done
priority: p1
created: 2026-09-01T03:38:31.130401Z
assignee: lintel
sprint: 97
closed: 2026-09-01T03:40:48.216043Z
---

A7's final item. sh f091034a fixed the command-position NAME[...] defect, --posix-gate detected it and FAILED with five STALE lines demanding the rows be removed, and they are now removed. Corpus is 188 shapes with 0 engine disagreements; the gate passes with an EMPTY allowlist. Acceptance: gate green, allowlist empty, class ratchet clean, suite exit 0.
