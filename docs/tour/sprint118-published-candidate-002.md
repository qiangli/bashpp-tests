# Sprint 118: published candidate 002, full Tour replay

**Sprint acceptance remains FAIL.** All 97 native Go and 97 compiled Bash++
observations pass. Interpreted Bash++ passes 39 and fails 58. No applicable
program was excluded or rewritten. The denominator is 93 runnable programs
plus four build-only programs, each checked in all three modes: 291 observations.
The ten volatile rows have seven fresh native oracle repeats each (70 total).

| Mode | PASS | FAIL |
| --- | ---: | ---: |
| Native Go | 97 | 0 |
| Interpreted Bash++ | 39 | 58 |
| Compiled Bash++ | 97 | 0 |

The corrected independent gate reports 58 `not_pass` findings and the expected
failing overall verdict, with no provenance, source, artifact, or semantic
audit failures. Original source hashes and all candidate repositories were
verified before and after execution. All modes used `GOMAXPROCS=2`.

## Evidence and provenance

- Candidate manifest: `/Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/candidate.json`
- Payload SHA-256: `e9a8a66ca1adbcbc614ab0f0dc9e6ea8d5590cb23e66ce7a8bdc74dab3becce3`
- Candidate manifest SHA-256: `ddf233e89c2839f299c14010c3d2ca8fba4ffb23e8835b86bd5ae0b6811f9aff`
- Ledger SHA-256: `77a6c61ea4b8a9e45667e9ece0be1a0834d7385793553f2d3f98c6a18253f4cc`
- Ledger root: `d549d6ae42c44ddb067908464054e7bd2ab835130081db83b117bbf6c23e1d54`
- Runtime source revision: `23ab881905b118ab8366c161a57f10b730b78276`
- Durable raw logs, artifacts, gate report, and analysis: `/Users/qiangli/.local/state/bashy/sprint118-evidence/published-candidate-002/tour/replay-002`
- [Complete captured ledger](../../tests/tour/executor-results.jsonl)
- [Exact failures, commands, source hashes, stdout and stderr](../../tests/tour/published-candidate-002-failures.json)
- The unchanged source archive and its SHA-256 table are preserved next to the
  replay directories under `published-candidate-002/tour/source-corpus`.

Replay 001 is retained in its separate durable directory. Its 31 compiled
failures were caused by the synthetic module lacking the generated compiler
runtime dependency. The harness now binds `mvdan.cc/sh/v3` to the authenticated
candidate's exact `sh` source revision. Replay 002 reran the complete denominator
and resolved all 31 failures. No source transformation or comparison weakening
was used. The runtime-dependency change passed 101 executor selftests; the
reviewed semantic comparators passed 151 selftests.

## Runtime work queues

These families classify the first observed failure; they are not proof that
one fix resolves every downstream issue. Work on the type/value representation
and collection consumers should proceed alongside bridge transport and callback
support, with explicit ownership of shared interpreter files. Channel/task
argument handling and generic/closure invocation have distinct reproductions.
The single complex-number case remains an explicit obligation.

| Family | Failing programs | First unchanged reproducer |
| --- | ---: | --- |
| Type declarations, selectors, pointers, interfaces | 20 | [concurrency/exercise-web-crawler.go](../../tour/_content/tour/concurrency/exercise-web-crawler.go) |
| Bridge values and native handles | 13 | [methods/exercise-errors.go](../../tour/_content/tour/methods/exercise-errors.go) |
| Collections and scalar expressions | 13 | [methods/methods-funcs.go](../../tour/_content/tour/methods/methods-funcs.go) |
| Functions, callbacks, generics | 6 | [generics/index.go](../../tour/_content/tour/generics/index.go) |
| Channels and task arguments | 5 | [concurrency/buffered-channels.go](../../tour/_content/tour/concurrency/buffered-channels.go) |
| Complex scalars | 1 | [basics/basic-types.go](../../tour/_content/tour/basics/basic-types.go) |

## Exact first diagnostics

