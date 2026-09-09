# Interpreter-owned standard-library test driver

Sprint #118, story #16 (`82a8a7687fec`). This is an implementation contract,
not an execution result. The native oracle and fixture cache do not execute
any original test body through Bash++.

## Ownership and inputs

The authenticated inventory retains all 180 reviewed packages, the 178
host-exposed package roots, the two policy refusals, and every original test
file. Applicable test files must be selected by the pinned SDK's actual build
constraints, with the selected and unselected files both recorded. Runtime
test registrations and terminals form a separate denominator; source-file
counts cannot stand in for tests.

For a selected package, load its unchanged `_test.go` source, companion files,
package globals, methods, initialization, and original file positions into the
Go-source interpreter. In-package tests additionally require the tested
package's source graph and test-only exports in the same interpreter scope.
Black-box tests use their actual separate package identity. Resolve internal
imports from that source graph without weakening Go visibility rules.

A native harness may own the reviewed `testing` scheduler and dependency
transport. It must not contain, compile, import as executable callbacks, or
forward the original test bodies. Its callbacks contain only protocol calls
that invoke identified interpreter functions. Native execution of a tested
standard-library dependency is counted as a bridge call, with zero credit for
interpreting that dependency's implementation. In-package interpreter coverage
cannot be substituted with an imported native package.

## Concrete first slice

The first diagnostic slice is `errors/errors_test.go`:
`TestNewEqual(*testing.T)` and `TestErrorMethod(*testing.T)`. Both original
bodies remain byte-for-byte unchanged. The machine-readable
[test-body-first-slice.json](test-body-first-slice.json) pins every selected
original companion file and the two registration positions. This pair exercises native error
allocation identity, repeated-handle equality, method dispatch, and the
failure-reporting callback through `testing.T.Errorf`.

Load and account for the actual `errors_test` package companions and imports;
register these two descriptors as a named discovery slice. Retain every other
package/test obligation as unexecuted, never successful or excluded. Match
against those exact test names in the independently authenticated native
`errors` package oracle. Whole-package completion requires every applicable
registration and any dynamically registered subtests.

Even this two-test slice is blocked until function callbacks, `*testing.T`
handle ownership, and reentrant call dispatch are implemented and verified.
Current native-only bridge invocation cannot satisfy it. The full inventory
must accompany any future two-test report, with an explicit slice identifier
and no whole-corpus PASS.

## Harness and callback protocol

The pinned `src/testing/testing.go:2428` exports:

```go
func Main(matchString func(pat, str string) (bool, error),
    tests []InternalTest, benchmarks []InternalBenchmark,
    examples []InternalExample)
```

A dedicated native harness can register `testing.InternalTest` descriptors
whose `F` callbacks call the interpreter over an authenticated session. A
fixed adapter may import `testing` and `regexp`; it must not embed test bodies
or import a compiled version of the source-under-test package to execute them.
`testing.Main` calls `os.Exit`, so it owns a dedicated process lifetime. It
cannot safely run inside the reusable dependency bridge process.

Each invocation needs at least:

| Field | Meaning |
|---|---|
| session / invocation / parent IDs | Bind handles, callbacks, nested tests, and terminal events |
| package and source-function identity | Original package, file digest, declaration position, function name |
| task identity | Interpreter task executing the body and its defers |
| typed argument handles | Session-scoped `*testing.T` or later `*testing.B` capabilities |
| request and sequence IDs | Reentrant dependency calls and ordered output |
| terminal disposition | Return, assertion failure, fail-now, skip-now, panic, cancellation |

The native callback suspends its `testing` goroutine while the original body
runs in the interpreter. Calls on `t` must route back to that specific native
testing goroutine. A single request/response lock held across the callback
would deadlock when the body calls `t.Errorf` or another dependency. The
transport must multiplex callback requests, method calls, acknowledgements,
ordered output, and cancellation.

A callback return is successful only when the interpreter reached its own
terminal state and the native scheduler confirms that test's terminal result.
A native process exit, an unvisited body, a missing callback acknowledgement,
or a successful dependency call cannot supply that confirmation.

## Control flow and lifecycle

