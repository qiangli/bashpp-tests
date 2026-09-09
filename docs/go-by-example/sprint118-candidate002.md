# Published candidate002 full replay

Sprint: #118; Story: #3; Story-ID: `fa07603b71dc`.

The full replay fails. All 85 unchanged original rows have three attempt
records; 242 programs executed and 13 compiled attempts could not produce a
runnable artifact. The sprint and parent acceptance remain open.

| Mode | Pass | Output/status mismatch | Output normalization rejected | Artifact unavailable |
|---|---:|---:|---:|---:|
| Native Go oracle | 85 | 0 | 0 | 0 |
| Bash++ interpreter | 16 | 56 | 13 | 0 |
| Transpiled native artifact | 69 | 3 | 0 | 13 |

The [255-attempt ledger](sprint118-candidate002-ledger.tsv) identifies every
row, mode, result, phase and diagnostic family. Normalization rejection often
follows an earlier product error; it does not imply a comparator defect.

## Candidate and retained evidence

[candidates.tsv](candidates.tsv) retains both exact reviewed candidates.
Candidate002 manifest SHA-256 is
`ddf233e89c2839f299c14010c3d2ca8fba4ffb23e8835b86bd5ae0b6811f9aff`;
payload SHA-256 is
`e9a8a66ca1adbcbc614ab0f0dc9e6ea8d5590cb23e66ce7a8bdc74dab3becce3`.
This is the reviewed default CLI build on Go 1.27.0 darwin/arm64; its manifest
binds clean revisions of all five runtime repositories. No optional build tag
is required by this candidate.

Durable evidence base:
`/Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/gbe`.

- `reviewed-results.jsonl.fail`: complete final recipe ledger.
- `reviewed-results.jsonl.work`: separate mode source/build/runtime roots,
  original assets, test driver, capture logs, maps, generated Go and binaries.
- `reviewed-taxonomy/taxonomy.json`: grouped results.
- `reviewed-taxonomy/failures.jsonl`: exact diagnostics plus captured argv, cwd,
  environment, stream paths and hashes for every failure.
- `reviewed-replay.log`: all 85 row reports and the final failure.

Root `79fc60e9bfadbbfa01f00d7855e16f395841fb65db3e9bf6db419c9add33f791`
is anchored in [evidence-roots.tsv](evidence-roots.tsv). Earlier full runs remain
on disk; the v4 comparator root is explicitly historical. Authentication of a
failing ledger is not a passing product gate.

## Prioritized product failures

1. Eight rows fail `*ast.ArrayType` conversion in both product modes:
   base64-encoding, directories, json, regular-expressions, sha256-hashes,
   spawning-processes, tcp-server, writing-files. This prevents unchanged
   `[]byte(...)` and related expressions from reaching native build.
2. Interpreter imported values/types: eight aggregate selector failures, five
   structured type failures, plus native argument/local named type identity.
   Examples include `os.Args` indexing, `atomic.Uint64`, `embed.FS`, `xml.Name`,
   `log` integer arguments and local `person` values.
3. Interpreter channels, aggregates and calls: receive expressions, local
   fields, composite/address arguments, multiple assignment, callbacks and
   panic/recover. Exact positions and diagnostics remain in raw failure records.
4. Other unavailable compiled artifacts: generic receiver, indexed generic
   type, two addressable aggregate failures (`structs`, `xml`) and missing
   recover helper. Together with ArrayType these account for all 13.
5. Three compiled observable differences: `constants` prints `600000000000`
   instead of `6e+11`; `embed-directive` loses original `print` stderr output;
   `logging` reports generated `main.go:24` instead of `logging.go:40`.
6. Multifile CLI argv: the original `_test.go` plus separate driver uses
   `--go-file A --go-file B -- -test.v`. Candidate002 rejects the separator as a
   file operand. Omitting it also fails because `-test.v` becomes a CLI flag.

Imported process exit also differs: `exit` returns native status 3, while the
interpreter returns 1 with `dependency process exited: exit status 3`. Passing
compiled channel rows do not establish interpreted channel support.

## Harness corrections and boundaries

Original source and asset bytes remain unchanged. The oracle builds/runs the
original package; the interpreter receives original input paths; transpile
produces generated Go and a validated map before real SDK build and binary
execution. The test driver is separate from the original `_test.go`. Integrity
checks cover source, driver and assets at phase boundaries. Runtime roots omit
source files, but this is not an OS-level denial of source or SDK access.

The dependency bridge uses the SDK at runtime. All modes receive an identical
explicit environment and shared cache outside compared runtime roots. Supported
telemetry settings are identical: `OTEL_TRACES_EXPORTER=none`, plus actual
`go telemetry off` under each isolated HOME before its effect baseline. The
gate verifies `go env -json GOTELEMETRY GOTELEMETRYDIR` and retains commands,
logs and mode-file digests. No effects are filtered after execution. The final
replay has zero filesystem-effect failures.

Normalizer v5 fixes three declared-comparator defects using retained real
native observations: positive throughput counts compare schema instead of
volatile values; macOS permission metadata accepts its attribute/ACL suffix;
time output validates fixed values and duration arithmetic before removing
volatile instants. Extra worker events, duplicate/zero counts, changed
filenames, fixed-date/nanosecond errors and logging source errors still fail.

Independent validation re-reads streams/artifacts, rejects duplicate stream
paths, binds raw output to captures, checks native binary magic and revalidates
maps against exact source inputs. Five real-ledger mutations fail after their
self-hashes are recomputed: duplicate stream, substituted output, native
artifact digest, telemetry mode digest and telemetry setup command.

## Manager verification

Run from bashpp-tests:

```sh
CORPUS_TEST_GO=/Users/qiangli/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.0.darwin-arm64/bin/go ruby tests/go-by-example/gate_contract_test.rb
tools/go-by-example/validate.sh
ruby tools/go-by-example/validate-evidence.rb /Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/gbe/reviewed-results.jsonl.fail
ruby tools/go-by-example/tamper-retained-evidence.rb /Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/gbe/reviewed-results.jsonl.fail
```

Measured tests: 11 tests / 60 assertions / zero skips; five retained-evidence
mutations rejected with specific diagnoses. Full replay below intentionally
exits nonzero until product defects are fixed. Use a new evidence filename:

```sh
ruby tools/go-by-example/gate.rb \
  --candidate /Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/candidate.json \
  --bashy /private/tmp/s118-published-002/bashy/bin/bashy \
  --evidence /Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/gbe/manager-results.jsonl
```

After fixes, freeze/review a new candidate and replay all rows/modes. Closure
requires all 255 attempts executed, complete and passing, with no unavailable
artifacts. Earlier failures remain retained.
