# Go by Example conformance corpus

Every `*.go` program under `examples/` in `mmcgrana/gobyexample` at commit
`7d705626375ba0263b616865a286e1587d6989c8`, copied verbatim, plus the non-Go
files those programs need at build or run time.

The upstream README is retained at
[`examples/UPSTREAM-README.md`](../../examples/UPSTREAM-README.md); it carries
the CC BY 3.0 grant covering the site content and examples. Provenance for the
exact commit is in `pin.tsv`; per-file byte counts and SHA-256 digests are in
`inventory.tsv`.

## What is here

| file | role |
|---|---|
| `pin.tsv` | the exact upstream commit, license, observed date, and the counts/digest the validator cross-checks |
| `behavior-schema.tsv` | the vocabularies and coupling for the three classification axes — the validator loads them from here, it does not hardcode them |
| `classification.tsv` | the authored, human-owned decision for every copied file |
| `inventory.tsv` | the derived join of `classification.tsv` with the measured bytes of the copied files |
| `toolchain.tsv` / `candidates.tsv` | the authenticated Go 1.27 release and the reviewed Bash++ candidate manifests |
| `evidence-roots.tsv` | the reviewed evidence roots; today's anchor is a real failing run |
| `prerequisites.md` | the measured product gaps that keep this gate red, and the CLI contract it binds |

`inventory.tsv` is a pure function of the other two plus the corpus tree.
`tools/go-by-example/refresh.sh` regenerates it, and given a clone at the pinned
commit it also proves the copy: the upstream `examples/**/*.go` set must equal
the classified program rows, and every copied file must be byte-identical to its
source.

**89 rows: 85 `.go` programs (84 `program` + 1 `test_program`), 3
`runtime_asset` files, 1 `provenance` file.** The 85 is the upstream `.go`
denominator at the pinned commit, recorded in `pin.tsv` and re-derived by the
validator, not asserted.

## Runtime assets are part of the corpus

`examples/embed-directive/embed-directive.go` does not compile without the files
its `//go:embed` directives name. Copying only the `.go` files produces a corpus
whose most-cited example cannot build, so the assets are copied and inventoried
with the same digests and provenance as the sources:

- `examples/embed-directive/folder/single_file.txt`
- `examples/embed-directive/folder/file1.hash`
- `examples/embed-directive/folder/file2.hash`

The `requires` column makes this a closed loop in both directions: a program may
not require an uninventoried asset, and an inventoried asset that no program
requires is an error.

## Three axes instead of a blanket verdict

The first cut of this corpus gave all 85 rows the same three values —
`applicable` / `none` / `exact`. That is not a classification; it is a
placeholder that happens to typecheck. It says nothing about the fact that
`switch` reads the wall clock, `http-server` binds a port, `line-filters` reads
stdin, or `range-over-built-in-types` prints map iteration order.

Each row now carries three explicit, deterministic axes, all drawn from
`behavior-schema.tsv`:

- **behavior** — what environmental surface the pinned program actually
  touches: `environment`, `filesystem_cwd`, `filesystem_temp`, `file_input`,
  `network_client`, `network_server`, `stdin`, `signals`, `process_exec`,
  `process_exit`, `clock`, `timeout`, `random`, `map_iteration`, `concurrency`,
  `argv`, `pointer_identity`, `test_harness`, or `deterministic`.
- **adapter** — the environment construction applied *before* the run to make it
  hermetic. Adapters never edit the pinned bytes.
- **normalization** — the only licensed rewrites applied *after* the run,
  identically to both sides of the differential.

The coupling is enforced, not documented: a behavior's required adapters must
all be present on the row, and every adapter and every normalization on a row
must be licensed by a behavior the row actually declares. `deterministic` is
exclusive and must compare raw bytes with no adapter.

The differential being compared is **pinned Go 1.27 vs Bash++, on the same
pinned bytes**. A normalization therefore exists only to cancel variance two
separate invocations cannot avoid — wall clock, addresses, ephemeral ports,
scheduler interleaving. It never exists to make a disagreement go away.

The pinned programs have no clock or random-source injection API. The runner
therefore exports no fictitious seed/clock variables: those rows use narrow
typed semantic comparators that validate and retain observed values, ranges,
arity, and order. Normalization is stream-aware; a stdout-only rule is an exact
no-op for stderr, including an empty stderr stream.

`map_iteration` is declared in the schema and used by exactly one row
(`range-over-built-in-types`, which prints `for k, v := range kvs`). It is not
used more widely because `fmt` prints maps in sorted key order, so `maps`,
`mutexes` and `url-parsing` are genuinely deterministic despite holding maps.

### There is no N/A

