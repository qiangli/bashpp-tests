---
id: 65db485f62ab
kind: task
title: S150.8 execute original package test bodies
seq: 53
status: doing
priority: p0
created: 2026-09-10T21:24:10.768266Z
sprint: 150
---

Packet 150.8; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-150.8.json; SHA 92914dac49a2d6469921a85f9ff98350abb03af7a8f786d2a9204a5dc1e5eed4; count 26. Use Go's native testing metadata and execution model as the only package-test authority. Enumerate every non-zero original Go test body, execute each through Bash++ in required modes, and aggregate exact outcomes; a package build or empty probe is FAIL. Harness and harness tests must be Go or Bash only.
