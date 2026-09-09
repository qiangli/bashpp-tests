---
id: 2bce26817abb
kind: task
title: Enumerate Go bridge standard-library test obligations
seq: 13
status: done
priority: p1
created: 2026-09-09T03:33:39.757644Z
assignee: qiangli
sprint: 118
closed: 2026-09-09T04:48:14.314556Z
---

W6 initial: derive actual exposed stdlib package list from sh; inventory applicable upstream tests and map to real bridge execution obligations. Own new tools/bridge-corpus and docs/bridge-corpus only. No exclusions invented, no claim native go test certifies bridge. Parent 6f0c4d9a31be.

Review and acceptance,2026-09-08:
Reviewed native bridge inventory merged;180 exposed package rows,178 reviewed host packages and2 explicit host refusals. Inventory/native tooling manager gate passed16 tests/35 assertions and offline integrity. This closes inventory only; native oracle failures and interpreter-owned test-body work remain open in82a8a7687fec and parent6f0c4d9a31be.
