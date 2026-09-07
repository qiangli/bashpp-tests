# Go-Profile Lowering Parity

Sprint 117 / Story #9 / Story-ID `e400885f8746`.

`tools/lowering/go_profile.rb` is the generalized Go-profile differential
lowering runner. For each declared case it transpiles a Bash++ fixture to Go
twice, requires the two results to be byte-identical, requires a schema-checked
source map that is digest-bound to those bytes, compiles the Go with the exact
pinned Go 1.27.0 toolchain, moves the resulting artifact out of its build tree,
and then runs the interpreter and the artifact in two separate, identically
laid-out execution roots — comparing stdout bytes, stderr bytes, the numeric
exit status and the observable filesystem effects of both runs.

**This runner is an evidence instrument, not a conformance claim.** A pass says
"for this fixture, on this host, the interpreted and lowered executions were
observationally identical and matched the manifest". It says nothing about the
Go language, about coverage, or about fixtures it did not run.

## Running it

```sh
ruby tools/lowering/go_profile.rb \
  --manifest docs/lowering/go-profile-cases.tsv \
  --fixture-root tests/lowering/go-profile \
  --bashy   PATH_TO_BASHY_CLI \
  --engine  PATH_TO_BASH_ENGINE \
  --sh-module PATH_TO_SH_MODULE
```

| flag | meaning |
| --- | --- |
| `--manifest PATH` | seven-column TSV case manifest (required) |
| `--fixture-root PATH` | directory the manifest's fixture paths are relative to (required) |
| `--sh-module PATH` | local `mvdan.cc/sh/v3` module directory, used as a `replace` target (required; or `SH_MODULE`) |
| `--bashy PATH` | CLI providing `transpile --bashpp` (or `BASHY_BIN`) |
| `--engine PATH` | engine providing `--bashpp` interpretation (or `BASH_ENGINE_BIN`) |
| `--go PATH` | pinned `go1.27.0` binary (or `GO_BIN`; otherwise resolved via `GOTOOLCHAIN=go1.27.0`) |
| `--case FILTER` | exact case id or shell glob; an empty selection is an error |
| `--artifacts PATH` | retained evidence directory; must not already exist |
| `--run-path PATH` | `PATH` handed to both execution modes; defaults to an empty directory |
| `--typed-only` | additionally require an interpreter-free typed artifact, run with an empty `PATH` |
| `--timeout SECONDS` | per-subprocess bound (default 60) |
| `--go-cache PATH` | `GOCACHE` for the build; defaults to a directory inside `--artifacts` |
| `--go-mod-cache PATH` | `GOMODCACHE` for the build; same default |
| `--phases PATH` | compiler phase contract governing this manifest |
| `--artifact-only` | custom manifests only: declare every case `artifact-run` |
| `--inventory` | validate every repository manifest and its phase contract, then exit |

No host path is committed anywhere in this story's files. Binaries and the `sh`
module are supplied at runtime, by flag or environment variable.

## The case manifest

Exactly seven tab-separated columns, with this exact header line:

```
id	category	fixture	expected_status	stdout	stderr	public_test_ref
```

* `id` / `category` — `[A-Za-z0-9][A-Za-z0-9_.-]*`; ids must be unique.
* `fixture` — a `.bpp` path relative to the fixture root. It must be contained:
  no leading `/`, no `.`/`..` segment, and its **realpath** must resolve inside
  the fixture root's realpath, so a symlink cannot escape.
* `expected_status` — the exact numeric process exit code, a decimal integer in
  `0..255`. Not a `success`/`error` word.
* `stdout` / `stderr` — JSON **string** literals, so the expectation carries
  exact bytes including newlines and embedded quotes. A bare unquoted value is
  rejected.
* `public_test_ref` — non-empty public reference; no surrounding whitespace.

Rows with a different column count, extra columns, a malformed field, a missing
fixture, or a duplicate id are rejected before any case runs. Every `*.bpp` file
under the fixture root must be declared by some row, so a fixture cannot be
added and silently left unmeasured.

`--inventory` checks the whole repository inventory in one shot:

```
INVENTORY docs/lowering/go-profile-cases.tsv tests/lowering/go-profile 52
INVENTORY docs/lowering/profile-additional.tsv tests/lowering/profile-additional 68
INVENTORY OK: 120 cases across 2 manifests
```

