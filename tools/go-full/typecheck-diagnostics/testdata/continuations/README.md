# Original multiline diagnostic controls

The `.go.txt` files are unchanged Go 1.27 source fixtures. Their Go Authors
copyright headers and the upstream [BSD license](../../LICENSE) apply. The
`.stderr` files are unchanged candidate006 product diagnostics retained by
official full008. `provenance.json` records original paths, sizes and hashes;
the regression test independently pins the hashes in code.

These inputs test diagnostic adjudication only. No Go fixture body is compiled
or executed by this test. Request paths identify the original source spelling;
source and diagnostic bytes are never rewritten to obtain a match.

Pinned source archive SHA256:
`7002403d7cc44529ef6d26f69a44818263395ead7c16c05a5808ae047ebeb0e5`.

The authenticated SDK `src/go/types/check_test.go` `unpackError` returns
`Error.Msg` intact (SHA256
`dbe52f3dc1de5b3e7e8c18cf5274f25e33d11156db1cf69f595d02de8f7a279a`).
Its `Config.Error` separately excludes positioned messages containing `: \t`.
The types2 harness follows the same distinction (SHA256
`fdfa057232cc79938ca904eee87a670a34c36ec835ee26e8b2505b2ffda37398`).
An unpositioned continuation such as `\thave (...)` remains part of the primary
message, including its newline; a positioned secondary is not a substitute.

Both original issue49005 and issue70150 require literal `\n\t` in ERROR
annotations. Missing, altered, orphan, cross-stream or substituted positioned
secondary details must not manufacture a passing match.
