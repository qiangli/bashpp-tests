---
id: 8b7675a669b8
kind: task
title: Cross-check the Go Day-1 table against the measured corpus
seq: 2
status: done
priority: p2
created: 2026-09-01T06:36:04.106466Z
assignee: lintel
sprint: 97
closed: 2026-09-01T06:36:15.639942Z
---

The Go Day-1 table in sh/syntax/bashpp_startsites_test.go copies its classes from baseline.tsv, so a re-measured corpus can flip a class while both suites stay green. verify-day1-table.sh compares them and fails on disagreement. All four failure modes induced and confirmed, including the vacuous-pass guard.