Both the `go-profile` and the `profile-additional` manifests are supported by
the same loader, and together they account for all 120 existing cases.

## Compiler phases

Not every identity in the inventory is contracted to become a native artifact.
The phase contract, `docs/lowering/go-profile-phases.tsv`, assigns each of the
120 identities exactly one compiler phase. It is owned by the coverage worker;
this runner only reads and enforces it.

| Phase | Cases | What the runner does |
| --- | ---: | --- |
| `artifact-run` | 105 | Transpile, require a valid map, build with the pinned Go, move the artifact out, run it source-absent, and diff it against the interpreter — every check in the rest of this document. 100 successful runs and 5 runtime errors. |
| `semantic-reject` | 15 | Require the CLI to *refuse* the statically invalid source with the exact contracted diagnostic. No Go, no map, no build, no artifact. |

The document has five columns:

```
id	phase	source_sha256	reason	public_test_ref
```

and is validated before anything runs: exact header, exactly five fields,
a known phase, a hex `source_sha256`, a non-empty `reason` and
`public_test_ref`. Bound to the manifest it governs, it must have **exactly one
entry per identity in both directions** — a missing entry, an entry for an
identity the manifest does not declare, or a duplicate all fail closed. Each
row's `source_sha256` must equal the fixture on disk and its `public_test_ref`
must equal the manifest's, so the metadata cannot drift away from the source or
the golden it describes. For the default inventory the pinned 105/15 split is
enforced as well.

### The phase contract cannot be bypassed

* A **default inventory manifest** always carries the full default contract. It
  cannot be run with `--artifact-only` — that would silently turn the 15
  `semantic-reject` identities into artifact runs — and it cannot be run at all
  if the contract file is missing. Supplying `--phases` for a default manifest
  is allowed but relocates the document only: it is still validated against all
  120 identities with the pinned split, so it can never weaken the contract.
* A **custom manifest** must declare its phases explicitly, with either
  `--phases PATH` or `--artifact-only`. Neither is inferred; running without one
  is an error. The two are mutually exclusive.

## Semantic rejection

For a `semantic-reject` identity the contract is that the CLI **produces the
contracted diagnostic**, not merely that it fails. Exiting non-zero is not the
contract. The runner requires all of:

* both independent transpile attempts exit with the manifest's status and
  reproduce its full stdout and stderr **bytes**;
* the diagnostic is a *recognized semantic rejection* (below);
* neither attempt emits Go or a source map;
* neither attempt changes its input tree;
* the two attempts agree — a nondeterministic rejection fails;
* the interpreter, run independently in its own isolated execution root,
  reproduces the original status and streams with a `clean` lifecycle;
* the interpreted run leaves **no filesystem effect at all** — these fixtures
  are contracted to have no external effect before the designated error.

No artifact is built, and none is claimed.

### What counts as a recognized semantic diagnostic

Every non-empty line must be a rendered Bash++ diagnostic identity,
`BASHPP-E...`, optionally positioned as `<source>: line N: `. When a line is
positioned, the path must be the **original fixture path**. The origin is
deliberately not normalized: normalizing it away would hide a diagnostic
pointing at the wrong file, and a positioned secondary line is part of the
contract — `cap-type-neg` requires both its operand-type error and its
positioned `BASHPP-ESHORT-NONEW` line.

`undefined-receiver-neg` is allowlisted for the exact legacy rendering
`invalid receiver type Missing (type is not declared in this session)` that its
public test pins. That allowance is keyed to that identity and those exact
bytes; the same text under any other identity is rejected.

These are **never** a semantic rejection, however non-zero the status:

* a `LOWER-E*` lowering error, including `LOWER-EUNSUPPORTED` — the transpiler
  giving up on a construct is not a diagnosis of the program;
* a raw Go toolchain or type-check error;
* a bare `line:col:` position from the lowering type checker;
* any unprefixed error outside the allowlist.

This distinction is the whole point of the phase. A transpiler that exits 2 and
emits nothing looks identical to a correct rejection until you read the bytes.

## Reporting: artifacts and rejections are counted separately

The two phases are always reported as separate numbers, and the result line
says so explicitly:

```
GO-PROFILE PHASE RESULT: 81/105 artifact executions, 0/15 certified semantic
rejections (120 phase-aware cases selected of 120; artifact executions are the
only native artifacts, semantic rejections build none)
```

