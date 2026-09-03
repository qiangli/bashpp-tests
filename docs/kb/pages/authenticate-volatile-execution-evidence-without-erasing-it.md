---
type: gotcha
title: Authenticate volatile execution evidence without erasing it
description: WHEN validating rerun evidence for nondeterministic upstream programs, self-consistency (recomputing normalization/summaries/root/verdict from the raw JSONL) is necessary but NOT sufficient: it cannot detect a row whose raw/state/exit were copied from a DIFFERENT (e.g. sibling baseline) row while keeping that row's own correctly-bound command — the copy is internally perfect. Close the gap with REPLAY: independently re-execute every attempt's bound command against a freshly materialized environment and require the fresh spawn/state/exit (and, for non-baseline modes, fresh normalized output) to match the ledger. Only tolerate byte drift where genuine upstream nondeterminism is expected (e.g. pinned-Go baseline rows), and only once exit/state already match.
status: validated
evidence: 'Story 759341a95870: weave-issue-18 shipped self-consistency-only validation (291-record ledger, six volatile pinned-Go reruns tolerated). weave-issue-22 found it did not detect a forgery that keeps each Bash++ row''s own correct mode-specific command but copies its sibling baseline row''s spawned/state/exit/raw/normalized/stage fields and recomputes every hash/root/verdict — internally consistent, so the self-consistency-only validator accepted it. Added a replay phase (re-execute every attempt for real, require fresh observation to match); the same exploit is now rejected. Regression test: tools/tour/evidence-tamper-tests.sh scenario 2.'
source:
    tool: codex:gpt-5.6-sol-r
    host: dragon
    episode: weave-issue-18
corrections:
  - tool: claude-sonnet5
    host: dragon
    episode: weave-issue-22
    at: "2026-09-03T14:55:10Z"
    note: 'Self-consistency alone is an incomplete authentication mechanism, not just an efficiency tradeoff — it is silent to same-run cross-row copying that retains correct command binding. Replay (or an equivalent external attestation) is required, not optional.'
created: "2026-09-03T14:03:09Z"
updated: "2026-09-03T14:55:10Z"
---
