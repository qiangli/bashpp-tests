---
id: e6c82be4a112
kind: task
title: 'Sprint 155.7: corpus-verify.go — independent Go verifier of a full corpus-gate run from emitted events only'
seq: 63
status: done
priority: p0
created: 2026-09-12T23:09:01.82511Z
weave: 131
assignee: qiangli
sprint: 155
closed: 2026-09-12T23:22:36.53111Z
resolution: fixed
closed_by: s155-verifier-a
---

Deliver tools/upstream-harness/corpus-verify.go (+ corpus-verify_test.go) — an independent reader of ONE corpus-gate.sh run: it reads only the emitted event/record streams under an evidence directory (the testdir events.jsonl, the types-backend events, the go-backend package events, and the native-lane counterparts) and NEVER reads test source, directives, manifests-as-authority, or makes a recipe/applicability decision (observer.go from S157.3 is the precedent for shape; package-verify.go/types-verify.go/backend-verify.go for the record formats — read them first). It must re-derive and print: unique root IDs and their count (expected 3,651 = 2,726 testdir + 899 typechecker + 26 package), per-runner PASS/FAIL/SKIP for the native lane and for each Bash++ mode, the SKIP set as a sorted ID list (to compare against the frozen 39), per-root per-mode terminal state, the count of native tested-source executions in the backend lanes (must be 0; find the record field that distinguishes a native exec from a backend exec and assert on it), and a sorted SHA-256 manifest of every file it read. Exit 0 only when every check holds; exit 1 with one line per violation otherwise. Flags: --evidence DIR, --expect-roots N, --expect-skips FILE(sorted IDs), --manifest OUT. Unit tests with one fixture per defect it must catch: duplicate ID, missing ID, extra SKIP, a native exec record in a backend lane, a root missing one mode's terminal, a manifest hash mismatch, and a zero-test package inversion. Proof: go test -count=1 ./tools/upstream-harness/ on novidesign.local. The Barrier A/B events on the Linux host are NOT available to you — the manager will run your binary against them after Barrier B exits; make the record-format assumptions explicit in a doc comment and keep it strictly read-only. RULES (Sprint 155, user-locked): every harness, test, validator, launcher and report generator is Go or Bash — no Ruby/Python/other language may be added or executed (D4). Repo = bashpp-tests only; never edit or rebuild ../bashy, ../sh, ../coreutils. Never run anything on the authorized Linux certification host. VERIFY ON novidesign.local, NOT on this machine: rsync -a --delete --exclude .git --exclude .cache "$PWD/" novidesign.local:~/sprint155/lanes/<your-story-id>/ then ssh novidesign.local "zsh -lc 'cd ~/sprint155/lanes/<your-story-id> && <command>'" (Go 1.27.0 darwin/arm64 and a running podman machine are there; the pinned Barrier B base trees are at ~/sprint155/base/{bashy,sh,coreutils,readline,filebrowser,bashpp-tests} with ~/sprint155/base/bashy/bin/bashy.real built). Kill only exact pids you own — never pkill by pattern. Commit on your branch with the trailers Sprint: #155 / Story: S155.<n> / Story-ID: <your story id> as the last paragraph; git diff --check clean; report every number you measured with the exact command.
