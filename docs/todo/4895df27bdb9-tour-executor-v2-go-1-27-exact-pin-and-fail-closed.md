---
id: 4895df27bdb9
kind: task
title: 'Tour executor v2: Go 1.27 exact pin and fail-closed result integrity'
seq: 5
status: done
priority: p0
created: 2026-09-03T10:27:15.319911Z
weave: 9
assignee: qiangli
sprint: 98
closed: 2026-09-03T11:06:43.509828Z
---

Supersedes rejected weave #6 while retaining its exact pinned source/license/helper inventory as reference. Require exact Go 1.27 toolchain identity and checksum; applicable/run rows must have successful Go baseline, build-only must successfully build; reject invalid UTF-8 instead of replacement; bounded process-tree and pipe cleanup; tamper tests for source hashes, byte counts, modes, result records, and baseline status. This is runner infrastructure, not Bash++ parity evidence. Commits require Sprint #98 and this Story/Story-ID trailers.