A certified semantic rejection is **not** a native execution. The totals must
never be read, or reported, as "120 native artifacts". 120 is the count of
phase-aware cases; the number of native artifacts is the artifact-execution
count alone.

## Toolchain authentication

The Go binary is authenticated against the row for this host's `goos`/`goarch`
in `docs/tour/toolchain.tsv`, which must have all seven columns populated. The
pinned version coordinate must be exactly `go1.27.0`, the full `go version`
output must match the recorded identity string, and the SHA-256 of the executing
binary must match the recorded digest. A host with no row is unsupported, not
degraded. Nothing runs before this passes.

## The source map

A source map is **required** for every case; it is not optional and its absence
is a case failure. It must be the artifact the public `bashy transpile` CLI
emits, at `<output>.map`, with schema `bashy-transpile-map-v1` and exactly these
top-level fields — extras and omissions are both rejected:

| field | requirement |
| --- | --- |
| `schema_version` | exactly `bashy-transpile-map-v1` |
| `origin` | non-empty, and equal to the transpiled source path |
| `go_digest` | exactly `sha256:<hex>` of the generated Go bytes |
| `mappings` | non-empty array |

Each mapping entry must carry exactly `go_line`, `go_col`, `source_line`,
`source_col`, `source_offset` and `node`. Both transpiles must produce
byte-identical maps.

**A positive integer is not a coordinate.** Every mapping is checked against the
bytes of the artifact it claims to address, in both directions:

* `go_line` must exist in the generated Go, and `go_col` must be inside that
  line;
* `source_line` must exist in the fixture, and `source_col` must be inside that
  line;
* `source_offset` must be exactly the byte position that `source_line` and
  `source_col` denote — the three fields must agree with each other and with the
  file, not merely be individually plausible;
* positions are **byte** positions, 1-based lines and columns with a 0-based
  offset, so a multi-byte source cannot shift a coordinate silently; a position
  landing inside a multi-byte UTF-8 sequence is rejected.

This invariant was validated against 200 real mappings produced by the CLI
across 20 real fixtures before it was made a gate, and the contract test pins
both directions: correct byte coordinates into a source containing two- and
three-byte characters are accepted, while the same coordinates counted in
characters are rejected.

The `go_digest` check is what makes the map load-bearing: a map that does not
hash to the exact Go source it accompanies is rejected, so a stale or
hand-written map cannot be presented as evidence.

## Typed-only profile (`--typed-only`)

Under `--typed-only` the compiled artifact must be a *direct typed Go program*:

* the generated package is `main`;
* every direct import is either the Go standard library or the reviewed
  `mvdan.cc/sh/v3/lower/shellrt` typed bridge runtime, which is itself
  stdlib-only and contains no interpreter;
* nothing in the artifact's **transitive** dependency set is a dynamic
  interpreter or process-exec package (`os/exec`, `plugin`,
  `mvdan.cc/sh/v3/interp`, `mvdan.cc/sh/v3/syntax`, `mvdan.cc/sh/v3/expand`,
  `mvdan.cc/sh/v3/pattern`);
* the artifact is executed with an empty `PATH`, so it cannot reach a shell.

The import facts come from `go list` and `go list -deps` — the Go toolchain's
own parser and build graph. They are never inferred by scanning the generated
text, because a textual scan matches comments, string literals and identifiers.
The contract test pins this: a program whose comments and function name contain
"interpreter", "shell", "runtime", "exec" and "bashpp" but which imports only
`fmt` is accepted, while a program that imports `os/exec` is rejected.

## Source absence and artifact isolation

Before the compiled run the original `.bpp` source is deleted from the compiled
execution root, and the built binary is moved out of its build directory into a
separate artifact directory. The artifact therefore runs with no source, no
module, no build tree, and an environment that contains no `GO*` variable. The
runner also refuses to start if the run `PATH` exposes a `go` executable.

## Execution environment

Both modes are launched with `unsetenv_others`, so the environment they see is
exactly what the runner builds — nothing is inherited:

```
LC_ALL=C.UTF-8  LANG=C.UTF-8  TZ=UTC  PWD=<execution root>
HOME=<execution root>/.bashpp-run/home
TMPDIR=<execution root>/.bashpp-run/tmp
TEST_TELEMETRY_DIR=<execution root>/.bashpp-run/telemetry
PATH=<--run-path, default: an empty directory>
```

