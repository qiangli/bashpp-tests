---
id: 2ab04e37d660
kind: task
title: 'Sprint 118: adjudicate JSON map-order corpus classification'
seq: 18
status: done
priority: p0
created: 2026-09-09T21:54:51.686589Z
weave: 43
assignee: qiangli
sprint: 118
closed: 2026-09-09T22:35:03.420868Z
---

Candidate022 proved examples/json/json.go is misclassified deterministic/none/none: encoding/json/v2 map emission is nondeterministic in the pinned oracle and compiled artifact. Deliberately decide whether to classify behavior map_iteration with licensed map_order normalization. Preserve historical Candidate021/022 evidence as historical; do not rewrite old roots. Add focused negative/positive schema and normalizer tests, document exact classification_sha256/corpus_sha256 rebaseline impact, regenerate reviewed inventory artifacts through repository tools, and independently validate. This is corpus governance only: do not edit product code, tamper tests, candidate evidence, or run the 255-observation gate. Required trailers: Sprint: #118; Story: #18; Story-ID: 2ab04e37d660.

Run 42 produced reviewed commit 657928b447e7c5e01e63142e9788d484ab796ff9, but its wrapper verify was misconfigured without the legacy tamper script's required candidate environment. Manager independently passed the focused 4-test/10-assertion JSON suite, offline 89/89 integrity gate, and 39-case inventory tamper suite. Replacement run 43 imports that exact seven-file commit under a valid verify command.
