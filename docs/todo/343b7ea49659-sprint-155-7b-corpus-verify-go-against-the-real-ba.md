---
id: 343b7ea49659
kind: task
title: 'Sprint 155.7b: corpus-verify.go against the real Barrier B streams — fix the record model, keep the 312 native-execution finding'
seq: 68
status: done
priority: p0
created: 2026-09-13T00:02:32.705318Z
weave: 137
assignee: qiangli
sprint: 155
closed: 2026-09-13T00:40:58.379634Z
---

corpus-verify.go (merged, S155.7) ran on the real Barrier B evidence and reported 2,635 violations (docs/upstream-harness/barrier-b/corpus-verify.summary.txt). ONE class is real and must be KEPT: 312 native tested-source executions = the 156 typechecker leaves with no types-backend record in either product lane (checker-API unit tests) x 2 modes — that check stays and must keep firing on these streams. The rest are the verifier's record model, not the run, and must be fixed against the real streams, which are on novidesign.local at ~/sprint155/evidence/barrier-b/{evidence-native,evidence-interpreted,evidence-compiled}/ (read-only; copy, never edit): (a) ~1,200 'invalid event JSON: cannot unmarshal object into Go struct' — a field typed string where the stream carries an object; (b) the per-phase accounting ('N backend dispositions for N phases', 'N phase records and N phase results') — multi-package compiledir/rundir/runindir roots emit one backend record per package compile plus link/execute, so the model must count records per (root, phase, package/input), not per phase name; (c) 12 'types-backend execution ... has no Go terminal' and 4 'duplicate ID in typechecker events' — classify against the streams: real, or a model error; if real, they stay as violations with the exact IDs. Deliver: fixed corpus-verify.go with a fixture per corrected shape (built from real-stream excerpts), and a run on ~/sprint155/evidence/barrier-b reporting EXACTLY the violations that remain, each explained in a doc comment. Expected end state on Barrier B: ROOTS 3651, SKIPS 39, the 312 native-execution violation (until S155.11 lands and the gate reclassifies the 156), and nothing else unless proven real. RULES: Go or Bash only; repo = bashpp-tests; never run on the authorized Linux host; verify on novidesign.local (rsync -a --delete --exclude .git --exclude .cache "$PWD/" novidesign.local:~/sprint155/lanes/<story-id>/ then ssh novidesign.local "zsh -lc 'cd ~/sprint155/lanes/<story-id> && <command>'"); kill exact pids only; COMMIT on your branch — no commits = failed run; trailers as the last paragraph of every commit: Sprint: #155 / Story: S155.7 / Story-ID: <printed on add>.