plus, **for the interpreter only**, the tooling variables described in the next
section.

`HOME` and `TMPDIR` sit at *identical relative paths inside each execution
root*, so the two environments are genuinely equivalent and their contents are
part of the compared surface.

Comparison is done on a normalized profile in which the absolute execution-root
prefix is replaced by `${EXEC_ROOT}`. Without that normalization the absolute
paths guarantee a difference and the comparison can never gate anything — which
is exactly how an environment "check" becomes decorative. Any key that differs
outside the declared divergence list is a case failure. The declared divergence
list is exactly the interpreter tooling keys `GOCACHE`, `GOMODCACHE` and
`GOTOOLCHAIN`, plus `PATH` under `--typed-only` where the artifact is
intentionally given an empty one.

## Interpreter tooling — configured, not exempted

The interpreter links in the Go import compiler infrastructure. Running a
fixture that imports a stdlib package therefore makes it behave like a build
tool: measured on `stdlib-import`, a default `HOME` collects **685 entries** of
Go build cache and telemetry that the native artifact never produces. Left
alone, four real cases with byte-identical streams and status fail on effects.

Turning telemetry off is **not** sufficient, and this document previously
implied it was: `TEST_TELEMETRY_DIR` with a mode-off file stops the counters,
but the Go **build cache** still lands under `HOME`. The two are separate
mechanisms and both have to be configured.

The fix is configuration, never exemption. **No filesystem path is excused
anywhere.** Instead:

| Setting | Value | Where |
| --- | --- | --- |
| `GOCACHE` | dedicated tooling directory, recorded in evidence | **outside** every execution root |
| `GOMODCACHE` | dedicated tooling directory, recorded in evidence | **outside** every execution root |
| `GOTOOLCHAIN` | `local` | interpreter only |
| `TEST_TELEMETRY_DIR` | `<execution root>/.bashpp-run/telemetry`, holding a `mode` file containing `off` | **inside**, identical in both modes |

Reusing the authenticated build caches for the tooling directories is permitted;
what matters is that they are outside the compared tree.

The telemetry directory is deliberately *inside* the execution root, created
identically in both modes **before the baseline snapshot**, so the `mode` file
is part of the compared surface. A tool that flips it back on, drops a counter
beside it, or deletes it is a divergence like any other write. That is
controlling the tool's configuration, not ignoring the program's writes.

Consequences, and the limits of the claim:

* The native artifact carries **no `GO*` variable at all**, and keeps its empty
  `PATH` under `--typed-only`.
* **No new tool is exposed on any `PATH`.** The Go infrastructure is linked into
  the interpreter, so nothing needs to be reachable through `PATH`; the Go
  binary the build uses is still the authenticated one and is not put in front
  of either program.
* `GOCACHE`, `GOMODCACHE` and `GOTOOLCHAIN` are the *only* declared environment
  difference between the modes, and they are recorded in `meta.json` and in the
  interpreted observation. Being declared, they are no longer compared — that is
  a real, if narrow, reduction in what the environment gate covers.
* Everything else stays compared, including arbitrary writes to `HOME` and
  `TMPDIR`. Verified from both sides: with the tooling configured the
  `stdlib-import` case leaves **zero** entries under `HOME` and reaches parity,
  while an arbitrary `$HOME/arbitrary` write by either mode still fails.
* This recognizes one specific fact — that the interpreter embeds the Go import
  compiler — and configures it. It is not a general licence to relocate
  inconvenient output, and it does not cover a future tool that writes somewhere
  else.

## Filesystem effects — what is and is not detected

Effects are detected by taking a SHA-256 tree snapshot of the execution root
before the run and after it, recording for every path its relative name, kind,
permission bits, size and content digest.

**There are no syscall hooks, no tracing and no interception.** The runner does
not claim to observe what a process did; it observes what changed under the
execution root. The evidence records this explicitly
(`effects.syscall_hooks: false`).

What that covers:

* every path under the execution root, including dotfiles;
* `HOME` and `TMPDIR`, because they are inside the execution root;
* files whose names end in `.raw` — the runner's own `.raw` evidence lives
  outside every execution root, so there is no reason to excuse them, and a
  fixture named `notes.raw` is compared like any other file.

What it does not cover, stated plainly:

