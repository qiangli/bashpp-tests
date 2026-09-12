---
id: 98a5b9a3fc8a
kind: task
title: S153.0 harness — cgo roots retained (D1), leaf-153 runs, manifests
seq: 60
status: done
priority: p0
created: 2026-09-12T14:55:45.964448Z
sprint: 153
closed: 2026-09-12T19:30:36.252082Z
---

D1 (approved 2026-09-12): partition-emit.go files 'package requires cgo' / 'unknown import path "C"' / //go:build cgo go-run failures as retained (the pure-Go shell declares no cgo); keep any compiled row whose cause is not cgo. Test in partition-emit_test.go; regenerate manifests from the unchanged Barrier A events; record the movement in the commit body. Then leaf-153 run 0 (192-root union: active-153 + leaf-151r2/153 + leaf-152r0/153 + leaf-152r1b/153) on candidate 4 from fresh /srv/sprint153, and run 1 at close.
