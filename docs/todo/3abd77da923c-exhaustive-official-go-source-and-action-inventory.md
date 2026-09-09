---
id: 3abd77da923c
kind: task
title: Exhaustive official Go source and action inventory
seq: 12
status: done
priority: p1
created: 2026-09-09T03:33:39.740376Z
weave: 8
assignee: qiangli
sprint: 118
closed: 2026-09-09T04:48:14.273862Z
---

W3 inventory: materialize pinned Go 1.27.0; enumerate full test tree and compiler/typechecker roots, recipe dependencies and sidecars, exact independent denominators, no cap. Own new tools/go-full and docs/go-full inventory only. Parent 6f0c4d9a31be.

Review and acceptance,2026-09-08:
Reviewed and integrated in79c685e. Manager full-inventory and final-corpus gates passed:3398 historical Go files,2726 recipe roots,743 checker roots,26 package roots,17 actions and directory phase obligations. Native full oracle2665 historical PASS/61 native SKIP,741 checker PASS/2 SKIP,26 package PASS. Product full corpus parent remains open.