`testing.T.FailNow` uses `runtime.Goexit` (pinned `testing.go:1080`), not a
regular return. Calling it in an unrelated bridge request goroutine would
terminate the wrong goroutine and can leave the protocol unanswered. Instead,
return an explicit control disposition to the interpreter task, run its Go
`defer` stack, and then ask the owning native callback goroutine to perform
the matching scheduler operation. Apply the corresponding rule to
`SkipNow`, `Fatal`, and `Skip`. Record the original source callsite and exact
message; do not invent an applicability exception.

`T.Run` creates child invocation IDs and reentrant callbacks. `T.Parallel`
must preserve the scheduler's parent/child barriers rather than starting
unmanaged interpreter goroutines. `T.Cleanup` registers callbacks that remain
valid after the body returns and run in the required order. Context deadlines,
panics, process failure, and cancellation must finish or explicitly fail all
outstanding body, subtest, and cleanup obligations. Close a session only after
its callbacks and output have drained. Reject stale handles, including handles
nested in map keys, map values, slices, and structs.

Callbacks must preserve ordinary Go panic/defer behavior and task identity.
A native dependency is not allowed to hide an interpreter failure by returning
success. Runner Reset and subshell creation require explicit session ownership;
a child reset cannot close the parent's live native test scheduler.

## Streams, examples, and larger harnesses

Preserve source-level `os.Args`, environment, cwd, and dependency initialization
before any body executes. Transport credentials do not belong in program argv.
Separate control messages from stdout/stderr. Route writes to the correct
active test or example, retain their order and bytes, and bind them to callback
and process IDs. Native `testing` example capture redirects its own stdout;
writes from a separate interpreter or dependency process do not automatically
enter that capture. Examples remain unsupported until that routing is proven.

The legacy `testing.Main` adapter supplies no fuzz targets and its
`matchStringOnly` implementation returns errors for profiling and fuzz-worker
operations. It also does not expose an `*testing.M` to the original
`TestMain`. `TestMain`, fuzzing, coverage/profiling, and later benchmark support
therefore require an explicit extended driver using the real `MainStart`
dependency contract, or an interpreter-owned equivalent. Record these phase
obligations; never omit their tests or label an unsupported harness successful.
Go's internal-package rules require a reviewed package graph or an in-tree
native adapter for internal harness dependencies. That is an implementation
constraint, not proof that a hand-generated testmain is impossible.

## Acceptance evidence

Every result must bind the original source hashes, applicable package graph,
SDK and product identity, generated adapter hash, exact commands/environment,
native baseline, callback start/terminal events, and raw streams. Assertions
inside the original bodies must execute through the interpreter. Record
which operations crossed into native dependencies separately.

Before advancing beyond the first slice, verify a passing body and an
independent deliberately failing harness fixture; fail-now/skip-now defers;
nested subtests and cleanup order; parent/child cancellation; stale nested
handles; output ordering; and session Reset isolation. Harness self-tests may
be authored separately. The original upstream test bodies must never be
modified to make those checks pass.

A missing adapter yields a named FAIL for its execution phase. Native oracle
PASS establishes the baseline only. Full product standard-library closure needs the driver implementation and
its actual interpreter execution evidence, not this contract alone. Story #16
can deliver the scoped native oracle and this contract; parent
`6f0c4d9a31be` retains the product execution obligation.

## Current interpreter loading proof

The authenticated published candidate002 (sh commit `23ab8819`, payload
SHA-256 `e9a8a66ca1adbcbc614ab0f0dc9e6ea8d5590cb23e66ce7a8bdc74dab3becce3`)
was invoked directly on the original SDK `src/errors/errors_test.go` with
`--bashpp --source=go`. It exited **2**, reporting
`Go execution requires package main with func main()`. The original file
remained 765 bytes with SHA-256
`7827d7e3ab7cc317a254ccf76158069b80c5b55b34ca45a3e6d799ad185f70ea`.

Exact commands, environment, candidate identity, and raw streams are retained
at `/Users/qiangli/.bashy/sprint118/evidence/stdlib-testbody-load-proof-001`.
This is an actual failing non-main loading proof, not an execution of the two
test bodies. It establishes the first implementation boundary before callback
transport and testing.T lifecycle can be exercised.
