# Sprint 118 candidate022 Go-by-Example replay

Candidate022 is the runtime candidate frozen after the post-candidate021
interpreted fixes. It uses `sh`
`69579ce6a96a53918bbe05214d77c32d5135c516` and `bashy`
`67886176d8a50c555714e97a96ce57ee4835479f`. Its manifest is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/candidate.json`
with SHA-256
`5e336da824fc062d07c0428ae6a7e4b8c6ec8ac6ac56bd14312bdf1157d72eb9`.

## What was frozen

The frozen tree is `/private/tmp/s118-runtime-022`, built once with the
recipe recorded in the manifest and then made read-only: every tracked file of
the `bashy` and `sh` clones, and both installed artifacts
(`bin/bashy`, `bin/bashy.real`), carry no write bit. The freeze record is
`runtime-integration-022/freeze.json`. Nothing in that tree was modified after
the build; registration happened here, in `candidates.tsv`, not there.

The story text named the post-candidate fixes as reaching `sh` `f1ed249d`
(`new(T)` short declarations, variadic collection binding, named scalar map
keys, and generic slice equality/sort). The freeze is taken one code commit
later, at `sh` `69579ce6`, because `7c4e5260` ("interp: preserve Go numeric
slice semantics") is the follow-up correction to that same
`interp/bashpp_native_slices.go` work and because `bashy` `.sibling-pins` at
`67886176` pins `sh` `69579ce6` — freezing `bashy` `ca1e6a0`/`sh` `f1ed249d`
would have been the only self-consistent alternative, and it omits a fix from
the named set's own subsystem. All four named fixes are contained in the
freeze.

`tools/go-by-example/validate-candidate.rb`, which shares no state with a gate
run, re-derived the whole binding from `candidates.tsv` and passed: launcher
`454c25a8`, payload `335aa2c6`, front end `gosource-v1`, the pinned
`go1.27.0 darwin/arm64` SDK, and all five runtime repositories clean at their
exact declared revisions.

## The replay

All 255 required observations were recorded, over all 85 rows in all three
modes, with port 8090 owned exclusively by this run (checked free before the
gate started, and no other gate was running).

- oracle: 85 pass
- compiled: 83 pass, 1 mismatch failure, 1 unspawned (`fail_incomplete`)
- interpreted: 59 pass, 22 mismatch failures, 4 normalization failures
- attempt records: 255; executed: 254; missing or unspawned: 1

The retained evidence is
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-022/gbe-full.jsonl.fail`.
Its file SHA-256 is
`8b3b991a484c51fd0ff77b137a6144f0cf2a8814258a711c2ac2a13fafab9634`
and its authenticated root digest is
`63cf7bf7a735959d66434eedb4c5ed431df19669289a05f127fb08d23605f8df`.
`tools/go-by-example/validate-evidence.rb` independently reconstructed the
255-attempt denominator, the verdicts and the root, and passed after the root
was added to `evidence-roots.tsv`. The per-attempt ledger is
[`sprint118-candidate022-ledger.tsv`](sprint118-candidate022-ledger.tsv); the
full taxonomy and every failing attempt's decoded streams are retained beside
the evidence in `runtime-integration-022/gbe-summary/`.

## What moved against candidate021

Exactly four rows changed verdict. Nothing else in the 255 moved.

| row | mode | 021 | 022 |
|---|---|---|---|
| `examples/enums/enums.go` | interpreted | `fail_mismatch` | **pass** |
| `examples/slices/slices.go` | interpreted | `fail_mismatch` | **pass** |
| `examples/json/json.go` | compiled | pass | `fail_mismatch` |
| `examples/pointers/pointers.go` | compiled | pass | `fail_incomplete` |

Interpreted mode gained two rows, 57 -> 59. Compiled mode lost two, 85 -> 83.
This candidate is therefore **not** an unambiguous advance on candidate021, and
candidate021 remains the accepted stable baseline until the compiled column is
back at 85. The two compiled losses have different causes, and only one of them
is a product regression.

### Compiled regression — `new(<value>)` no longer transpiles

`examples/pointers/pointers.go` line 45 is `p := new(42)`. Go 1.26 widened the
`new` builtin to accept a value expression, and the pinned Go 1.27 oracle
compiles and runs it, printing `value at *p: 42`. Under candidate022 the
transpile stage now exits 2:

```console
$ bashy transpile --bashpp --source=go pointers.go -o gen.go --map gen.go.map
pointers.go:45:11: gosource: unsupported type *ast.BasicLit
```

With no generated Go there is no artifact, so the compiled run stage is
recorded `unspawned` and the attempt is `fail_incomplete` — this is the single
missing observation in the 255.

