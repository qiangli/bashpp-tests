# Public Go-profile source cases

This directory contains 52 executable source cases adapted from the public
`sh/interp/bashpp_*_test.go` tests identified in
`docs/lowering/go-profile-cases.tsv`. They establish interpreted observations
for this selected corpus. They do not establish complete Go-profile coverage
or compiled parity.

`validate.rb` invokes the selected interpreter using an argument array,
`[binary, "--bashpp", fixture]`, and compares the exact process exit code,
stdout bytes, and stderr bytes with the manifest. The manifest currently has
33 cases expecting exit 0 and 19 cases expecting exit 2. Different nonzero
exit codes are failures, even if diagnostic text matches.

The validator requires an explicit executable via `BASH_ENGINE_BIN` or `--bin`.
It resolves that path before changing the working directory. All fixture paths
must be contained within this directory. IDs and fixture targets must be unique,
and every `.bpp` file must appear exactly once in the manifest. These checks
run over the entire corpus before applying an optional case filter.

```sh
BASH_ENGINE_BIN=/path/to/bash ruby tests/lowering/go-profile/validate.rb
ruby tests/lowering/go-profile/validate.rb --bin /path/to/bash --case if-branches-scopes
ruby tests/lowering/go-profile/validate.rb --bin /path/to/bash --artifacts /tmp/profile-observations
ruby tests/lowering/go-profile/validate.rb --self-test
```

Artifacts go to a newly created external temporary directory by default.
`--artifacts` selects an external directory; paths inside this repository are
rejected. The printed directory retains each case's stdout, stderr, exact exit
code, JSONL observation, source hash, and interpreter path/hash metadata.
Runtime artifacts and machine-specific interpreter paths are not source files
and must not be committed.

The manifest has seven tab-separated columns:

| Column | Meaning |
|---|---|
| `id` | Stable source-case identifier |
| `category` | Semantic family |
| `fixture` | Contained relative `.bpp` path |
| `expected_status` | Exact integer process exit code |
| `stdout` | JSON string containing expected stdout bytes |
| `stderr` | JSON string containing expected stderr bytes |
| `public_test_ref` | Public source test identity, `sh/interp/file_test.go:TestName[/subtest]` |

Expected streams record observations from the interpreted CLI. Some diagnostics
include the relative fixture filename, so cases run with this directory as cwd.
The public source references let reviewers compare each adapted case with its
original test. In particular, `cap-type-neg` records both the builtin diagnostic
and the following short-declaration diagnostic.

The cases exercise expressions, constants, control flow, composites, pointers,
interfaces, methods, assertions, generics, builtins, and negative conversion or
assignability checks. This selection lacks a positive conversion-expression
case. Assertion positives are included in interface cases. The builtin residual
case uses a channel to observe `len` and `cap`; it is not a concurrency suite.

One explicit adaptation is `const/blank-specs-advance-iota.bpp`: it omits the
original `${_-unbound}` probe because the CLI gives `_` a shell-specific value.
The source case retains the iota-advance observations `A=1` and `B=3`. Some
table-driven source cases use the same `func main() { ... }; main()` scaffolding
as their original interpreter test.

Self-tests reject fixture deletion, duplicate IDs, unknown case selections,
path traversal, unlisted source files, non-integer expected status, and the wrong
nonzero status. A passing selected run certifies only the named interpreted
observations for the executable whose hash appears in the external artifact.
