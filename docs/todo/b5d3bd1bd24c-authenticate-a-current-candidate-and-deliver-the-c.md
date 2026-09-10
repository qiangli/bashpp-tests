---
id: b5d3bd1bd24c
kind: task
title: Authenticate a current candidate and deliver the complete official-Go baseline replay
seq: 17
status: todo
priority: p0
created: 2026-09-09T06:36:02.000807Z
assignee: qiangli
sprint: 142
---

Moved from Sprint 118 Story #17 by user direction on 2026-09-09.

RESIZED 2026-09-10 by operator direction: this story is now a MEASUREMENT, not a
closure claim. It authenticates a current candidate and delivers ONE complete
official-Go replay whose partition and first-blocker taxonomy staff Sprints
142-145. A failing baseline does not block it; an incomplete or unaccounted
replay does.

CANDIDATE. Reuse the retained Sprint 118 authenticity baseline: Candidate018
replaces stale published-002 references; frozen read-only root
/private/tmp/s118-runtime-018; manifest SHA
a927efce4f80e392f78c9552e0a0f6f3465f1921d1a8fcc3ae7976e02250fdd2; sh
071f2409490641f3ae64ad45560164ca8f60506d; bashy
118bb3f6841a57a7010b7858bf02564c445416f7. That binding is STALE. Freeze and
authenticate a fresh candidate at the published heads instead. This is cheap and
should be verified rather than assumed: the delta from the reviewed Candidate040
(sh 704fa0635f1d, bashy 7e8abb38cebe) to the published heads is NON-CODE - two
docs/todo status files in sh and one .sibling-pins line in bashy - so the
published product is byte-equivalent in code to an already-reviewed candidate and
needs authentication, not re-review. Never edit frozen Sprint 118 evidence.

REPLAY. Run all 3495 official-Go roots with GOMAXPROCS=2 and GOFLAGS=-p=2, in a
single uncapped, unsharded, unresumed pass. The prior attempt failed only on
launch policy, not on code: it exited 143 at a manager-imposed 1800-second window
having attempted 1298 roots. product.rb has no wall clock of its own - its
--timeout is per capture. Allocate a >= 2.5 hour uninterrupted slot. A complete
run measured 4196.77s at candidate006 and extrapolates to about 4850s from
candidate018's 1.39s per root.

VENUE. The replay stays on this darwin/arm64 host and cannot move to the DO
droplet: the skip adjudication is bound to this authenticated configuration, the
expected-failure sets are platform-qualified, and every product row joins native
oracle observations produced here. Treat it as a scheduled EXCLUSIVE local slot -
it also holds TCP port 8090 - while local capacity is otherwise reserved for the
agents working the stories.

DISK. The Story #21 preflight recorded NO-GO at 10.23 GiB free against a
requirement of 6.719 GiB projected retained evidence plus a 4.000 GiB reserve.
That gate now clears with room, but re-run it with an actual df at launch and
NEVER renegotiate the 4 GiB reserve to fit.

ACCOUNTING. Retain complete-attempt evidence and exact missing/phase counts. Do
not claim completion from a capped or partial run, and give no verdict to an
unattempted root. No original-source rewrite and no native-only product credit.

Delivery commits: Sprint: #119; Story: #17; Story-ID: b5d3bd1bd24c.
Cross-reference Sprint #118 upstream-go deferral and docs/sprint-118-handoff.md.
