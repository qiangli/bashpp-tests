---
id: e87e1cbcbb20
kind: task
title: S150.5 exact buildrun adapter
seq: 50
status: doing
priority: p0
created: 2026-09-10T21:24:10.668795Z
sprint: 150
---

Packet 150.5; manifest /srv/sprint142/evidence/product-baseline-001-control/packet-manifests-v4/packet-150.5.json; SHA 0890ae57a2a00591169cab3c5a0d823761621f4f46582a8da7d84fd79a061d2b; count 1. Use the upstream Go harness as the only recipe authority. Preserve its build/run boundary, build the Bash++ artifact from exact selected sources, and execute only that artifact with the selected arguments. Harness and harness tests must be Go or Bash only.
