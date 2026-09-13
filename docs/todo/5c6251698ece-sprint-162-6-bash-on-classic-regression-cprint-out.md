---
id: 5c6251698ece
kind: task
title: 'Sprint 162.6: Bash++-ON classic regression — cprint output diff + procsub 60 s timeout: confirm on Linux, root-cause, fix in sh'
seq: 70
status: todo
priority: p0
created: 2026-09-13T00:36:06.957358Z
assignee: qiangli
sprint: 162
---

tools/classic-gate.sh (S155.8) on the published candidate at the darwin test venue: Bash++ OFF 86/86, Bash++ ON 84 PASS + cprint FAIL (output differs from cprint.right) + procsub TIMEOUT (60.02 s). Step 1: reproduce on Linux (sprint162-leaf: make test-bash-container BASH53_OCI=podman needs podman there — install rootless podman on the leaf droplet, or run the hermetic serial gate natively per bashy/CLAUDE.md, and record which); if it does not reproduce on Linux, record that with the exact commands and the darwin-only classification. Step 2: root-cause each in sh (the Bash++ activation path must not change Classic behaviour — the isolation contract); fix from an outside-corpus reproducer; focused go test + the container gate OFF and ON both 86/86. Product edits land in sh (file a linked story there with todo add --sprint 162 and put ITS id in the sh commit trailers). RULES: Go or Bash only in every harness/test/validator (no other language added or executed); the exact upstream Go 1.27 harness is the only authority; never a permissive comparison, never behaviour keyed to a fixture path or expected string, never a timeout raise. Leaf runs use the sprint162-leaf droplet (same 2-vCPU shape as the certification host, pinned SDK at /srv/sprint142, base trees at /srv/sprint162/base; one coordinator at a time; GOMAXPROCS=2 GOFLAGS=-p=2; 60 s backend bound), NEVER the certification host (Barrier C only) and never the dev box. Kill exact pids only. Commit with trailers Sprint: #162 / Story: S162.<n> / Story-ID: <id> as the last paragraph.
