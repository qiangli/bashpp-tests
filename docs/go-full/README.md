# Full official Go source and recipe inventory

This is an **inventory, not an execution result**. It binds every input to the
reviewed Go 1.27.0 source archive and retains the complete upstream root sets.
It does not claim Bash++ parity, native oracle success, or a completed sprint.
The bounded 35-case Go oracle remains a separate earlier gate.

Run from the bashpp-tests repository:

```sh
python3 tools/go-full/inventory.py materialize
python3 tools/go-full/inventory.py validate
python3 tests/go-full/test_inventory.py
```

`materialize` downloads the official source archive, verifies its SHA-256 against
`docs/go-corpus/pin.tsv`, and materializes `.cache/go-full/go`. An existing source
tree must match **all 15,615 archive files**, including membership; this command
refuses to repair a modified tree silently. It does not execute source code.
`generate` regenerates the committed JSON/JSONL inventories. `validate` recomputes
those artifacts independently from the authenticated archive and compares their
complete bytes, after checking the materialized tree. `--cache`, `--archive`,
`--source-root`, and `--output` support isolated workspaces. The archive root's
files may be read concurrently; execution must use separate working directories.

The archive SHA-256 is
`7002403d7cc44529ef6d26f69a44818263395ead7c16c05a5808ae047ebeb0e5`.
The runner at `src/cmd/internal/testdir/testdir_test.go` is independently checked
against `docs/go-oracle/pin.tsv`:
`54900709a1fae5f469aa7bf59b22660f6fb9eb169e84f9c0d9760f0fe38444f4`.
The historical inventory's reviewed digest and every historical source digest
must also match. Original source files are never rewritten.

## Independent denominators

| Unit | Count | Meaning |
|---|---:|---|
| Historical `.go` source files | 3,398 | Exact historical source-file denominator |
| Upstream testdir roots | 2,726 | `.go` entries in the pinned runner's 14 direct directories |
| Historical directory inputs | 669 | 666 ordinary directory inputs plus three used by nested `run` drivers |
| Historical files outside testdir scope | 3 | `test/stress/{maps,parsego,runstress}.go`; runner does not enumerate this directory |
| Valid root action recipes | 2,725 | Across all 17 action names; one additional root has build-ignore metadata and no valid action |
| Directory recipe roots | 290 | True `*dir`/`runindir` recipes; 679 member references including non-Go inputs |
| Ordered directory package groups | 607 | For the four actions using upstream `goDirPackages`, including `-s` |
| Expected-output bindings | 1,232 | 99 existing `.out` files plus 1,133 explicitly absent sidecars |
| Generator action roots | 26 | 22 `runoutput`, four `errorcheckoutput`; each generates one downstream source artifact when applicable |
| Nested-process candidate roots | 26 | `os/exec` import in root source; requires runtime process and generated-artifact evidence |
| Compiler/typechecker test-package roots | 26 | Direct test packages under compiler, testdir, go/types and internal/types scopes |
| Static typechecker fixture roots | 743 | Both checkers' five file/directory families, expanded under their respective runner identities |
| Distinct typechecker fixture inputs | 378 | Shared fixture files are counted once here and separately per checker root |
| Executed roots / observed generated programs | 0 / 0 | No source program runs during inventory construction |

These units overlap and must not be added into a single test count. The package
roots include both checker packages and the testdir package. **Runtime-generated
subtests and nested-generated-program denominators are unknown**, represented by
JSON `null`; zero observed generated programs is not zero expected programs.
Every case retains environment/build constraints for later adjudication. No
platform filtering or unsupported-product exclusions are applied here.

The three stress sources remain in the source inventory. `runstress.go` describes
an intentionally infinite runtime stress program; running it needs a separately
bounded stress campaign, not an invented finite testdir recipe. Its absence from
the finite upstream runner is provenance, not a Bash++ coverage exemption.

## Artifacts and semantics

- `summary.json`: schema, reviewed pins, scopes, independently named counts,
  runner directories and platform-dependent expected-failure sets.
- `files.jsonl`: digests for every regular file under `test/`,
  `src/cmd/compile/`, `src/cmd/internal/testdir/`, `src/go/types/`, and
  `src/internal/types/`, plus license/version/environment identities (4,814).
  Other SDK dependencies are authenticated through the complete source archive
  and full-tree verification; they are not mislabeled as test fixtures.
- `historical-sources.jsonl`: all 3,398 historical rows with original action,
  digest, source role and owning roots. Historical `none` (762 rows) is not an
  exclusion: the earlier ten-line action detector misses `asmcheck` and other
  true recipes, as well as dependency-only files.
- `testdir-roots.jsonl`: untruncated root/recipe list, flags, arguments,
  environment append operations, build directives, package order, exact
  directory membership, sidecar presence/absence, and generated-source duties.
