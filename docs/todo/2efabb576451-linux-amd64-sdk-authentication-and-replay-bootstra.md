---
id: 2efabb576451
kind: task
title: Linux amd64 SDK authentication and replay bootstrap
seq: 28
status: done
priority: p0
created: 2026-09-10T12:07:19.948487Z
assignee: sprint142-manager
sprint: 142
closed: 2026-09-10T21:15:14.195287Z
---

Add official Go 1.27 linux/amd64 toolchain identity support and make the existing SDK/native authentication path platform-correct for the DigitalOcean replay host. Verify published archive checksum, bin/go digest, module identity where applicable, fail closed on mismatches, and cover with deterministic tests. Prepare—not yet certify—the exact remote bootstrap against droplet 598793199; never touch bashy.dhnt.io. SCOPE: bashpp-tests only. No successor sprint. Commit with Sprint: #142 and this Story-ID.
