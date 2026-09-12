---
id: 4877afd3a207
kind: task
title: S154.0 harness — partition v10 (verdict column; D1 optimizer rows retained; D2 typechecker rows → 154; runtime rows → 153), leaf-154 runs, manifests
seq: 61
status: done
priority: p0
created: 2026-09-12T20:04:42.30181Z
sprint: 154
closed: 2026-09-12T21:54:12.745905Z
---

Plan: dhnt docs/sprint-154-master-execution-plan.md (D1–D3 approved 2026-09-12). Part 1: partition-emit.go gains a verdict column read from the upstream errorCheck output in the logs — the missing error "<regex>" / unmatched error: <line> pairs per root, so each row is one of missing · extra · wording · position · multiplicity; partition-emit_test.go with one fixture per class; re-emit from unchanged Barrier A events. Part 2 (rules keyed on recipe flags + verdict shape from the events, never on expected strings): (a) interpreted row of an errorcheck* recipe whose flags carry -m, -live, -d=, or -race → declared unsupported in the interpreted check-diagnostics branch (optimizer diagnostics are a compiler artifact) → retained; compiled row with -d= → retained; compiled -m/-live/-race rows stay 154. (b) run/errorcheckoutput runtime rows → 153. (c) typechecker 'no error expected' whose extra message is a tab continuation or undefined: assert|trace → 154. (d) unclassified wording rows → 154 by verdict. Movement in the commit body. Then leaf-154 run 0 (162-root union ∪ 52 unclassified ∪ 103 typechecker roots) on the current pin from fresh /srv/sprint154, and run 1 at close.
