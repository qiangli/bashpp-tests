---
id: fa07603b71dc
kind: task
title: 'Final verification: Go by Example corpus under examples/'
seq: 3
status: assigned
priority: p1
created: 2026-09-03T09:45:35.902827Z
weave: 16
assignee: qiangli
sprint: 118
---

Pin https://github.com/mmcgrana/gobyexample.git at exact commit 7d705626375ba0263b616865a286e1587d6989c8 (master observed 2026-09-03). Derive a fail-closed inventory of every program under examples/. Preserve upstream license/provenance. For each row record deterministic applicability or a standing reasoned exception; copy applicable examples; run with the pinned Go 1.27 toolchain and Bash++; compare exit status/stdout/stderr and any declared filesystem/network behavior with normalization only where explicitly licensed. No PLANNED, silent omissions, denominator caps, or blanket N/A. Gate is final verification after parser/evaluator/compiler support lands.

Sprint118 execution assignment from sprint118-manager. Read /Users/qiangli/projects/poc/dhnt/docs/sprint-118-master-execution-plan.md. Work only in your isolated weave workspace. Original upstream Go bytes unchanged; no source adaptations or native-Go whole-program delegation. No subagents. Commit named files with Sprint: #118, Story and Story-ID trailers; do not push, close stories or declare sprint gates complete. Manager independently verifies/integrates. Use GOMAXPROCS=2 and Go -p 2 for focused tests; no broad heavy suites. Shared tools/corpus library is being implemented separately; do not edit it. Report missing support honestly and leave failures visible. Read canonical /Users/qiangli/projects/poc/dhnt/sh as needed. Existing product does not yet support source=go; prepare harness contract now, never forge passes.
Own tools/go-by-example, tests/go-by-example and docs/go-by-example; never original examples bytes. Fix obsolete --compile using transpile --bashpp --source=go plus native Go build/run, original asset relative paths and fresh per-mode states, actual _test.go execution and truthful adapters. Shared Corpus::Executor under tools/corpus/executor.rb coming. No fake_clock/seeded_random claim absent real control. Audit approved normalizers for effect checks; preserve all85 programs and provenance. Add durable fail-closed meaningful tests and report unresolved product prerequisites.

Review integration2026-09-08: original Go phase pipeline, candidate binding, test driver, perphase identity, exact effects and strict event normalization merged. Manager harness6tests24assertions + shared19tests98assertions and89/89originalinventory PASS. Last diagnostic255mode obligations executed224,31incomplete;126pass72mismatch18normalization8effects31incomplete. These old-rule measurements are not final certification; corrected harness requires regenerated anchored evidence. Story stays open.