There is no `applicable` / `exception` / `N/A` column, and no way to reach one.
Every program row is attempted by `tools/go-by-example/gate.sh` under the
adapters named on its own row, and an unspawned attempt is explicitly missing,
never executed. The only overall state a bad run can produce is FAIL. The
validator rejects `n/a`, `N/A`, `PLANNED`, `planned`, `skipped`,
`unsupported` and `exception` as classification values outright.

`runtime_asset` and `provenance` rows carry `not_a_program` on all three axes.
That is structural — a `.txt` file has no behavior to classify — and the
validator requires it exactly for those kinds and forbids it for program kinds.
It is not something a failing run can move a row into.

## Gates

`tools/go-by-example/validate.sh` is the offline integrity gate, wired into
`harness/run.sh` on every run. It fails closed on:

- a pin that is not the reviewed commit, or that has lost its CC BY 3.0 grant
- a schema term that is undeclared, duplicated, or self-inconsistent
- an inventory path that is absolute, drive-qualified, home-relative, contains
  `..` or `.` components, an empty component, a backslash, a character outside
  the permitted set, or falls outside `examples/`
- **a path-set difference** between `classification.tsv`, `inventory.tsv` and
  the corpus tree, in either direction — missing rows, extra rows, missing
  files, extra files, and same-count substitutions and transpositions
- any byte-count or digest drift in a copied source
- a symlink or other non-regular file standing in for a copied source
- an unlicensed normalization, a missing required adapter, an unlicensed
  adapter, or a `deterministic` row carrying either
- a break in the `requires` closure in either direction
- a classification table that diverges from the derived inventory

The path-**set** comparison is the correction that matters. The first cut
compared a row *count* against `find | wc -l`, which any same-size set
satisfies; renaming a file, swapping two paths, or dropping one row while adding
another all passed. `tests/go-by-example/validate_inventory.sh` asserts the
rejection of 39 defect classes, including the three the count check let through.

`tools/go-by-example/gate.sh --candidate MANIFEST --bashy LAUNCHER` is the
differential execution gate and is final verification. **The product now
implements both contract commands, so the gate drives the real front end; it
still fails today, on measured product defects rather than on a missing flag.
See [`prerequisites.md`](prerequisites.md).**

## The three modes

Each of the 85 program rows is observed three times, on the same unchanged
upstream bytes, for a denominator of 255 attempts.

| mode | command |
|---|---|
| `oracle` | pinned `go build` (`go test -c` for the `test_program` row) into a native binary, then run that binary |
| `interpreted` | `bashy --bashpp --source=go <source> [argv...]`, or `--go-file A --go-file B` for an explicit multi-file package |
| `compiled` | `bashy transpile --bashpp --source=go <inputs> -o generated.go --map generated.go.map`, then pinned `go build` of the generated Go, then run the artifact |

Six Sprint 118 corrections are load-bearing here.

**The oracle no longer uses `go run`.** `go run` is a wrapper: for
`examples/exit/exit.go` it exits 1 itself and prints `exit status 3` on *its*
stderr, so a deliberate `os.Exit(3)` and a panic were being compared through a
`goexit_status` rewrite instead of being observed. The gate now builds and runs
a native binary, `exit.go` is recorded as exit 3 with empty stderr, and the
`goexit_status` normalization is gone (normalizer VERSION 2).

**`--bashpp --compile -o` is gone.** No shipped CLI ever implemented it. The
compiled mode is a real transpile → build → run pipeline, and each stage is
recorded separately, so a successful transpile can never be read as an artifact
that executed; `validate-evidence.rb` refuses a spawned compiled run that has no
successful `build` stage carrying an artifact digest.

**Assets keep their original relative paths and every mode gets fresh state.**
`//go:embed folder/single_file.txt` is resolved by the compiler against the
directory holding the source file, so the previous basename-flattened copy
silently changed the program. Each mode now gets its own source staging
directory and its own freshly built execution root (nothing but `home/`, `tmp/`
and the declared assets), snapshotted before and after. The resulting filesystem
delta is a compared channel alongside status, stdout and stderr, normalized only
by the row's declared `tmp_path` where licensed; a mode that agrees on all three
streams but leaves different files behind fails with `fail_effects`.

**The `_test.go` row really runs its assertions.** The oracle builds the
unchanged bytes with `go test -c`. The product modes are given the unchanged
bytes *plus* a separately generated `testing.Main` driver — a new file, never an
edit — so the tests actually execute instead of the `_test.go` being handed over
as if it were a script. The two recipes were verified to produce byte-identical
output and status under `-test.v` on the pinned toolchain.

**Multi-file input uses the product's own `--go-file`, never a second operand.**
Sprint 118 W1 shipped `--go-file`, repeatable, as the explicit multi-file
contract; a surplus operand is handed to the *program* as argv. Appending the
generated driver as an operand would therefore have compared a one-file build
against the oracle's two-file package with nothing in any stream to show for it.
Both the gate and `validate-evidence.rb` bind this, and the validator checks the
recorded argv of every multi-file product stage, not merely the recipe prose.