- `typechecker-roots.jsonl`: the exact five `testDirFiles` families for each of
  `go/types` and `cmd/compile/internal/types2`. A direct file is one fixture;
  direct files in a child directory form one package fixture. It preserves the
  checker-specific column tolerance and source constraints. Other checker unit
  tests and generated source literals belong to the package-root executions.
- `package-roots.jsonl`: packages with `_test.go` inputs in the compiler/checker
  scope, excluding Go's `testdata`, vendor and hidden/underscore directories
  from package enumeration. Those files remain in `files.jsonl`. Package
  applicability and dynamic tests require bound `go list`/`go test -json` runs.
- `action-catalog.json`: the full pinned 17-action vocabulary and phase contracts.
  Every entry explicitly records `implemented_executor: false`. This catalog is
  not executable code or a claim that these phases have been implemented.

The recipe parser uses upstream quote/backslash behavior rather than shell
`shlex`, keeps flags and argv separate, appends repeated environment settings,
records timeout before environment scaling, and preserves the `-0`, `-1`, `-s`,
`-gomodversion`, and `errorcheckwithauto` rules. Errorcheck effective flags include
upstream's `ssa/check/on` insertion. Actual assembly environment expansion,
diagnostic matching and final compiler commands remain executor duties.

Two important upstream boundaries are explicit:

1. `test/linkmain.go` has `//go:build ignore` and a copyright line in the recipe
   position. Upstream registers it, then checks constraints **before** action
   validation. The root remains present with `action: null` and
   `invalid-if-forced-past-build-ignore`; it is not silently discarded.
2. Plain `run` programs can invoke Go and generate more programs internally.
   `bug369.go` and `issue9355.go` read three `.dir` files despite not using a
   directory action. Other examples include `nosplit.go`, `const7.go`,
   `rangegen.go`, and `linkmain_run.go`. Associated directories are preserved;
   sibling `.go` string references are conservative candidates. They are not an
   exhaustive dynamic dependency graph. Full archive verification ensures no
   upstream bytes escape the provenance boundary. Future execution must record
   every child process and generated artifact and must not count native Go
   child success as evidence that Bash++ executed the tested program.

## Failure behavior and verification

Wrong archives, runner changes, historical digest drift, malformed recipes,
unknown actions/families, unclassified historical files, added/missing/changed
source files or added empty directories, symlinks, unsafe archive paths, duplicate archive members and
changed inventory artifacts all fail closed. Normal inventory output uses
`status: inventory-verified` and `execution_claim: false`, never a parity PASS.

The negative selftests cover source mutation/addition/deletion, false sidecar
addition, symlinks, archive checksum/path/duplicate attacks, malformed recipes,
quote and flag semantics, ignored-but-enumerated roots, nested-driver inputs and
unknown generated denominators. Full validation rederives all committed rows
from the authenticated release; run it after generating and before executing.

## Execution foundations and remaining implementation

The full native oracle and product accounting drivers are separate from the
inventory. See [SDK relocation and authenticated continuations](AUTHENTICATION-RESUME.md)
for durable source paths, fail-closed resume rules and the legacy evidence boundary.
See [the official type-checker recipe adapter](TYPECHECKER-ADAPTER.md) for how the
743 `go/types`/`types2` check roots execute their two phase obligations, and which
exact recipe options still fail as unfinished.
They depend on the shared `tools/corpus/executor.rb` contract.
`GO_FULL_CORPUS_LIB=/absolute/path/to/executor.rb` supports isolated integration
before the shared harness commit lands. These drivers have parser/negative
contract tests; a full corpus run has **not** been performed in this change.

First prepare an isolated complete SDK from the pinned source archive plus the
pinned platform binary distribution:

```sh
python3 tools/go-full/sdk.py --goos darwin --goarch arm64 \
  --output "$PWD/.cache/go-full-sdk/root" > .cache/go-full-sdk-identity.json
```

`sdk.py` authenticates both archives, checks every overlapping file for byte
equality, preserves official executable modes, verifies the native `bin/go`
digest, and emits an identity for the exact merged tree. It never modifies the
original source tree or runs a compiler. An existing SDK must match all merged
files. The source-complete SDK contains `test/`, which packaged toolchains may
omit; relying on a packaged toolchain alone can make upstream testdir skip the
entire corpus.

When the manager allocates a compiler slot, run the full native harness:

```sh
ruby tools/go-full/native.rb \
  --sdk-identity .cache/go-full-sdk-identity.json \
  --evidence /absolute/durable/run/native --parallel 2 --timeout 1800
```

