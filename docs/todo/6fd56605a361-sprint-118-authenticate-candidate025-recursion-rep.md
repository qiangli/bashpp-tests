---
id: 6fd56605a361
kind: task
title: 'Sprint 118: authenticate Candidate025 recursion replay'
seq: 22
status: todo
priority: p0
created: 2026-09-10T00:35:59.637593Z
sprint: 118
---

Using published canonical sh 05be162749be and bashy 0740303 (which pins that sh), build and freeze Candidate025 and execute a bounded three-mode replay of exactly examples/recursion/recursion.go. Retain all three observations under a new immutable runtime-integration-025 evidence path, authenticate source/candidate/streams/root offline, keep the footprint small, and publish an exact receipt. Expected oracle, interpreted, compiled all pass; do not claim or run the other 84 rows, edit product/corpus semantics, overwrite older evidence, or weaken the production gate. Add standalone bounded validation/tamper coverage or safely generalize the Candidate024 standalone validator without allowing bounded evidence into the production gate. Required trailers Sprint #118 and this Story/Story-ID.
