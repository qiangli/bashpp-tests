---
id: f3d6a18d5039
kind: task
title: 'Recipe-adapter closure: every testdir root reaches its declared terminal phase'
seq: 25
status: todo
priority: p0
created: 2026-09-10T09:03:08.897813Z
sprint: 142
---

Closure ledger for Sprint 142. bashpp-tests ONLY - no sh source file is in scope.

Split from Sprint 119 on 2026-09-10. Owns the execution MECHANICS of the testdir
axis, not product semantics.

SIGNATURE TO ERASE. full008 recorded 1188 roots carrying 2157 unfinished phase
references, and 63 declared generator mode lineages of which only 34 were
observed and 29 went unexecuted after earlier failures. First-blocker recipe
totals were 525 compile, 125 compiledir, 116 rundir, 81 asmcheck. RE-DERIVE all
of these from the Sprint 119 baseline before staffing - they are candidate006
numbers and the product is 131 sh commits newer.

REQUIRED. Single-file compile and directory package compilation need real
generated-artifact compilation and complete phase ledgers. Directory imports must
execute the source under test through the PRODUCT package graph; native
forwarding is never coverage. Generator recipes retain the unchanged generator,
hash each generated program, and record which source produced which child
obligation. Negative rows require the expected rejection category at the original
source positions - an unrelated parse error, a missing tool or a shell command
failure is not a passing rejection.

FOUNDATION. The canonical official compile adapter is corpus
c205e6f8cfd8c44124a85d4822097f612d3e7350 with final correction
0b0f47d45ab895501c1ea9c53153a8bf9e122138: real go tool compile -e -p=p
-importcfg, actual dependency archives, object validation, exact
output/environment/SDK/cache-key binding and every-use authentication. Build on
it. Unsupported flags, directory cases and original package-test bodies were
explicitly left open.

DONE WHEN every testdir root reaches its declared terminal phase under a real
recipe, so that any remaining failure is attributable to product semantics. This
sprint does NOT close testdir PASS - Sprint 144 does, and cannot start until this
one lands.
