# Go oracle programs — not bash++ fixtures

These are **verbatim Go**, and that is the point.

They were filed as `.bpp` fixtures, which made them unrunnable and misgraded:
each begins `package main` with `import "fmt"` and `func main()`, and `package`
is explicitly **outside** the supported subset
(`../../../docs/bashpp-posix-superset-syntax.md`). A runner pointed at them was
grading Go source as though it were shell.

Their real use is the **differential method** in
`../../../bashy/docs/bash-plus-plus-go-example-corpus.md`: run the Go program
with a pinned toolchain as an ORACLE, run the independently authored bash++
form, and compare observable behaviour. For that, being real Go is required —
so they are `.go` here, excluded from the fixture sweep, and kept.

`cannotassign.go` and `assign.go` additionally carry `// ERROR "regex"`
annotations. The harness now understands that form; the bash++ fixtures that
exercise those diagnostics live under `../` in the numbered directories.

Provenance is unchanged: each file retains its upstream Go copyright header and
its `1:1 bash++ adaptation of ../go/test/...` line. Note that `../go/` is not
mounted in this tree, so those references are currently unresolvable — see the
denominator note in `../../README.md`.
