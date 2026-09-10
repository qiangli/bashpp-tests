---
id: 405d0d96bb28
kind: task
title: 'Sprint 118: authenticate Candidate024 generic-receiver replay'
seq: 20
status: done
priority: p0
created: 2026-09-09T23:54:19.235163Z
weave: 47
assignee: qiangli
sprint: 118
closed: 2026-09-10T00:35:34.933246Z
---

Using canonical sh e3615678760246e61ffd079300204f18bccd1e2a and bashy 4e5db5d1a6aa43539626f25e1fce0c3ba99ec723, build/freeze a new authenticated candidate and execute a bounded three-mode replay of exactly examples/generics/generics.go and examples/range-over-iterators/range-over-iterators.go. Retain raw evidence under a new Candidate024 path, validate candidate and evidence offline, and publish a precise diagnostic receipt. Do not overwrite Candidate023, edit product/corpus semantics, claim full Go-by-Example parity, or run the other 83 rows. Keep retained artifacts small. Required trailers: Sprint #118 and this Story/Story-ID.