This executes all 26 inventoried packages with the **unmodified upstream**
harnesses. It does not cap historical tests or reimplement only seven actions.
It uses serial package execution, `GOMAXPROCS=2`, and bounded intra-package concurrency. It
retains real `go test -json` output and joins terminal observations to all three
static axes. Duplicate terminal events, missing roots, source/SDK mutation,
partial test lifecycles, and failed packages cannot produce a native PASS. An
actual ancestor skip can explain an unregistered child; a passed parent cannot
confer a pass on an absent child. Actual runtime test starts and terminals form
separate dynamic denominators. `native_verdict: PASS` remains explicitly
`evidence_kind: native-go-only` and `product_execution_claim: false`.

Once the manager supplies the integrated source-front-end candidate, its build
manifest, and module context, the full product accounting driver can run:

```sh
ruby tools/go-full/product.rb \
  --bashy /absolute/candidate/bashy --candidate /absolute/candidate.json \
  --sdk-identity .cache/go-full-sdk-identity.json \
  --source-root "$PWD/.cache/go-full/go" \
  --native /absolute/durable/run/native \
  --modules /absolute/generated-module-context.json \
  --evidence /absolute/durable/run/product
```

The module-context JSON maps generated module-file names to exact bytes, as the
shared executor requires. Original corpus files are always the source inputs.
The driver replays the retained native event log, checks all native root IDs
against independent inventories, and binds both runs to the same SDK/inventory.

Only straightforward `run`, `build`, and `buildrun` recipes without special
flags, environment changes, nested tools, or directory/generator requirements
enter the shared executor. Their original source executes in all three modes;
upstream output is checked in addition to differential observations. Testdir
requires a successful runtime exit. Its combined stdout/stderr expectations
cannot be reconstructed when both separately captured streams are nonempty;
such a case fails with a concrete capture-adapter gap instead of guessing an
ordering.

Another 521 unflagged negative `errorcheck`/`errorcheckwithauto` roots use the
source-positioned diagnostic adapter. Both product processes must actually
exit unsuccessfully and their retained output must satisfy every original
`ERROR` annotation. A pinned-SDK build of the Go matcher supplies Go regular
expression semantics, `LINE` expansion, source positions and autogenerated
diagnostic handling. The adapter rejects timeouts, process leaks, signals,
missing or changed source/output, absent expected annotations and every
unmatched diagnostic, including unpositioned failures and nonlocal files.
It does not borrow a native compiler result as product evidence. Recipes with
extra compiler flags, version/environment changes or expected-failure inversion
still require their own exact adapters.

Twenty-one unflagged `runoutput` roots also have a real generated-source
adapter. Each unchanged generator runs in three modes. Each mode's emitted
bytes become its own separately hashed `tmp__.go` input, retaining the exact
emitter stream and parent/mode identity. A full three-mode downstream gate runs
for **each** emitted artifact: three generated artifacts and nine child-mode
obligations per applicable root. The diagonal ensures that each original mode
executes its own emitted source; the additional checks must also pass. No
baseline-generated source replaces a product generator's output. Upstream
expected output is checked on child execution. Missing/empty generator output,
failed generators, mixed-stream source ordering, missing children or changed
source fail. Aggregate actual subprocess time and process-stage counts are
retained; the shared executor currently gives every child/mode a private Go
cache, so this stronger cross-check costs additional compilation work. Numeric
product cost requires the integrated candidate run.

Every remaining root gets retained interpreted/check and compiled/transpile
**diagnostic probes**, exact source hashes and an explicit list of unfinished
phases. Those probes do not satisfy the missing recipe phases, even when they
exit zero. The root remains FAIL. Native upstream skips remain `UPSTREAM_SKIP`
with their actual event and require applicability adjudication; they count as
zero product executions. These are visible implementation gaps, not exclusions
or successful placeholder results.

The product summary deliberately cannot certify full coverage in this current
executor increment. Remaining work is explicit:

- Complete phase adapters for compiler-only, diagnostic, ordered directory,
  assembly, generated-source and module-directory recipes.
- Bind both product modes to every static checker fixture, generated checker
  program and dynamically enumerated test body; native `go test` cannot supply
  a product verdict.
- Instrument nested compiler processes and retain their generated inputs and
  artifacts. A per-case `go` proxy can record command lookup, argv/environment,
  working directory, source digests and generated artifacts; native forwarding
  is baseline-only. Product compiler requests must route to the corresponding
  product phase or fail explicitly.
- Certify SDK/source access boundaries with a manager-provided OS sandbox or
  container. PATH proxies alone cannot prevent absolute-path tool/source
  access, so they cannot establish that boundary.
- Join every observed dynamic obligation to final product evidence and resolve
  each upstream skip against the bound platform/options before certification.

Run the non-corpus evidence tests with:

