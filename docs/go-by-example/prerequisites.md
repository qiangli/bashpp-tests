# Measured product state of the Go by Example gate

> Historical candidate001 report. Superseded by the full
> [runtime candidate005 replay](sprint118-candidate005.md). Counts and defect
> status below describe that earlier candidate only; they are not current
> acceptance claims. The earlier evidence is retained as diagnostic history.

Sprint 118, Story #3, Story-ID `fa07603b71dc`.

Nothing here is a projection. Every line is derived from one real run of
`tools/go-by-example/gate.sh` against the authenticated `gosource-v1` diagnostic
candidate over all 85 rows in all three modes, retained in full at
[`tests/go-by-example/sprint118-story3-candidate001.jsonl.fail`](../../tests/go-by-example/sprint118-story3-candidate001.jsonl.fail)
and anchored in `evidence-roots.tsv`.

The candidate is the tag-enabled diagnostic build
(`GOTOOLCHAIN=go1.27.0 GOMAXPROCS=3 GOFLAGS=-p=3 make build BASHY_GOSOURCE=1`),
launcher `454c25a8`, payload `11268961`, front end `gosource-v1`, over the
reviewed `bashy` / `sh` / `coreutils` / `readline` / `filebrowser` revisions in
`candidates.tsv`, on the pinned `go1.27.0 darwin/arm64` SDK.

## 1. The contract commands exist now

The previous edition of this document recorded `--source=go` as NOT IMPLEMENTED
in either mode. W1 landed it. Both contract commands run:

```console
$ bashy --bashpp --source=go hello-world.go
hello world
$ bashy transpile --bashpp --source=go hello-world.go -o gen.go --map gen.go.map
$ echo $?
0
```

The generated Go is real lowered output (`mvdan.cc/sh/v3/lower`), the source map
validates against the shared corpus schema, and the artifact builds and runs.
The gate no longer documents a missing flag; it measures the front end.

## 2. The CLI contract this corpus binds

```
bashy --bashpp --source=go SOURCE.go [ARGV...]
bashy --bashpp --source=go --go-file A.go --go-file B.go
bashy transpile --bashpp --source=go SOURCE.go       -o GEN.go --map GEN.go.map
bashy transpile --bashpp --source=go --go-file A.go --go-file B.go -o GEN.go --map GEN.go.map
```

`--go-file` is the product's own repeatable multi-file selector, and the gate
uses it for the one multi-file row. **A second source file is never appended as
an operand.** `internal/cli/gosource.go` stops flag scanning at the first
non-`-` operand and hands surplus operands to the program as argv, so the
operand spelling would have compared a one-file build against the oracle's
two-file package with nothing in any stream to show for it. Both the gate and
`validate-evidence.rb` bind this, and the validator checks the *recorded argv*
of every multi-file product stage, not merely the recipe prose.

### DEFECT 1 — program argv is unreachable alongside `--go-file`

There is no spelling that passes explicit multi-file input *and* program
arguments. Measured against the candidate:

```console
$ bashy --bashpp --source=go --go-file main_test.go --go-file driver.go -- -test.v
bashy: --go-file cannot be combined with a file operand
$ bashy --bashpp --source=go --go-file main_test.go --go-file driver.go -test.v
flag provided but not defined: -test.v
```

`stripGoSourceInvocationFlags` treats `--` as the end of options and *appends it
to argv*, where `ResolveGoSource` then sees it as a file operand and refuses the
combination; without `--`, a leading-dash argument falls through to Go's `flag`
package and is rejected as a shell option.

Needed API: let `--` terminate the Go-source selector group and pass everything
after it to the program, so `--go-file A --go-file B -- ARGV...` is accepted.
This is the only thing blocking the `test_program` row from being *attempted*
under its real `-test.v` recipe; it is a CLI defect, not a lowering one.

### DEFECT 2 — `os.Args` is the interpreter's argv, and is not indexable

```console
$ bashy --bashpp --source=go argv.go alpha beta
n= 26
argv.go:11:18: BASHPP-ESELECTOR-ROOT: __gosource_import_0_1 is not a structured value
```

`len(os.Args)` reports the *bashy process's* argv (26 entries here, none of them
the program's), and indexing `os.Args[i]` fails outright. The
`examples/command-line-arguments` row therefore cannot pass in the interpreted
mode regardless of how argv is spelled. The compiled mode does not share this:
the lowered Go binary receives its own argv normally.

## 3. Measured results

Denominator 255 (85 rows x 3 modes). All 85 oracle attempts pass, which is what
makes the product columns meaningful.

| mode | passing | dominant failure |
|---|---|---|
| `oracle` | 85/85 | — |
| `compiled` | 38 | 31 rows never transpile |
| `interpreted` | 0 | expression/builtin lowering gaps; plus DEFECT 6 below |

### Compiled mode: 31 rows fail at `transpile`, 0 fail at `go build`

Every transpile that succeeded produced Go that compiled and ran. The refusals
group into a small number of front-end gaps:

| rows | diagnostic |
|---|---|
| 10 | `LOWER-EUNSUPPORTED` — word call requires resolved native function / unary `&` / committed `*ast.SelectorExpr` |
| 8 | `gosource: unsupported expression *ast.ArrayType` (`[]byte(...)`, `[]string{...}`) |
| 6 | `gosource: unsupported expression *ast.FuncLit` |
| 4 | `LOWER-ETYPE` — channel element inference, address of a composite literal |
| 1 | `LOWER-EUNDEFINED: undefined: bool` |
| 1 | `gosource: unsupported type *ast.IndexExpr` |
| 1 | `invalid receiver type List[T] (type is not declared in this session)` (generics) |