| Source | Family | First diagnostic |
| --- | --- | --- |
| [basics/basic-types.go](../../tour/_content/tour/basics/basic-types.go) | Complex scalars | `_content/tour/basics/basic-types.go:13:9: BASHPP-ECOMPLEX-UNSUPPORTED: complex values are not supported by the Bash++ scalar carrier` |
| [concurrency/buffered-channels.go](../../tour/_content/tour/concurrency/buffered-channels.go) | Channels and task arguments | `_content/tour/concurrency/buffered-channels.go:11:14: BASHPP-EEXPR-OPERAND: unsupported unary operator ILLEGAL` |
| [concurrency/channels.go](../../tour/_content/tour/concurrency/channels.go) | Channels and task arguments | `bash++: cannot send "sum" as int channel value` |
| [concurrency/default-selection.go](../../tour/_content/tour/concurrency/default-selection.go) | Channels and task arguments | `bash++: tick is not a channel in this task group` |
| [concurrency/exercise-web-crawler.go](../../tour/_content/tour/concurrency/exercise-web-crawler.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/concurrency/exercise-web-crawler.go:41:1: undefined type: fakeResult` |
| [concurrency/mutex-counter.go](../../tour/_content/tour/concurrency/mutex-counter.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/concurrency/mutex-counter.go:12:1: undefined type: __gosource_import_0_1.Mutex` |
| [concurrency/range-and-close.go](../../tour/_content/tour/concurrency/range-and-close.go) | Channels and task arguments | `fibonacci: cannot use "cap(c)" as int value for parameter n` |
| [concurrency/select.go](../../tour/_content/tour/concurrency/select.go) | Channels and task arguments | `bash++: cannot send "x" as int channel value` |
| [flowcontrol/switch.go](../../tour/_content/tour/flowcontrol/switch.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ESELECTOR-ROOT: __gosource_import_0_1 is not a structured value` |
| [generics/index.go](../../tour/_content/tour/generics/index.go) | Functions, callbacks, generics | `BASHPP-EGENERIC-INFER: cannot infer type arguments for Index` |
| [generics/list.go](../../tour/_content/tour/generics/list.go) | Functions, callbacks, generics | `_content/tour/generics/list.go:7:1: undefined type: T` |
| [methods/empty-interface.go](../../tour/_content/tour/methods/empty-interface.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/methods/empty-interface.go:11:2: BASHPP-EASSIGN-TYPE: untyped result is not assignable to interface` |
| [methods/errors.go](../../tour/_content/tour/methods/errors.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/methods/errors.go:10:1: undefined type: __gosource_import_0_1.Time` |
| [methods/exercise-errors.go](../../tour/_content/tour/methods/exercise-errors.go) | Bridge values and native handles | `unregistered bridge type "error"` |
| [methods/exercise-stringer.go](../../tour/_content/tour/methods/exercise-stringer.go) | Bridge values and native handles | `unregistered bridge type "IPAddr"` |
| [methods/indirection-values.go](../../tour/_content/tour/methods/indirection-values.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/methods/indirection-values.go:15:19: BASHPP-ESELECTOR-UNKNOWN: Vertex has no field or method "X"` |
| [methods/indirection.go](../../tour/_content/tour/methods/indirection.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ESELECTOR-UNKNOWN: Vertex has no field or method "X"` |
| [methods/interface-values-with-nil.go](../../tour/_content/tour/methods/interface-values-with-nil.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/methods/interface-values-with-nil.go:27:2: BASHPP-EASSIGN-TYPE: cannot assign *T to I` |
| [methods/interface-values.go](../../tour/_content/tour/methods/interface-values.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/methods/interface-values.go:31:6: _content/tour/methods/interface-values.go:31:6: BASHPP-EEXPR-FORM: unsupported scalar expression *syntax.BashPPAddressExpr` |
| [methods/interfaces-are-satisfied-implicitly.go](../../tour/_content/tour/methods/interfaces-are-satisfied-implicitly.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-EINTERFACE-VALUE: interface assignment requires a named value` |
| [methods/methods-continued.go](../../tour/_content/tour/methods/methods-continued.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ESELECTOR-TYPE: local f has no typed selector path` |
| [methods/methods-funcs.go](../../tour/_content/tour/methods/methods-funcs.go) | Collections and scalar expressions | `_content/tour/methods/methods-funcs.go:20:18: BASHPP-EEXPR-OPERAND: v is not a scalar` |
| [methods/methods-pointers-explained.go](../../tour/_content/tour/methods/methods-pointers-explained.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ENIL-DEREF: dereference of nil pointer` |
| [methods/methods-pointers.go](../../tour/_content/tour/methods/methods-pointers.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ESELECTOR-UNKNOWN: Vertex has no field or method "X"` |
| [methods/methods-with-pointer-receivers.go](../../tour/_content/tour/methods/methods-with-pointer-receivers.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ENONADDRESSABLE: operand is not addressable` |
| [methods/methods.go](../../tour/_content/tour/methods/methods.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/methods/methods.go:15:19: BASHPP-ESELECTOR-UNKNOWN: Vertex has no field or method "X"` |
| [methods/reader.go](../../tour/_content/tour/methods/reader.go) | Bridge values and native handles | `integer for uint8` |
| [methods/stringer.go](../../tour/_content/tour/methods/stringer.go) | Bridge values and native handles | `unregistered bridge type "Person"` |
| [methods/type-switches.go](../../tour/_content/tour/methods/type-switches.go) | Type declarations, selectors, pointers, interfaces | `BASHPP-ETYPESWITCH-OPERAND: i is not an interface` |
| [moretypes/append.go](../../tour/_content/tour/moretypes/append.go) | Collections and scalar expressions | `_content/tour/moretypes/append.go:25:51: gosource: unsupported interpreter collection value <nil>` |
| [moretypes/exercise-maps.go](../../tour/_content/tour/moretypes/exercise-maps.go) | Functions, callbacks, generics | `_content/tour/moretypes/exercise-maps.go:14:10: BASHPP-EEXPR-UNDEFINED: undefined: WordCount` |
| [moretypes/function-closures.go](../../tour/_content/tour/moretypes/function-closures.go) | Functions, callbacks, generics | `_content/tour/moretypes/function-closures.go:19:4: BASHPP-EEXPR-UNDEFINED: undefined callable pos` |
| [moretypes/function-values.go](../../tour/_content/tour/moretypes/function-values.go) | Bridge values and native handles | `_content/tour/moretypes/function-values.go:21:22: gosource: native handle (func(float64, float64) float64) is not scalar` |
| [moretypes/making-slices.go](../../tour/_content/tour/moretypes/making-slices.go) | Collections and scalar expressions | `_content/tour/moretypes/making-slices.go:23:22: gosource: unsupported interpreter collection value <nil>` |
| [moretypes/map-literals-continued.go](../../tour/_content/tour/moretypes/map-literals-continued.go) | Collections and scalar expressions | `BASHPP-ECOLLECTION-ELEMENT: cannot use string value as float64` |
| [moretypes/map-literals.go](../../tour/_content/tour/moretypes/map-literals.go) | Collections and scalar expressions | `BASHPP-ECOLLECTION-ELEMENT: cannot use string value as float64` |
| [moretypes/maps.go](../../tour/_content/tour/moretypes/maps.go) | Collections and scalar expressions | `_content/tour/moretypes/maps.go:14:6: BASHPP-EASSIGN-CALL: tuple assignment requires a declared result-bearing function` |
| [moretypes/mutating-maps.go](../../tour/_content/tour/moretypes/mutating-maps.go) | Collections and scalar expressions | `assignment mismatch: 2 variable(s) but 1 value(s)` |
| [moretypes/nil-slices.go](../../tour/_content/tour/moretypes/nil-slices.go) | Collections and scalar expressions | `_content/tour/moretypes/nil-slices.go:9:14: gosource: unsupported interpreter collection value <nil>` |
| [moretypes/pointers.go](../../tour/_content/tour/moretypes/pointers.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/moretypes/pointers.go:15:6: _content/tour/moretypes/pointers.go:15:6: BASHPP-EEXPR-FORM: unsupported scalar expression *syntax.BashPPAddressExpr` |
| [moretypes/slice-bounds.go](../../tour/_content/tour/moretypes/slice-bounds.go) | Collections and scalar expressions | `_content/tour/moretypes/slice-bounds.go:10:6: _content/tour/moretypes/slice-bounds.go:10:6: BASHPP-EEXPR-FORM: unsupported scalar expression *syntax.BashPPSliceExpr` |
| [moretypes/slice-len-cap.go](../../tour/_content/tour/moretypes/slice-len-cap.go) | Collections and scalar expressions | `_content/tour/moretypes/slice-len-cap.go:12:6: _content/tour/moretypes/slice-len-cap.go:12:6: BASHPP-EEXPR-FORM: unsupported scalar expression *syntax.BashPPSliceExpr` |
| [moretypes/slice-literals.go](../../tour/_content/tour/moretypes/slice-literals.go) | Bridge values and native handles | `unregistered bridge type "[]struct{i int;b bool}"` |
| [moretypes/slices-of-slice.go](../../tour/_content/tour/moretypes/slices-of-slice.go) | Collections and scalar expressions | `_content/tour/moretypes/slices-of-slice.go:26:35: BASHPP-EEXPR-OPERAND: indexed value is not a scalar` |
| [moretypes/struct-literals.go](../../tour/_content/tour/moretypes/struct-literals.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/moretypes/struct-literals.go:13:14: BASHPP-ESTRUCT-UNKNOWN: Vertex has no field selector "X"` |
| [moretypes/struct-pointers.go](../../tour/_content/tour/moretypes/struct-pointers.go) | Collections and scalar expressions | `BASHPP-EASSIGN-MISMATCH: BASHPP-ECOLLECTION-ELEMENT: cannot use float64 value as int` |
| [moretypes/structs.go](../../tour/_content/tour/moretypes/structs.go) | Bridge values and native handles | `unregistered bridge type "Vertex"` |
| [solutions/binarytrees.go](../../tour/_content/tour/solutions/binarytrees.go) | Bridge values and native handles | `_content/tour/solutions/binarytrees.go:56:10: gosource: native handle (*tree.Tree) is not scalar` |
| [solutions/binarytrees_quit.go](../../tour/_content/tour/solutions/binarytrees_quit.go) | Bridge values and native handles | `_content/tour/solutions/binarytrees_quit.go:60:10: gosource: native handle (*tree.Tree) is not scalar` |
| [solutions/errors.go](../../tour/_content/tour/solutions/errors.go) | Bridge values and native handles | `unregistered bridge type "error"` |
| [solutions/image.go](../../tour/_content/tour/solutions/image.go) | Bridge values and native handles | `unregistered bridge type "Image"` |
| [solutions/loops.go](../../tour/_content/tour/solutions/loops.go) | Collections and scalar expressions | `_content/tour/solutions/loops.go:28:28: BASHPP-EEXPR-OPERAND: operator - not defined on String and String` |
| [solutions/maps.go](../../tour/_content/tour/solutions/maps.go) | Functions, callbacks, generics | `_content/tour/solutions/maps.go:24:10: BASHPP-EEXPR-UNDEFINED: undefined: WordCount` |
| [solutions/readers.go](../../tour/_content/tour/solutions/readers.go) | Bridge values and native handles | `unregistered bridge type "MyReader"` |
| [solutions/rot13.go](../../tour/_content/tour/solutions/rot13.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/solutions/rot13.go:28:1: undefined type: __gosource_import_0_0.Reader` |
| [solutions/slices.go](../../tour/_content/tour/solutions/slices.go) | Functions, callbacks, generics | `_content/tour/solutions/slices.go:27:11: BASHPP-EEXPR-UNDEFINED: undefined: Pic` |
| [solutions/stringers.go](../../tour/_content/tour/solutions/stringers.go) | Bridge values and native handles | `unregistered bridge type "IPAddr"` |
| [solutions/webcrawler.go](../../tour/_content/tour/solutions/webcrawler.go) | Type declarations, selectors, pointers, interfaces | `_content/tour/solutions/webcrawler.go:91:1: undefined type: fakeResult` |

Fresh acceptance must use the next frozen candidate and a new evidence directory
with all 97 programs and seven native repeats. Focused reproductions can guide
runtime fixes, but cannot replace that full replay.