```sh
ruby tests/go-full/execution_test.rb
ruby tests/go-full/authentication_test.rb
ruby tests/go-full/typechecker_test.rb
GOMAXPROCS=1 GOTOOLCHAIN=local /absolute/pinned/sdk/bin/go -C tools/go-full/diagnostics test -p=1 ./...
GOMAXPROCS=1 GOTOOLCHAIN=local /absolute/pinned/sdk/bin/go -C tools/go-full/typecheck-diagnostics test -p=1 ./...
```

`typechecker_test.rb` includes bounded integration controls that execute the
frozen candidate against real pinned fixtures; they skip when that candidate or
the pinned SDK is absent.

They reject terminal-event fabrication by omission/duplication, passed-parent
substitution, improper generic handling of complex/nested recipes, unsuccessful
runtime exits and guessed combined-stream ordering. No fake successful Bash++
program is used as corpus evidence.


## Recorded native run and skip review

The first complete native run finished successfully in 560.83 seconds on
`darwin/arm64`, `CGO_ENABLED=1`, with `GOMAXPROCS=2`, serial packages and two
concurrent tests. All 26 packages passed. The independent static joins were
2,665 historical passes plus 61 upstream skips, and 741 checker-fixture passes
plus two upstream skips. The event log contains 7,312 test starts and 7,312
terminal test events. Parent tests and dynamic subtests have distinct event
identities; this is an event denominator, not an invented atomic-case count.

The native event log SHA-256 is
`a31b7ab58f416a46f8c225afb010dcedc13a0ffc5ad77f34d3f17b2ee57c02e8`.
The source-complete SDK passed whole-tree verification after execution. This is
native-only evidence and does not establish product or nested-tool coverage.

Generate an exact applicability-review packet from retained evidence:

```sh
python3 tools/go-full/skips.py --native /absolute/durable/run/native \
  --output /absolute/durable/run/native-skip-review
```

The first packet retains all 63 static-axis skip events and original directives:
52 historical build-constraint decisions, nine explicit upstream `skip`
actions, and two checker decisions for the shared `issue78346.go` fixture.
That fixture declares `//go:build ignore && !386 && !arm && !mips && !mipsle &&
!wasm`. Exact per-root source hashes, output reasons, log line numbers, terminal
events, native process environment and a retained pinned-SDK `go env` query
support manager adjudication. The packet leaves
`manager_adjudication_complete: false` and assigns zero product execution
credit. It does not convert architecture/experiment/upstream skips into blanket
product exclusions.


## Directory package and phase ledger

`directory-phases.jsonl` expands all 290 directory recipes into 635 tested
package nodes, 362 edges between packages under test, and 1,132 ordered phase
obligations **per mode**. It is a ledger with zero execution credit. Package
imports come from Go's imports-only parser over authenticated original files,
not regular-expression guesses. Generate or verify it using the complete SDK:

```sh
python3 tools/go-full/directory.py --go /absolute/sdk/bin/go \
  --sdk-identity .cache/go-full-sdk-identity.json
python3 tools/go-full/directory.py --go /absolute/sdk/bin/go \
  --sdk-identity .cache/go-full-sdk-identity.json --validate
python3 tests/go-full/test_directory.py
```

Each ordered `compiledir`/`rundir`/`errorcheckdir`/`errorcheckandrundir` group
retains exact file membership, package/importcfg identity and dependencies.
These are explicit compiler inputs: file build constraints do not filter them.
The error-check-and-run action retains both compilation passes, the designated
failing package, diagnostic matching, final-package link and execution.
Assembly/packing stages and `runindir` module creation/graph resolution remain
explicit. Module file selection is environment-dependent, and module package
ordinals are not falsely asserted to be a compile order. The sole `import "C"`
edge is a named foreign-code bridge requirement, not an unresolved import or
permission to forward tested Go packages to native Go.

Every edge between tested Go packages prohibits native forwarding. The current
candidate's package importer and interpreter linker need product support to
satisfy those edges. Running an original dependency under native Go would not
complete the corresponding interpreted or compiled product phase.

## Negative-phase discovery shard

`product.rb --phase-shard negative` selects **all 521** implemented unflagged
negative roots, records the full manifest denominators alongside that selection,
and emits one retained result per selected root. It does not run the 1,050
ordinary runtime/build roots or claim full-sprint closure.

The first diagnostic candidate run retained 521/521 rows: 219 negative passes,
297 failures and five actual upstream skips. Both product modes had the same
219/297 result split, and the original source tree passed validation afterwards.
Failure categories across modes were 514 missing-annotation outcomes, 55
wording mismatches and 25 unexpected successes. These are diagnostic findings;
no output normalization or unsupported flags were used to turn them green.
The main missing-diagnostic cause was returning only the first `go/types` error
and formatting `scanner.ErrorList` as one error plus an omitted-error count.
Full positioned error collection/rendering is product work, not a corpus edit.
