---
id: 605c7c4f2cad
kind: task
title: Authenticated root-subset selection for lane-level corpus feedback
seq: 24
status: todo
priority: p0
created: 2026-09-10T09:02:45.591308Z
sprint: 142
---

Enabler filed in Sprint 119 so Sprints 142-145 inherit a working feedback loop.

THE PROBLEM. product.rb offers only two shards today - negative (521 testdir
diagnostic roots) and typechecker (743) - and no way to run an arbitrary subset.
So a worker fixing one defect class can only measure it by waiting for the full
3495-root replay, which is about 90 minutes and holds port 8090. That is what
forced Sprint 118 into 35 one-row frozen candidates, which is what filled the
disk and produced the Story #17 storage NO-GO.

DELIVER. A named, hash-bound root subset that runs in minutes against a shared
candidate, with no freeze and no new evidence directory. Extend the existing
phase_roots contract, which already fails closed on denominator drift: a subset
carries its own expected count and identity set and MUST be structurally
incapable of emitting a corpus-level verdict.

GATE. Negative control required: a subset run that attempts to claim a
full-corpus denominator, or to write into a corpus evidence root, fails closed.
Positive control: a subset of known roots reproduces the same per-root verdicts
the last full replay recorded for exactly those roots.

Own tools/go-full only. Do not touch sh.
