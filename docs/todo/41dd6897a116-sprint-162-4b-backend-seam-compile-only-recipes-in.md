---
id: 41dd6897a116
kind: task
title: 'Sprint 162.4b: backend seam — compile-only recipes invoked as upstream invokes them (no implied -complete); generate/execute-phase dispositions'
seq: 72
status: assigned
priority: p0
created: 2026-09-13T02:07:06.707183Z
weave: 141
assignee: qiangli
sprint: 162
---

Harness half of S162.4 (sh #94 d408f15b7cb4), the backend seam in tools/upstream-harness/testdata/backend/bashpp_backend_test.go: (a) compile-only upstream recipes (compile / errorcheck / compiledir and the compile phases of the -dir forms) invoke the pinned toolchain the way upstream's compile action does — gc directly with the recipe's flags and an importcfg, not a cmd/go build that implies -complete — so a body-less function declaration is compiled exactly as the authority compiles it (D3(a) of the Sprint 162 master execution plan); recorded as a seam event with the exact argv, never a permissive path, never a timeout raise; (b) the generate-phase 'compile input is not a Go source file' (6 roots) and execute-phase 'module package has non-Go inputs' (3 .s roots + 1 gotest) dispositions: implement what the authority does where the product can satisfy it, else leave the row FAIL with the honest first line (never retained). Verify: go test -count=1 ./tools/upstream-harness/... (Go/Bash only), then a subset leaf of the 41 body-less roots on the leaf host against the sh lane's candidate. Exit: the 39 non-executing body-less roots compile in compiled mode once the emitter passes declarations through.
