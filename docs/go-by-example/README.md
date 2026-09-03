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
rejection of 41 defect classes, including the three the count check let through.

`tools/go-by-example/gate.sh` is the differential execution gate and is final
verification, so it runs after parser/evaluator/compiler support lands. It is
fail-closed three ways: it refuses to run without the pinned Go 1.27 toolchain
and `BASHY_BIN`; every adapter and normalization the schema declares must have
an implementation registered in the runner, so a term nobody implemented is a
configuration failure rather than a quietly skipped row; and the count of
executed programs must equal the count of program rows.

`tools/go-by-example/build-executor.sh` independently builds the reviewed
Bashy source commit twice with separate Go caches and a path-independent,
fixed build recipe. It installs only when both builds are byte-identical and
match the nonzero digest in `executor.tsv`. The executor is bound to the same
pinned toolchain as the oracle: the reviewed `go_identity` on the executor pin
must equal the `toolchain.tsv` identity, the resolved builder is authenticated
by release version, `VERSION` file and binary digest, and both builds run that
binary directly under `GOTOOLCHAIN=local`. A Go 1.26 provenance record, or an
ambient Go 1.26 builder, is refused before anything is compiled -- the gate and
`validate-evidence.rb` refuse the same pin independently.

The gate authenticates the native `go1.27.0` executable against
`toolchain.tsv`, executes three records per program (oracle, Bash++ interpreted,
and Bash++ compiled), retains compiled-build provenance with the compiled record,
bounds and sweeps each process
group, detects surviving descendants, captures all three observable channels, and writes the complete result
set to pass/fail-specific `.cache/go-by-example/results.jsonl.{pass,fail}`
evidence. The executor must match the
platform artifact digest reviewed into `executor.tsv`; there is intentionally
no caller-supplied digest override. The gate binds that identity, version,
corpus, schema, repository-versioned normalizer module, toolchain, source,
builder and compiled artifact hashes into the
evidence. Surviving descendants are observed rather than assumed: every child
inherits one end of a liveness pipe the gate closes immediately after spawn, so
the read end reaches EOF exactly when the last descendant is gone. A descendant
that escaped into its own session is invisible to `kill(0, -pgid)` and is still
reported as a leak. Any timeout, surviving child,
missing artifact/mode/result, non-UTF-8 stream, exit/status/output mismatch, or
unregistered schema term is fatal. Complete-but-mismatching attempts are published
atomically as failing evidence; incomplete attempts stay in the `.fail`
evidence and never replace opposite-verdict evidence. Each final record declares
the 255 denominator, the actually spawned numerator, every anchored digest and
a root digest; `validate-evidence.rb` decodes every raw stream, independently
recomputes its normalized bytes from the inventory classification and schema,
then rechecks the derived verdict and result chain
and requires that root in the reviewed `evidence-roots.tsv`. It is a standalone
verifier: it hashes and reloads `classification.tsv`, re-derives the behavior
schema vocabularies, re-checks every behavior/adapter/normalization coupling on
every program row, requires the inventory's classification columns to be exactly
the authored table's, and re-runs `tools/go-by-example/validate.sh` itself rather
than trusting that the gate once did. The classification digest is anchored in
the schema-6 manifest and summary alongside the corpus, schema, normalizer,
toolchain and executor digests. Recomputing JSON
self-hashes or the summary root proves consistency, not production provenance.
`tools/go-by-example/tamper-tests.sh` runs 24 genuine mutations: missing
adapters, permissive normalization, spawn failure, forged executors, Go 1.26
executor pins, missing rows/modes, result tampering, stale raw and stale
normalized bytes with recomputed roots, unbound classification tables,
unlicensed adapter coupling, uninventoried corpus files, and timeout/leak
handling. The leak case is a real survivor, not a forced state: the mutated
command exits 0 only after a descendant has confirmed it left the process
group, so the gate's unmodified cleanup, record and publication path is what
observes the leak.

The current compiler-parity tranche is intentionally red. The authenticated
evidence in `tests/go-by-example/story198-current.jsonl.fail` records denominator
255, executed 170, missing/unspawned 85: every compiled-mode command failed to
spawn because the reviewed executor does not yet implement `--compile`. This
infrastructure tranche does not close Story #198 and does not claim all modes ran.
