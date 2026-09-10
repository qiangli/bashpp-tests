---
id: 605c7c4f2cad
kind: task
title: Authenticated root-subset selection for lane-level corpus feedback
seq: 24
status: done
priority: p0
created: 2026-09-10T09:02:45.591308Z
weave: 59
assignee: qiangli
sprint: 142
closed: 2026-09-10T21:15:14.176983Z
---

Sprint 142 P0 feedback lane. DELIVER a named, hash-bound arbitrary-root subset runner for the 3495-root official-Go corpus. It must authenticate the full inventory and native joins before selection, bind exact IDs/count/inventory/runner/candidate hashes, emit subset-only scope, and be structurally unable to claim a corpus verdict or write to a full-corpus evidence root. Positive control: selected retained product-all-008 roots reproduce their exact per-root verdicts. Negative controls: forged count, duplicate/unknown/missing IDs, changed manifest, full-denominator claim, and protected output path all fail closed. Preserve existing negative=521 and typechecker=743 selections. SCOPE: bashpp-tests tools/go-full and tests/go-full only; do not touch sh or bashy. Commit named files with Sprint: #142, Story: #24, Story-ID: 605c7c4f2cad.
