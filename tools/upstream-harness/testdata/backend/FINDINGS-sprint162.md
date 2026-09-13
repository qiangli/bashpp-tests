# Sprint 162 backend phase dispositions

The retained manifest's compiled rows identify these phase boundaries.  The
authority invokes an assembler or a Go package loader here; neither is a
direct Go-source execution that Bash++ can honestly substitute.  They remain
FAIL in both modes with the existing first line, never `retained`.

| root | phase / first cause | disposition |
| --- | --- | --- |
| `testdir:asmhdr.go` | generate: `.s` compile input | FAIL: unsupported generate phase |
| `testdir:fixedbugs/issue22877.go` | generate: `.s` compile input | FAIL: unsupported generate phase |
| `testdir:fixedbugs/issue37513.go` | generate: `.s` compile input | FAIL: unsupported generate phase |
| `testdir:fixedbugs/issue47317.go` | generate: `.s` compile input | FAIL: unsupported generate phase |
| `testdir:linknameasm.go` | generate: `.s` compile input | FAIL: unsupported generate phase |
| `testdir:retjmp.go` | generate: `.s` compile input | FAIL: unsupported generate phase |
| `testdir:fixedbugs/issue15609.go` | execute: module package includes `call_amd64.s` | FAIL: unsupported execute phase |
| `testdir:fixedbugs/issue74648.go` | execute: module package includes `a.s` | FAIL: unsupported execute phase |
| `testdir:fixedbugs/issue47185.go` | execute: module package includes non-Go `bad.go` | FAIL: unsupported execute phase |
| `package:cmd/compile/internal/ssa` | gotest: package inputs include non-Go files | FAIL: existing gotest non-Go-input disposition |

The compile-only body-less family is separate: once lowering emits the
declaration, the compiler path uses upstream-shaped `go tool compile` and is
eligible to PASS.  A body-less declaration that reaches link/run remains a
linker failure; it is not made permissive by this seam.
