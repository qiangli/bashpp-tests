# Sprint 117 lowering boundary

`identities.tsv` independently inventories every certified start-site node,
public profile/corpus identity, five Bash# families, 33 compiled-runtime cases,
and 13 agentic boundary cases. It stores an exact ordered identity digest, not
only a count, so an equal-size substitution cannot pass.

Run the P0 structural gate:

```sh
tools/lowering/validate.sh
```

`tools/lowering/differential.rb` accepts `--case FAMILY/CASE` (or a shell
glob). It authenticates Go against the existing public Go 1.27.0 pin in
`docs/tour/toolchain.tsv`, requires two identical generated Go files, builds
and executes the binary, and compares byte-identical interpreter parity. A
missing compiler, skipped case, or interpreter wrapper is always a FAIL.

On this host the existing `GOTOOLCHAIN=go1.27.0 go env GOROOT` acquisition
path resolves the exact pinned binary and its checksum. A real one-case attempt
then reaches `bashy transpile --bashpp … -o …go`; the current product exits 127
there, so it records an honest transpilation/parity failure before any generated
Go, build, or binary run can be claimed.