**Process control is the shared corpus library's, not a second copy of it.**
Spawning, the monotonic deadline, the process group, the reap, teardown,
surviving-descendant detection, raw file-backed stream capture, filesystem
snapshots, launcher/payload/SDK digest authentication and clean-revision
authentication all come from `tools/corpus/executor.rb`. This corpus owns only
what is specific to it: the per-row behaviour adapters, the three recipes and
the narrow declared comparators layered above those primitives. The one thing
the shared `Corpus.capture` signature cannot express — a descendant that called
`setsid()`, and a pid an adapter must signal at a readiness line — is obtained
through `tools/go-by-example/launch.go`, a corpus-owned launcher that publishes
its pid, opens an inherited liveness FIFO and then `exec`s the program. It adds
no second spawn, timer or reaper, and the argv actually handed to
`Corpus.capture` is recorded beside the program's own.

## Adapters name controls that exist

`fake_clock` and `seeded_random` were removed from the registry. The pinned
programs read the real clock through `time.Now` and draw from the `math/rand/v2`
global source, neither of which has an injection point — measured against the
pinned toolchain, `GODEBUG=randautoseed=0` still leaves
`examples/random-numbers` producing different values on consecutive runs. Those
rows now carry adapter `none` and are compared by the `wallclock` and
`random_stream` comparators, which is what was actually happening. Both the gate
and `validate-evidence.rb` reject a schema that registers an adapter no
production code implements, and the reverse.

`signal_injector` was also made real. It used to fire after a blind 50 ms sleep,
which raced `examples/signals`: the process died under the default SIGINT
disposition before `signal.Notify` was armed, so both sides recorded empty
output and the example's actual behaviour was never observed. It now waits for
the program's readiness line, exactly as the schema describes it, and the row
records `awaiting signal` / `interrupt signal received` / `exiting`.

## The candidate is authenticated, not assumed

`gate.sh --candidate MANIFEST --bashy LAUNCHER` is the whole provisioning
contract, and there is no default: a gate that ran whatever binary happened to
be on PATH would be reporting on an unidentified product.

Sprint 98 bound one reproducible executor digest in `executor.tsv`, and
`build-executor.sh` rebuilt it twice to prove it. That pin and that script are
retired, because the Go-source front end is not that shape: it is a Makefile
tag-enabled build (`make build BASHY_GOSOURCE=1`) that installs a small launcher
beside a large `.real` payload, over a set of replaced sibling modules. Claiming
to reproduce a manager-supplied diagnostic build byte-for-byte would have been a
claim this repository cannot honestly make, so it is not made.

What replaces it is stricter about everything that *can* be checked. The
supplied manifest is accepted only when it equals a reviewed row of
`candidates.tsv` — starting with the manifest's own digest — and then:

- the launcher and its adjacent `.real` payload are authenticated separately,
  by `Corpus.authenticate_file`, and may not be the same digest;
- every declared repository is at its clean exact revision, untracked files
  included, by `Corpus.authenticate_candidate` — with no extra and no missing
  runtime dependency, `filebrowser` included;
- the front-end version and the SDK identity match the reviewed row, and that
  identity is the same Go release the oracle uses, so a pass can never be
  assembled from a Go 1.27 oracle plus a candidate some other release built;
- the build recipe exactly matches the reviewed manifest. Historical diagnostic
  builds may use a tag; reviewed default builds are also accepted without
  relaxing the manifest, binary, repository, or SDK identity checks.

The build recipe is **bound, not inferred**. The manager supplies the
authenticated manifest; this repository proves these bytes and these revisions
and records the asserted recipe, and it does not pretend to have observed the
build. `tools/go-by-example/validate-candidate.rb` re-derives all of the above
from `candidates.tsv` alone, sharing no state with a gate run.

The lowering runtime follows from the same authentication: the compiled mode's
`replace mvdan.cc/sh/v3` now points at the repository the *authenticated
candidate* declares, at its proved commit. The old `GBE_SH_MODULE` environment
path — an unauthenticated directory the caller chose — is gone.

## Fail-closed properties

Every adapter and normalization the schema declares must have an implementation
registered in the runner. All three modes are given the *same* environment
block: there is no tooling exemption for the interpreter, because
`examples/environment-variables` prints every key it can see. `GOROOT` and
`GOMODCACHE` are in that common block — they are what the product's runtime
import helper reads, and granting them to one side only is exactly the
exemption this rule exists to forbid. PATH is provisioned only for the rows
whose declared behavior is to execute another program; every other row runs with
an empty PATH.

