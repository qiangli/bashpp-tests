---
id: 3ea9bb6062a9
kind: task
title: 'S117-01A: executable Go-profile semantic fixtures'
seq: 10
status: todo
priority: p0
created: 2026-09-07T18:10:52.750213Z
sprint: 117
---

P0 child of S117-01 coverage foundation and parent59bc1d4ea772. Extract public Go-profile source fixtures from existing sh interpreter/syntax tests to make certified semantic coverage executable independently of the compiler. Own ONLY tests/lowering/go-profile/** and docs/lowering/go-profile-cases.tsv (new files). Do not edit tools/lowering,existing fixtures,other manifests or sh. Cover expressions/const/conversions/control flow, composites/pointers, interfaces/methods/assertions, generics/inference and builtins. Use existing supported source forms. Define TSV id,category,fixture,expected_status,stdout,stderr,public_test_ref; preserve explicit expected error versus success. Each case references exact public sh test identity, not private umbrella ledger. No minimum count theater: choose meaningful cases covering every public source-reachable semantic family, report any missing category honestly. Validate fixtures against current interpreted binary /var/folders/vg/nlsn8n8x77n1xgg2nlpnvz180000gn/T/sprint117.xwst9qeb/bash; diagnostics via product /var/folders/vg/nlsn8n8x77n1xgg2nlpnvz180000gn/T/sprint117.xwst9qeb/bashy if checker-only. Keep positive/negative source semantics separate. Do not mark compiled parity; compiler pending. Use shellquote-safe Ruby/Python driver in your owned directory for interpreted validation and an optional --case filter. Preserve real output artifacts or expected files, no guessed green. No mailbox/role/registry/skills troubleshooting; manager reads workspace. Commit named files only, no push/pins; read repository instructions. This lane supplies evidence samples to main coverage worker without modifying that worker files.
