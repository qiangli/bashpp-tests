---
id: 72ac9344b150
kind: task
title: 'Sprint 118: authenticate Candidate026 generics replay'
seq: 23
status: todo
priority: p0
created: 2026-09-10T01:09:49.600186Z
sprint: 118
---

Using published canonical sh fd69aa85 and bashy 40af166 (which pins that sh), build/freeze Candidate026 and execute a bounded three-mode replay of exactly examples/generics/generics.go. Retain/authenticate all three observations under a new immutable runtime-integration-026 path and publish exact append-safe evidence. Expected oracle/interpreted/compiled all pass; report facts if not. Preserve prior candidates/evidence, do not run other 84 rows or claim full parity, and keep the production gate byte-identical. Extend only the standalone bounded validator/selftests using historical candidate-table prefix authentication. Required trailers Sprint #118 and this Story/Story-ID.