* writes to absolute paths outside the execution root;
* effects with no filesystem trace (network, IPC, non-persistent state);
* file metadata not in the snapshot tuple (mtime, ownership, xattrs).

### The one path that cannot be diffed

Exactly one path cannot be compared between the modes: the original Bash++
source, which the compiled artifact runs without. That is not a licence to stop
looking at it — a blanket ignore also hides a compiled artifact that *recreates*
the source path, and an interpreted run that rewrites its own source.

So instead of excusing the path, its state is pinned explicitly at both ends in
both modes, and every one of these is a case failure:

* the interpreted root must contain the source before the run;
* the interpreted run must leave it byte-identical — modifying or deleting its
  own source fails;
* the compiled root must not contain it before the run;
* the compiled root must **still** not contain it, or anything under that path,
  after the run — recreating or writing it fails.

Only once those transitions are asserted is the path normalized out of the
general effect diff, and the unfiltered snapshot is still what gets recorded.

## Process lifetime, timeouts and partial evidence

Every subprocess is started in its **own process group** with `pgroup: true`,
and its pipes are drained by a single bounded `IO.select` loop that appends to
the byte buffers as data arrives.

The rule the runner enforces is that **an observation is only evidence if the
runner watched the whole process tree finish.** Pipe EOF does not prove that:
a descendant can close or redirect the inherited descriptors and keep running,
and keep writing into the execution root, long after the pipes have closed.
Liveness is therefore probed on the *process group* — `kill(0, -pgid)` — not
inferred from the pipes. `invoke_subprocess` does not return while a process it
spawned is still alive in that group.

Each run records a `lifecycle`, and only `clean` is acceptable:

| lifecycle | meaning | verdict |
| --- | --- | --- |
| `clean` | leader exited, pipes closed, process group empty — observed to completion | case may pass |
| `timeout` | exceeded `--timeout`; group killed; exit reported as 124 | **case fails** |
| `group-outlived-drain` | a process was still alive in the group after the leader exited and the bounded grace expired; the group was killed | **case fails** |
| `group-unreapable` | the group could not be emptied | **case fails** |

`group-outlived-drain` is a failure, not a footnote. If the runner had to cut a
live process short, the streams and the snapshot that follow are truncated by
construction, and reporting parity on them would be reporting parity on an
observation that was still in progress. The explicit reason is included in the
failure text.

A process group that empties **on its own** inside the grace is not killed and
not penalised: the runner waits for it and the work it did is part of the
compared effects. Both directions are pinned in the contract test — a descendant
that finishes in time passes with its effect captured; one that outlives the
grace, with pipes open *or* closed, fails.

Other guarantees:

* Whatever bytes arrived before a kill are retained. Raw `stdout`/`stderr` are
  written to `<phase>.stdout.raw` / `<phase>.stderr.raw` at **every** phase,
  including failing, timed-out and truncated ones.
* Termination is `SIGTERM`, a short bounded wait, then `SIGKILL`, addressed to
  the runner's own process group id and nothing else. There is no `pgrep`, no
  `ps` scan, and no sleep-then-kill over unrelated processes.
* A signal is only ever sent after `group_alive?` has confirmed the group is
  non-empty. A process group id cannot be recycled while the group still has
  members, so the runner cannot signal an unrelated process.

## Failure handling

A defect in one case never stops the others. Case-level problems raise a
per-case failure, are reported as `PARITY FAIL <id>: <reason>`, and the runner
continues to the next case. The run ends with an aggregate
`GO-PROFILE PARITY FAIL: N failures across M selected cases` and a non-zero
exit. Pre-flight problems (bad flags, bad manifest, unauthenticated toolchain)
fail closed before any case runs.

A full-manifest pass prints `GO-PROFILE PARITY PASS: N/N`; a filtered run prints
`GO-PROFILE PARITY SUBSET PASS: N/M` and is never reported as full parity.

## Retained evidence

Artifacts are retained outside the worktree (`$TMPDIR` by default, or
`--artifacts`) and the path is printed as `ARTIFACTS RETAINED: <dir>`. Layout
per case, with the build tree and all evidence deliberately **outside** both
execution roots:

