---
id: 29b6f7a3abcc
kind: task
title: 'Sprint 155.11: corpus-gate product denominator = the 743 seam-exercised typechecker leaves; the 156 checker-API unit-test leaves are native-only, zero credit, listed by ID'
seq: 67
status: done
priority: p0
created: 2026-09-13T00:02:15.000842Z
weave: 136
assignee: qiangli
sprint: 155
closed: 2026-09-13T00:40:58.321423Z
---

Barrier B (docs/upstream-harness/barrier-b.md) found that corpus-gate.sh has credited 156 typechecker leaves as product PASS in both Bash++ lanes since Barrier A although they never reach the substituted conf.Check call (no types-backend record in either lane): TestInstanceInfo 68, TestObjectString 34, TestInstantiatedObjects 22, TestInstantiateEquality 22, TestGCSizes 4, TestAtomicAlign 4, TestHasher 2 — checker-API unit tests, not fixture checks. The seam-exercised families are TestCheck 148 + TestFixedbugs 548 + TestSpec 26 + TestExamples 16 + TestLocal 5 = 743 (the Sprint 142 inventory, docs/upstream-harness/typechecker-matrix.tsv). Deliver, in Go/Bash under tools/upstream-harness/: (1) corpus-gate.sh and the tally emit the product typechecker denominator as 743 and report the 156 as a separate native-only class (listed by ID with zero credit, never PASS, never SKIP); the printed totals become 3,495 / 3,456 / 39 with the 156 shown beside them; (2) partition-emit.go never assigns a native-only leaf to an owner; (3) the decision is by SEAM EVIDENCE (a product-lane leaf with no types-backend record is native-only), never by test-name pattern — the family names above are documentation, not the rule; (4) a unit test with a fixture stream proving a no-backend leaf is classed native-only and a with-backend leaf is not; (5) re-emit Barrier B's manifests from the retained events (copied to novidesign.local ~/sprint155/evidence/barrier-b/) and show the summary unchanged except for the new class. Read barrier-b.md and corpus-verify.summary.txt first. RULES: Go or Bash only; repo = bashpp-tests; never run on the authorized Linux host; verify on novidesign.local (rsync -a --delete --exclude .git --exclude .cache "$PWD/" novidesign.local:~/sprint155/lanes/<story-id>/ then ssh novidesign.local "zsh -lc 'cd ~/sprint155/lanes/<story-id> && <command>'"); kill exact pids only; COMMIT on your branch — no commits = failed run; trailers as the last paragraph of every commit: Sprint: #155 / Story: S155.11 / Story-ID: <printed on add>.