The cause is the `new` special case added by `sh` `47cce082` ("gosource:
convert new(T) short declarations") in `gosource/convert.go`. Its short-decl
branch fires for *every* `new(...)` call on the right-hand side of `:=` and
routes it through `c.expr(rhs)`, which treats the argument as a type. For
`new(Vertex)` that is right and is what the commit fixed; for `new(42)` the
argument is a value, and the conversion fails. Candidate021 had no such branch,
so `new(42)` fell through to the generic call path and compiled correctly.

Reduced to two lines, and measured against both frozen candidates:

```go
p := new(42)   // candidate021: transpiles.  candidate022: unsupported type *ast.BasicLit
q := new(int)  // both: transpiles
```

The indicated remedy is to restrict the new branch to a type argument, so a
value argument falls through to the path that already worked:

```go
if obj, ok := c.info.Uses[id].(*types.Builtin); ok && obj.Name() == "new" &&
    len(rhs.Args) == 1 && c.info.Types[rhs.Args[0]].IsType() {
```

This was verified, not asserted. A scratch clone of `sh` `69579ce6` carrying
only that guard, built with the same recipe against `bashy` `67886176`,
transpiles `pointers.go`; the generated Go builds against the lowering runtime
and prints the oracle's bytes exactly, including `value at *p: 42` and
`value at *p: 0`. The interpreted verdict for the row is unchanged by the
guard — it still fails with `BASHPP-EBUILTIN-TYPE: new requires exactly one
type argument and is only a value expression`, which is the same interpreted
gap candidate021 recorded. The probe was built and run outside both frozen
trees and outside every tracked repository; no product change is registered
here.

### Not a regression — `examples/json/json.go` is misclassified

The compiled `json` failure is one line of a fifteen-line stream:

```
oracle    {"apple":5,"lettuce":7}
compiled  {"lettuce":7,"apple":5}
```

That line is `json.MarshalWrite(&buf, d)` over `map[string]int{"apple": 5,
"lettuce": 7}`, and under `encoding/json/v2` it is emitted in Go **map
iteration order**. The pinned oracle is itself nondeterministic here. Running
the retained candidate022 artifacts from `gbe-full.jsonl.work/034` 40 times
each:

| binary | line | `{"apple":5,...}` | `{"lettuce":7,...}` |
|---|---|---|---|
| oracle | 6 (`json.Marshal`) | 35 | 5 |
| oracle | 14 (`json.MarshalWrite`) | 34 | 6 |
| compiled | 14 (`json.MarshalWrite`) | 33 | 7 |

Both of the row's map-encoding lines are order-dependent on both sides.
`classification.tsv` line 52 nevertheless declares the row
`deterministic / none / none`, which under the schema means raw byte comparison
with no adapter and no normalization. So this row has never been a measurement:
every verdict it has produced in every anchored chain — including candidate021's
compiled pass, and the candidate020 "order-sensitive" mismatch that the
candidate021 record describes as resolved — was a coin flip on two independent
two-key maps. Candidate021 got heads; candidate022 got tails.

The row needs the same treatment `examples/range-over-built-in-types` already
has: behavior `map_iteration` with the licensed `map_order` normalization. That
is a schema decision, and this run does not take it — retyping a corpus row
changes `classification_sha256` and `corpus_sha256`, which would invalidate the
anchored candidate021 and candidate022 chains along with every earlier root.
The finding is recorded here so the decision is made deliberately, with the
re-baselining that follows from it, rather than absorbed into a candidate
comparison. Until it is made, `examples/json/json.go` should not be read as
evidence for or against any candidate in either product mode.

## Remaining interpreted failures

26 of the 28 remaining interpreted failures are unchanged from candidate021;
`enums` and `slices` left the list and nothing joined it. Grouped by the
diagnostic family the taxonomy derives:

| family | count | rows |
|---|---|---|
| `program-diagnostic` | 15 | command-line-flags, command-line-subcommands, context, directories, http-server, json, logging, maps, panic, pointers, regular-expressions, sorting-by-functions, sorting, variadic-functions, xml |
| `generic-method-receiver` | 2 | generics, range-over-iterators |
| `comparator-shape-or-prior-error` | 2 | stateful-goroutines, testing-and-benchmarking |
| `output-or-status-mismatch` | 2 | embed-directive, signals |
| `aggregate-composite-expression` | 1 | errors |
| `callback-or-callable-value` | 1 | time |
| `imported-aggregate-selector` | 1 | strings-and-runes |
| `multiple-assignment-or-tuple` | 1 | spawning-processes |
| `native-argument-type-identity` | 1 | recursion |

`examples/json/json.go` appears in that list, and its interpreted failure is
real independent of the classification defect above: the run stops at
`gosource: native slice retention or mutation is unsupported for
encoding/json/v2.Unmarshal` after eight of fifteen lines.

Story `fa07603b71dc` stays open. The interpreted column is 59/85, the compiled
column has one product regression to reverse and one misclassified row to
decide, and no row has been retired, excepted, or normalized into agreement.
