# Runtime candidate006 full Go by Example replay

Sprint: #118; Story: #3; Story-ID: `fa07603b71dc`.

The complete replay remains failing: all 255 attempts executed, with no missing
or unavailable mode. All 85 unchanged originals pass as transpiled native
artifacts; 56 still fail in the interpreter. The
[complete ledger](sprint118-candidate006-ledger.tsv) records every outcome.

| Mode | Pass | Output/status mismatch | Normalization rejected | Unavailable |
|---|---:|---:|---:|---:|
| Native Go oracle | 85 | 0 | 0 | 0 |
| Bash++ interpreter | 29 | 46 | 10 | 0 |
| Transpiled artifact | 85 | 0 | 0 | 0 |

All 27 interpreter passes from candidate005 are retained. Two more pass:
`environment-variables` with the product's exact caller environment fix, and
`closing-channels` with the independently reviewed
[source-derived order contract](closing-channels-order.md). The latter is a
classification correction and is not presented as a runtime improvement.
Historical candidate005 evidence remains unchanged under its original v5
contract. No other comparator changed. No source bytes were edited.

All compiled attempts pass strict source-map validation, real SDK build,
actual artifact execution and the declared output/status/effect comparisons.
The original `_test.go` also passes in compiled mode with the separately
retained testing driver. This does not certify the interpreter, all Go programs,
or sprint completion.

## Authenticated inputs and retained evidence

Manager-authorized manifest:
`b4cf7401f24a3d57110c4e4f02c62242c435846344b54af8dc915401c5e97df4`.
Payload: `6778f33158c91adfb24b9cbbbb09525adfe0874d3679a77cfa543538334261a6`.
The exact row in [candidates.tsv](candidates.tsv) retains all earlier candidates.
Independent authentication checks the launcher plus adjacent payload, all five
clean runtime revisions, and the pinned Go 1.27.0 darwin/arm64 SDK. The sh
revision is `194d246ebc67d122c0e0f9a028302c5df3dd48bf`; bashy is
`e6a730d2d9c2359e547cf2e5ab2d8fd288c155ff`. Normalizer version 6 and its code,
schema and source inventory digests are bound into every attempt.

Durable base:
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-006/gbe`.

- `results.jsonl.fail` contains all 255 attempts and the complete failing summary.
- `results.jsonl.work` retains independent original inputs and runtime roots,
  per-phase argv/cwd/environment/deadlines, source/generated/map/SDK/artifact
  digests, raw streams and actual native binaries.
- `taxonomy/taxonomy.json` contains complete grouped counts;
  `taxonomy/failures.jsonl` retains all 56 failures with exact diagnostics and
  capture bindings; `taxonomy/ledger.tsv` is the complete 255-row ledger.
- `replay.sh` and `replay.log` retain the uncapped invocation and all row reports.

The independently anchored root is
`725648b9f5525a7f6a1f48eac7aa62fe467d3db93dfad3351275b1111c0b7395`
in [evidence-roots.tsv](evidence-roots.tsv). All 89 original corpus files remain
intact. No filesystem-effect failure, deadline, process leak, missing artifact
or unavailable mode occurred. Supported telemetry opt-outs were configured and
recorded identically before each runtime baseline; effects were not erased.

## Remaining interpreter failure families

The retained taxonomy preserves observed verdicts. Its diagnostic group names
are for triage; `program-diagnostic` intentionally remains broad rather than
claiming a root cause from a partial error string. Concrete next fixes are:

1. **Collections and scalar/native transfer:** string-to-`[]byte` in base64,
   directories, regular expressions and hashing; native byte-slice values in
   embed, JSON, reading-files and process output; nil slices; composite values;
   named map keys; native pointer fields such as `http.Response.Body`.
2. **Callable values and generics:** function literals in atomic counters,
   mutexes and recursion; local handlers in HTTP server/context; imported
   `errors.AsType`, `slices.Sort` and `SortFunc`; generic local `element` types;
   the original testing example's separate `gbeMatchString` driver callback.
3. **Native identity, methods and call results:** local `rect`, `point`, `person`
   and other named values; address expressions; native pointer dereference;
   tuple assignment from `filepath.Rel` and template calls; native methods such
   as `TCPListener.Close` and `os.File.Write`; variadic expansion.
4. **Channels and task state:** native timer/ticker/context channels, limiter
   handles, channel struct fields, worker groups and typed selection. An
   otherwise successful select run still differs in observable output.
5. **Panic and recovery:** `panic.go` exits 2 with empty stderr, omitting the
   native panic message. `recover.go` exits 2 with no output instead of
   recovering and exiting 0. Both oracle and compiled artifacts pass.
6. **Other observable semantics:** the logging interpreter reports
   `value.go:586` rather than original `logging.go:40` before a later address
   error; type-switch interface storage and time/URL/native selectors also fail.

Ten normalization rejections are preserved as failures, mostly after earlier
interpreter errors or missing expected output. They are not justification for
loosening the remaining comparators. Every exact first diagnostic is available
in the retained failure records for targeted reproduction.

## Independent checks

```sh
bash tools/go-by-example/validate.sh
ruby tests/go-by-example/closing_channels_order_test.rb
ruby tests/go-by-example/gate_contract_test.rb
ruby tools/go-by-example/validate-evidence.rb /Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-006/gbe/results.jsonl.fail
ruby tools/go-by-example/tamper-retained-evidence.rb /Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-006/gbe/results.jsonl.fail
```

The closing-channel tests passed 4 tests and 59 assertions, including exhaustive
comparison of all 362,880 event permutations against the independent 42-trace
channel model. Existing gate contract tests passed 11 tests and 61 assertions,
without skips. The retained validator authenticates this **failing** complete
chain. Five adversarial changes are rejected: duplicate streams, raw-output
substitution, artifact digest, telemetry-file digest and telemetry command.
