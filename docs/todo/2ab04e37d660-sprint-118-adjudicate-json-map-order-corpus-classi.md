---
id: 2ab04e37d660
kind: task
title: 'Sprint 118: adjudicate JSON map-order corpus classification'
seq: 18
status: todo
priority: p0
created: 2026-09-09T21:54:51.686589Z
weave: 42
assignee: qiangli
sprint: 118
---

Candidate022 proved examples/json/json.go is misclassified deterministic/none/none: encoding/json/v2 map emission is nondeterministic in the pinned oracle and compiled artifact. Deliberately decide whether to classify behavior map_iteration with licensed map_order normalization. Preserve historical Candidate021/022 evidence as historical; do not rewrite old roots. Add focused negative/positive schema and normalizer tests, document exact classification_sha256/corpus_sha256 rebaseline impact, regenerate reviewed inventory artifacts through repository tools, and independently validate. This is corpus governance only: do not edit product code, tamper tests, candidate evidence, or run the 255-observation gate. Required trailers: Sprint: #118; Story: #18; Story-ID: 2ab04e37d660.