```
<artifacts>/meta.json                     run metadata, toolchain, binary digests,
                                          effect-detection disclosure
<artifacts>/<category>/<id>/
    evidence.jsonl                        one JSON record per phase
    generated.one.go  generated.one.go.map
    generated.two.go  generated.two.go.map
    transpile.one/  transpile.two/        sandboxes the two transpiles ran in
    build/           go.mod, main.go      build tree (not an execution root)
    artifact/lowered.bin                  the artifact, moved out of the build tree
    run/interpreted/                      execution root (contains .bashpp-run/home, /tmp)
    run/compiled/                         execution root, original source deleted
    *.stdout.raw  *.stderr.raw            raw bytes for every phase
```

## Self-test contract

`tests/lowering/go_profile_contract_test.rb` is the structural contract for the
runner. It requires the real artifacts to be supplied at runtime and refuses to
run without them:

```sh
CONTRACT_BASHY_CLI=... CONTRACT_ENGINE=... CONTRACT_SH_MODULE=... \
  ruby tests/lowering/go_profile_contract_test.rb
```

It separates two kinds of evidence, and labels each check accordingly:

* **MECHANISM** checks drive the runner with a fake transpiler and a fake
  engine. They exist to exercise gate mechanics — missing map, wrong map schema,
  unbound digest, non-determinism, build failure, exit mismatch, effect
  divergence in `HOME`/`TMPDIR`/`*.raw`, timeout, descendant drain, all-case
  continuation. They make **no** claim about Bash++ or about the real compiler.
  Their generated Go is still compiled for real by the pinned Go 1.27.0
  toolchain, and the typed-only scenarios import the real, reviewed
  `mvdan.cc/sh/v3/lower/shellrt` bridge from the real `sh` module — not a
  pretend stand-in.
* **ACCEPTANCE** checks drive the runner with the real transpile CLI, the real
  engine, the real `sh` module and the real pinned Go, over a `var x = 10;
  println(x)` fixture, in both default and `--typed-only` mode. They require the
  real source map to be present, schema-correct and digest-bound. They must pass.

Both positive and negative directions are pinned for the load-bearing gates: a
matching `HOME` write is accepted while a one-sided one fails, a descendant that
finishes inside the grace passes while one that outlives it fails, correct byte
coordinates into a multi-byte source are accepted while character-counted ones
are rejected, and a typed program whose comments name an interpreter is accepted
while one that imports `os/exec` is rejected. A gate that only ever fails proves
nothing.

The suite shares one Go build cache across its scenarios (`S117_GO_CACHE`,
default `$TMPDIR/s117-runner-correction-cache`). It creates the directory if it
is missing and never removes it: this suite does not clean up a directory it was
handed.

## Current status

The core compiled semantic diagnostics are not implemented yet, so the full
inventory **fails today, by design**. Measured against the current product CLI:

* **81 of 105** `artifact-run` identities execute and match. The 24 failures are
  13 transpilation refusals, 6 stdout divergences, 4 filesystem-effect
  divergences and 1 stderr divergence.
* **0 of 15** `semantic-reject` identities are certified. All 15 exit 2 and emit
  nothing, but every one produces a `LOWER-E*` error with a bare `line:col`
  position instead of the contracted `BASHPP-E*` diagnostic.

Those numbers are the honest state of the product, not a defect in the gate.
The gate is deliberately not weakened to accommodate them: a `LOWER-ETYPE`
message is not the contracted diagnostic, and accepting it would retire the
requirement rather than meet it.

## Known limitations

* Effect detection is snapshot-based; see the list above for what it misses.
* Parity is asserted per fixture on the host that ran it. Nothing here
  generalizes to fixtures that were not run, and a subset run is reported as a
  subset.
* A certified semantic rejection asserts the transpiler's diagnostic and the
  interpreter's observation. It asserts nothing about compiled behaviour,
  because there is deliberately no compiled artifact.
* The "no effect before the designated error" assertion for `semantic-reject`
  identities is a property of these 15 reviewed fixtures, not a general promise
  that an effectful program can reject early.
* The interpreter's Go build cache and module cache are written outside the
  compared tree, so what the interpreter's embedded compiler does inside those
  caches is recorded but not diffed.
* The `mvdan.cc/sh/v3` requirement in the generated module is satisfied by a
  local directory `replace`; the module's own version graph is not exercised.
* Timing-dependent or concurrency-dependent fixtures can diverge legitimately;
  this runner reports the divergence, it does not adjudicate it.
* The two runs are sequential, not concurrent, so wall-clock ordering effects
  between the modes are not modelled.
