# Sprint118 candidate013 official typechecker result

Candidate013 completed all 743 official typechecker roots in 246.2 seconds: **682 PASS, 59 FAIL, 2 UPSTREAM_SKIP**. Full3495 inventory validation and native joins preceded selection. This is diagnostic coverage through the product's checking/transpilation paths; original test bodies were not executed and the overall product gate remains FAIL.

The exact root join against full008/candidate006 shows 112 FAIL→PASS, 570 PASS→PASS, 59 FAIL→FAIL, and the same two native skips. There are no PASS regressions in this measured axis. These are fresh candidate013 results; prior evidence was not upgraded or resumed.

The 59 failures are completely classified:

| Roots | Missing capability | Concrete original example |
|---:|---|---|
| 18 | Upstream test-only `assert` builtin semantics | `check/builtins0.go`, `check/literals.go`; both checker families |
| 18 | Exact build-tag applicability recipe | `check/go1_19_20.go`, `fixedbugs/issue66064.go` |
| 8 | Joint original multi-file package checking | `check/decls2`, `check/importdecl0`, `check/importdecl1`, `check/issue25008` |
| 6 | Structured importer diagnostic rendering | `check/map0.go`, `fixedbugs/issue43109.go`, `fixedbugs/issue48082.go`; expected primary matches but unpositioned native go-list continuation remains |
| 3 | types2-local parser/checker diagnostics differ | `TestLocal/issue47996.go`, `issue68183.go`, `issue71254.go` |
| 2 | FakeImportC checker recipe | `check/importC.go` |
| 2 | Lowerer nil-body panic | `fixedbugs/issue40038.go`; interpreted check PASS, compiled transpile panics in `lower.(*emitter).block` |
| 2 | Generic indexed instantiation lowering | `fixedbugs/issue59958.go`; unsupported `*ast.IndexListExpr` |

All 28 unsupported recipe roots remain FAIL with 56 explicit unfinished phase references. Their 56 fallback checking/transpilation probes do not satisfy the missing recipes. The 713 supported recipes produced 1,426 product phases and 1,426 matcher phases. Together with fallback probes there are 2,908 root-linked captures, plus two matcher build captures. All 2,910 exited; no deadlines occurred. Compiled mode has 682 PASS/59 FAIL and interpreted mode 684 PASS/57 FAIL; skips have no credited product modes.

Both `issue78346.go` native skips are source-bound: the pinned fixture declares `ignore && !386 && !arm && !mips && !mipsle && !wasm`. Both pinned harnesses' `shouldTest` recognize release tags, GOOS and GOARCH only, so `ignore` evaluates false. `testPkg` then skips because no files remain. `complete-observation.json` retains fixture/harness SHA256 records and exact native terminal observations. Neither skip is product PASS.

Independent retained integrity validation passed 8,373 unique file/absence records, root membership/seals, native observation joins, shared-cache environment bindings and 2,910 process streams. Producer source and module postchecks also passed. Reproduce the read-only retained audit:

```sh
/usr/bin/ruby /Users/qiangli/.bashy/sprint118/evidence/go-full/product013-preparation/audit-retained.rb
```

The source modules were authenticated offline before launch: 19 dependency modules, all 4,391 source files and archive/go.mod records, exact candidate013 commits and launcher/payload, pinned SDK, and generated scaffold bytes. The module manifest is `~/.bashy/sprint118/sources/go-full-candidate013-modules/manifest.json`, SHA256 `8f6b4ae106b5855ae69858ecabf7c5cb544457304052d9067f45ca259c3ec837`. The exact reviewed command and frozen bindings are in `typechecker-command-review.json`; validation is in `module-validation.json`.

Raw results remain in sibling `product-typechecker-013`. Ledger SHA256: `ccf8026ad601278d42ebeb4a77f9de9b0951ba8d28cfa1795028c5225c987949`. Summary SHA256: `831d3164de014b62e506ecf74dc007d66f947f0babb620b9e75584ade2220366`. Complete failure records and original per-mode commands are linked in `complete-observation.json`. The isolated selector commit is `2b2f74ead6f04a4c1612fd005f0d2287feadd462`; working tree is clean. Evidence occupied about 102 MiB and the dedicated Go build cache about 133 MiB at completion. Both remain retained.

No full3495 run was launched. Candidate014, corrected joint checking and the independently reviewed compile adapter require fresh authenticated context before subsequent acceptance runs.

Manager independent gate passed2.016s on2026-09-09.