That empty PATH is **command-lookup isolation, not an OS-level denial** of the
SDK or of the source tree, and the evidence says so in as many words; the
validator refuses a chain that words it more strongly than the harness earns.

Process groups are bounded and swept by `Corpus.capture`, and surviving
descendants are observed rather than assumed: every child inherits the write end
of a liveness FIFO the corpus launcher opens before `exec`, so the gate's read
end reaches EOF exactly when the last descendant is gone. A descendant that
escaped into its own session is invisible to `kill(0, -pgid)` and is still
reported as a leak. Any timeout, surviving child, missing artifact/mode/result,
invalid transpile source map, non-UTF-8 stream, exit/status/output/effect
mismatch, or unregistered schema term is fatal. Complete-but-mismatching
attempts are published atomically as failing evidence. Each final record
declares the 255 denominator, the actually spawned numerator, every anchored
digest and a root digest.

`validate-evidence.rb` is a standalone verifier. It decodes every raw stream,
independently recomputes normalized bytes and effect digests, rechecks the
derived per-attempt verdicts and the summary, re-derives the schema
vocabularies, re-checks every behavior/adapter/normalization coupling, requires
the inventory's classification columns to be exactly the authored table's,
re-runs `validate.sh` itself, re-derives the whole candidate binding from
`candidates.tsv`, and enforces the recorded recipe: an evidence chain whose
oracle reverted to `go run`, whose product modes dropped `--source=go` or the
`--go-file` multi-file contract, which grants one mode extra environment, which
renames the shared corpus primitives away, which overstates the isolation the
harness builds, or which was produced against some other launcher, payload,
build recipe or runtime dependency set, is refused even when every hash in it
has been recomputed. Recomputing JSON self-hashes or the summary root proves
consistency, not provenance, so the derived root must additionally appear in
`evidence-roots.tsv`.

## Evidence status

**The anchored root is a real failing run, and that is the honest state.**
`--source=go` now exists, so the gate drives the real product instead of
documenting a missing flag, and the anchored chain in `evidence-roots.tsv` is
the authenticated `gosource-v1` diagnostic candidate over all 85 rows in all
three modes, with every raw stream retained. It is anchored *because* it is a
`fail`: anchoring makes it independently re-verifiable, and it gives the tamper
suite a document the product actually produced. It is not coverage, and
`validate-evidence.rb` still accepts `pass` only at
`denominator = executed = 255`, `missing = 0`, every attempt spawned, complete
and passing. The measured failures are listed in
[`prerequisites.md`](prerequisites.md).

The Sprint 98 schema-6 chain remains at
[`tests/go-by-example/retired/`](../../tests/go-by-example/retired/README.md);
it describes the retired `go run` / `--compile` recipe and must not be presented
as coverage. It is preserved rather than deleted — a failed chain is part of
this corpus's history.

The stand-in executable is gone with the same change. Phase B of
`tools/go-by-example/tamper-tests.sh` used to generate its input by running the
gate against a fixture, because no honest document existed; it now mutates the
committed real chain, and Phase A drives the same real candidate.

The suite checks **48 genuine mutations** across two phases — the 32 it always
checked, plus the candidate-binding negatives the manifest contract made
possible: missing rows, unimplemented adapters, permissive normalization, no
default candidate, an unreviewed manifest, a mutated launcher, zeroed and
self-identical digests, a Go 1.26 candidate pin (refused by both the gate and
the independent validator), a default-CLI build recipe, an incomplete runtime
dependency set, a runtime dependency at the wrong commit, a candidate declaring
no lowering runtime, spawn failure, timeout, descendant leak, basename-flattened
assets, an effect-only divergence that agrees on all three streams, invented
green documents, missing rows/modes, result tampering, stale raw and stale
normalized bytes with recomputed roots, forged effect digests, a compiled run
recorded without its build or its validated source map, reverted recipes, a
dropped `--go-file` contract in both the recipe and the recorded argv, a hidden
runtime-environment grant, disowned corpus primitives, overstated isolation,
evidence bound to another launcher/payload/recipe/dependency set, unbound
classification tables, unlicensed adapter coupling, and uninventoried corpus
files. The leak case is a real survivor, not a forced state.

The final harness binds each original example directory and each staged
source/driver/asset tree before execution, then checks them after transpilation,
Go build, and execution. Interpreted and compiled modes use separate original
copies. The `_test.go` bytes remain unchanged; its generated driver is a separate
bound input. Generated maps use the common validator with actual generated and
original/driver file records. Normalizer version 4 rejects unexpected concurrency
output and out-of-range worker/job identifiers instead of discarding them.
These harness corrections do not convert retained diagnostic failures into
passes; evidence must be regenerated and independently anchored for new bytes.
