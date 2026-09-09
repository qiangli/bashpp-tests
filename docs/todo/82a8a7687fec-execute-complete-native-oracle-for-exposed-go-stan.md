---
id: 82a8a7687fec
kind: task
title: Execute complete native oracle for exposed Go standard library tests
seq: 16
status: todo
priority: p1
created: 2026-09-09T04:10:21.936059Z
assignee: qiangli
sprint: 118
---

Sprint118 W6 continuation, own tools/bridge-corpus and docs/bridge-corpus ONLY, no subagents/push/closure. Manager seeds prior inventory02879b9 into new workspace before launch. First correct false README/obligations claim no hand-generated testmain can exist: actual SDK src/testing/testing.go:2428 exports testing.Main; describe its real limitations TestMain/fuzz/internal imports without invented impossibility. Implement and run complete native oracle for all178 host-exposed stdlib packages from prior180 package inventory (2 runtime-policy host refusals retained explicitly), unchanged authenticated fullSDK /Users/qiangli/.bashy/weave/bashpp-tests-3387043c/workspaces/issue-8/.cache/go-full-sdk/root and .cache/go-full-sdk-identity.json. Reuse tools/corpus/executor.rb Corpus.capture and tools/go-full/native.rb JSON event parser. Exact -json -p=1 -parallel=2 GOMAXPROCS2 bounded package timeout, all expected package/runtime terminal events, no denominator caps. Retain full stdout/stderr/env/commands, before+after SDK auth, skippedtest reasons/hostconditions. Durable evidence /Users/qiangli/.bashy/sprint118/evidence/bridge-native-001; native evidence only product_execution_claim=false, never productPASS. Do not restart fullsuite for doconly changes. Then prepare exact product test-body driver contract using actual testing.Main and interpreter callbacks, keeping unmodified _test.go bodies interpreter-owned: importing original tested package into native wrapper is NOT productinterpretation. Coordinate through manager, no sh edits. Focused validator tampertests and actual runnable native runner this turn, no analysis-only delivery. Commit proper Sprint:#118 Story+newID trailers. Read manager notes in current weave comments at work boundaries.

Review integration2026-09-08: native runner/inventory authentication and tamper checks delivered in47e4a53. Complete native178package run:155PASS14FAIL9SKIP;81263teststarts and terminals,SDKintegritytrue.14failures include offline external test-vector modules and runtime CPU constraints; retainFAIL, no new exceptions. Interpreter-owned test-body driver contract and source-bound skip adjudication remain open. SDK/source caches relocated with digestmanifest in durable sprint118/sources; rawlogs preserved.
