---
id: 759341a95870
kind: task
title: Execute every applicable pinned Tour example under Go and Bash++
seq: 4
status: done
priority: p1
created: 2026-09-03T09:57:58.477362Z
assignee: sprint118-manager
sprint: 118
closed: 2026-09-09T16:05:44.215242Z
---

Depends on the pinned 168-row x/website inventory delivered in fd676b7 and parser/evaluator/compiler foundations. Build a deterministic executor that copies all 93 applicable and 4 build-only official programs with BSD provenance, provisions official golang.org/x/tour helper module dependencies, runs the declared pinned Go baseline, Bash++ interpreted, and Bash++ compiled modes, and records exit/stdout/stderr with explicit normalization. The gate must fail on missing, PLANNED, unexpected N/A, or mismatched results. It may land infrastructure before language support, but cannot close until all declared rows pass.

Sprint118 execution assignment from sprint118-manager. Read /Users/qiangli/projects/poc/dhnt/docs/sprint-118-master-execution-plan.md. Work only in your isolated weave workspace. Original upstream Go bytes unchanged; no source adaptations or native-Go whole-program delegation. No subagents. Commit named files with Sprint: #118, Story and Story-ID trailers; do not push, close stories or declare sprint gates complete. Manager independently verifies/integrates. Use GOMAXPROCS=2 and Go -p 2 for focused tests; no broad heavy suites. Shared tools/corpus library is being implemented separately; do not edit it. Report missing support honestly and leave failures visible. Read canonical /Users/qiangli/projects/poc/dhnt/sh as needed. Existing product does not yet support source=go; prepare harness contract now, never forge passes.
Own tools/tour, tests/tour executor/selftests and docs/tour executor documents, but do not touch original tour corpus or inventory pins or sprint118-reconciliation.md. Fix transpile --bashpp --source=go, semantic check --check for build-only (no body execution), candidate source commit and Makefile launcher+.real digest binding instead of release-tag-only gate, three stages artifacts and fresh per-mode state. shared Corpus::Executor under tools/corpus/executor.rb will provide capture+three modes; integrate when available, report API needs early. Preserve source maps and full97 denominator. Parent story source contains old failure evidence: do not overwrite historical evidence. Add accurate new gate tests and README. Keep existing normalizer restrictions, audit no blanket masking.

Review integration2026-09-08: real shared-capture executor and corrected semantic/artifact validator merged.151semantic+100executor manager selftests and immutable corpus validation PASS. Historical diagnostic00197baseline/23interpreted/54compiled PASS are old-rule measurements only;117product mode failures remain and corrected rules require fresh ledgers with input-artifact captures. Story stays open until all97rows pass required modes.

Manager completion2026-09-09: candidate016 full execution PASS5m6.921s with97 native/97 interpreted/97 compiled PASS, all291 mode observations and77 native semantic oracle observations. The full168-row inventory has97 program PASS and71 precise fragment NOT-APPLICABLE terminals. Independent retained gate PASS765ms verifies1302 raw streams,388 artifact references and all97 full source maps (1787 unique files). Published receipt: docs/tour/sprint118-candidate016.md, raw ledger SHA1d5ba35f3d7e521781fa2655f5be532106c4151fc00b978d271b78737e953ea1. Reviewed runtime sh e2c28426/Bashy461a5cb and umbrella pins are pushed; full sh short suite PASS17m16.177s and installed Dragon original-Go smoke PASS25.961s. Original bytes and semantic comparator remain unchanged. Full-Go, GbE and overall sprint acceptance remain separate and open.