### DEFECT 3 — channel ownership in the lowering runtime

Six rows transpile, build and then fail at run time with
`bash++: channel belongs to a different ownership scope`:
`channels`, `channel-buffering`, `channel-directions`,
`channel-synchronization`, `closing-channels`,
`non-blocking-channel-operations`, plus `range-over-channels`. Two of them go on
to report `BASHPP-EEXPR-UNDEFINED: undefined: msg` / `undefined: more`, i.e. the
receive binding is lost with the channel.

### DEFECT 4 — untyped float constants render in the wrong form

`examples/constants`: the oracle prints `6e+11`, the compiled artifact prints
`600000000000`. Same value, different `fmt` rendering of an untyped constant.

### DEFECT 5 — `print`/`println` builtins produce nothing

`examples/embed-directive` writes `hello go`, `hello go`, `123`, `456` to
**stderr** through Go's `print` builtin. The oracle does; the compiled artifact's
stderr is empty. Its stdout matches exactly, so the row fails on the builtin
alone.

### DEFECT 6 — `log` reports the generated file/line, not the source position

`examples/logging`: the oracle prints `logging.go:40: with file/line`, the
compiled artifact prints `main.go:24:`. The transpiler emits a valid source map
but `log.Lshortfile` resolves against the generated file, so a user-visible
position points into `generated.go` instead of their own source.

### DEFECT 7 — panic output loses the goroutine trace

`examples/panic`: the oracle emits `panic: a problem` followed by a blank line
and a goroutine traceback; the compiled artifact emits only `panic: a problem`.
The row's `panic_trace` normalization truncates at the traceback, and the
remaining difference is real.

### DEFECT 8 — the interpreted mode invokes the Go toolchain at run time

This is not visible in any stream; the compared filesystem-effect channel found
it. With no explicit `GOCACHE`, the interpreted mode populated several thousand
`$HOME/Library/Caches/go-build/**` entries *inside the program's execution root*,
along with `asm@`, `compile@`, `link@` and `go@` telemetry counters. The
interpreted mode is not evaluating these programs; it is driving the pinned
toolchain.

The gate now supplies one `GOCACHE` outside every execution root, identically to
all three modes, so the effect channel measures the program instead of the
toolchain. What it does **not** do is suppress the telemetry, and the residue is
therefore still recorded and still fails the comparison:

```
+home/.agents/otel/spool/spans.jsonl
+home/Library/Application Support/go/telemetry/local/{asm,compile,go}@go1.27.0-....count
+home/Library/Application Support/go/telemetry/local/{upload.token,weekends}
```

Eight rows — `hello-world`, `closures`, `for`, `functions`, `if-else`,
`range-over-built-in-types` among them — agree with the oracle on stdout, stderr
and exit status and fail **only** on this residue. That is the honest state: an
interpreter that writes its own telemetry into the program's `HOME` is not
side-effect transparent, and no measured off-switch removed it (`GOTELEMETRY=off`
does not; the bashy spool path is derived from `HOME`). Excluding tooling
telemetry from the compared channel would be a schema decision — a new declared
behavior or normalization — and this story does not grant itself one.

## 4. Runtime environment: answered, not deferred

The previous edition listed `GOROOT`/`GOCACHE` as an open W1 contract question.
It is answered by measurement: without `GOROOT` the front end refuses every
program with `could not import fmt ... ($GOROOT not set)`, and `GOMODCACHE` is
its module-import counterpart. All three of `GOROOT`, `GOMODCACHE` and `GOCACHE`
are therefore part of the **common** environment block — the oracle binary and
the compiled artifact receive them and ignore them, so
`examples/environment-variables` observes the same keys in all three modes and
`declared_env_divergence` stays empty. `validate-evidence.rb` refuses a chain
that grants them to the interpreter alone.

The compiled mode's lowering runtime is no longer provisioned through
`GBE_SH_MODULE`. It is the `mvdan.cc/sh/v3` repository the **authenticated**
candidate declares, at its proved clean commit.

`examples/environment-variables` itself still fails in the interpreted mode, on
`BASHPP-EEXPR-FORM: unsupported scalar call` for `os.Getenv("FOO")` used as a
call argument — the compiled mode lowers the same line correctly.

## 5. Two harness defects corrected in this story

Recorded because they were misattributing harness gaps to the product.

- `examples/pointers` was classified `deterministic` while printing `&i`, a real
  ASLR address. Two invocations of the *same* binary cannot agree on it; the row
  only passed because the oracle is compared with itself. It now carries
  `pointer_identity` / `pointer_address`, matching `examples/string-formatting`,
  which already declared the pair.
- `wallclock` did not cover three renderings of the same unavoidable reading:
  the monotonic `m=+0.000044210` component, the ANSIC layout without a trailing
  `UTC`, and the Kitchen layout `4:34AM`. Normalizer `VERSION` is now 3. The
  widening is deliberately narrow: `examples/logging` still fails on DEFECT 6,
  which is a source position, not a clock.

## 6. Closure condition

Story `fa07603b71dc` closes when the gate reports
`verdict=pass denominator=255 executed=255` against the reviewed candidate, and
`validate-evidence.rb` authenticates that chain against a root committed to
`evidence-roots.tsv`.

The anchored root today is a **fail**. It is anchored because it is real and
worth re-verifying, not because it is coverage: `validate-evidence.rb` accepts a
`pass` verdict only when `denominator == executed == 255`, `missing == 0`, and
every single attempt is spawned, complete and passing. No row may be excluded to
get there — the 85-row denominator is derived from the pinned upstream `.go` set
and re-checked on every run.
