---
id: e29305614139
kind: task
title: Shared three-mode corpus execution and evidence contract
seq: 11
status: done
priority: p0
created: 2026-09-09T03:33:39.722255Z
weave: 7
assignee: qiangli
sprint: 118
closed: 2026-09-09T04:48:14.249803Z
---

Implement W2: reusable subprocess, CLI phase and candidate-provenance contract for original .go inputs with --source=go. Keep shared library under tools/corpus only; other workers own tools/tour and tools/go-by-example. Parent 6f0c4d9a31be; goal upstream-go.

Review and acceptance,2026-09-08:
Reviewed and integrated in79c685e. Manager gate final-corpus-tools-gate-retry.json passed; shared process/phase/provenance contract and original-map byte authentication verified (19 tests/98 assertions, no skips). Full corpus parents remain open.
