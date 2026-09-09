# Tour three-mode executor (`tour-executor/v2`)

Sprint 118 / Story #4 / Story-ID `759341a95870`.

A deterministic executor for the pinned go.dev/tour denominator: it copies all
**93 applicable + 4 build-only** official programs with their BSD provenance,
provisions the official `golang.org/x/tour` helper module, and runs the
declared pinned Go baseline, Bash++ interpreted and Bash++ compiled modes,
recording exit status, raw stdout/stderr and explicit normalization for every
one of the **291** observations.

## Current status — read this first

The gate **FAILS**, and that is the accurate result. The failures are real
product failures on a real, manifest-authenticated candidate, and they are
retained verbatim.

```
tour-executor/v2 FAIL: 291/291 observations
  baseline     PASS=97
  interpreted  PASS=23  FAIL:run:exit:2=45  FAIL:run:exit:1=29
  compiled     PASS=54  FAIL:build:exit:1=27  FAIL:transpile:exit:2=16
  candidate: authenticated
  semantic:  10 rows, 70 native oracle runs
```

What that says:

1. **The Go-source frontend exists and works.** Against the diagnostic
   candidate (`frontend_version: gosource-v1`), `bashy --bashpp --source=go`,
   `--check` and `bashy transpile --bashpp --source=go … --map …` all parse,
   ingest Go and emit a valid source map. 23 of 93 rows run correctly
   interpreted and 54 of 97 complete the transpile+build pipeline. The earlier
   report that these selectors were unimplemented is superseded: it was
   produced against a default build without the frontend.
2. **The remaining failures are product defects, recorded per stage**, e.g.
   `BASHPP-EEXPR-FORM: unsupported scalar call` for `rand.Intn(10)` used as a
   call argument in interpreted mode (the same row's compiled mode passes).
   Nothing here converts a defect into a pass, a skip or a not-applicable.
3. **The baseline is green across all 97 rows**, including the ten
   nondeterministic ones, which are now adjudicated by reviewed semantic
   comparators against a fresh native oracle rather than against a frozen draw.

The historical failure evidence for this story — `tests/tour/evidence.jsonl`,
produced by the superseded `tour-evidence/v2` runner — is **untouched**. The
new ledger is a separate artifact, `tests/tour/executor-results.jsonl`.

## Running it

```sh
# 1. produce the ledger (needs network once, to provision the helper module)
BASHPP_BIN=/path/to/candidate/bin/bashy \
TOUR_CANDIDATE_MANIFEST=/path/to/sprint118-evidence/<candidate>/candidate.json \
  bash tools/tour/run-executor.sh

# 2. audit it offline — no product, no toolchain, no network
bash tools/tour/validate-executor.sh

# 3. prove the gate itself, on a synthetic fixture that PASSES
bash tools/tour/executor-selftests.sh

# 4. prove the semantic comparators reject
bash tools/tour/semantics-selftests.sh

# 5. prove the gate on the REAL ledger, one mutated fact at a time
bash tools/tour/executor-tamper-tests.sh
```

| Variable | Meaning |
|---|---|
| `BASHPP_BIN` | candidate `bashy` launcher (required) |
| `TOUR_CANDIDATE_MANIFEST` | manager-supplied build manifest JSON (required) |
| `TOUR_CORPUS_ROOT` | committed corpus root (default `tour/`) |
| `TOUR_EXECUTOR_RESULTS` | ledger path |
| `TOUR_EXECUTOR_EVIDENCE` | durable root for raw capture logs and artifacts |
| `TOUR_ORACLE_REPEATS` | native repeats per volatile row (default 7) |
| `TOUR_STEP_TIMEOUT` | per-stage bound in seconds (default 60) |
| `TOUR_ONLY` | substring filter for development; marks the ledger `partial`, which the gate rejects |

## Files

| Path | Role |
|---|---|
| `docs/tour/executor-contract.tsv` | the argv, stage decomposition and body-execution policy of every (applicability, mode) pair — single source of truth for producer *and* gate |
| `docs/tour/phase-migration.tsv` | the checked bridge from the pinned historical inventory schema to the current executor phase contract |
| `docs/tour/candidate.tsv` | which components the build manifest must bind, and how the launcher/payload pair is digested |
| `docs/tour/volatility.tsv` | the measured nondeterminism record |
| `docs/tour/semantics.tsv` | the reviewed comparator bound to each of those ten rows |
| `tools/tour/semantics.rb` | the comparators themselves |
| `tools/tour/executor.rb` | contract, scoring, candidate authentication, normalization audit, and the thin adapter over the shared capture primitive |
| `tools/tour/executor-runner.rb` | produces `tests/tour/executor-results.jsonl` |
| `tools/tour/executor-gate.rb` | offline gate |
| `tools/tour/executor-selftests.rb` | unit + end-to-end gate tests on a synthetic fixture |
| `tools/tour/semantics-selftests.rb` | negative-first comparator tests |
| `tools/tour/executor-tamper-tests.sh` | differential tamper probes against the real ledger |
| `tests/tour/executor-results.jsonl` | the `tour-executor/v2` ledger |

Unchanged and deliberately preserved: `tests/tour/inventory.tsv`,
`tests/tour/results.tsv`, `tests/tour/evidence.jsonl`, `tour/` (the corpus),
`docs/tour/pin.tsv`, `docs/tour/differential-schema.tsv`,
`tools/tour/normalize.rb`, and the whole `evidence.rb` / `evidence-runner.rb` /
`evidence-validator.rb` family.

## The shared capture primitive is mandatory

Every subprocess this corpus runs goes through `Corpus.capture` in
`tools/corpus/executor.rb` (W2, Story-ID `e29305614139`): argv with no shell, an
explicit environment with `unsetenv_others`, file-backed raw streams, a
monotonic deadline, its own process group, a swept group and a
surviving-descendant check.

`tools/tour/executor.rb` contains **no capture implementation and no fallback**.
If the shared library is absent or does not expose `Corpus.capture` /
`Corpus.authenticate_candidate`, the corpus aborts — a ledger produced by an
unreviewed capture path is not evidence. `TourExecutor.run` is a thin adapter:
it calls the primitive, reads back the file-backed `.stdout`/`.stderr` logs,
**re-checks each against the digest the shared library recorded**, and converts
them into the normalized, base64-bound data the ledger needs. It does not
duplicate spawning, deadline enforcement or process cleanup.

The manifest binds `capture_implementation` and the SHA-256 of the shared
library itself, and the gate rejects a ledger that claims any other capture
path (`capture:implementation`, `capture:library_sha256`). A previous draft of
this corpus shipped a private `TourExecutor.capture` plus a runtime probe that
would "adopt the shared library when it appears", and a
`docs/tour/executor-shared-api.md` describing an API that did not exist. Both
are gone: the real API is used, and the file that speculated about it has been
deleted.

## Candidate authentication is the supplied manifest, verbatim

The candidate is authenticated by handing the manager-supplied
`candidate.json` to `Corpus.authenticate_candidate`, which verifies the
launcher digest, the adjacent `.real` payload digest, and that **every listed
repository is at the stated revision with a clean tree including untracked
files**. Authentication failure aborts the run.

Two rules were superseded:

* the `tour-evidence/v2` rule that a candidate had to be a **published release
  tag** (`tools/tour/evidence-runner.rb` still aborts without one), which made
  a Makefile build untestable; and
* the first `tour-executor` draft's **derived** binding, which resolved sibling
  worktrees by convention and compared them to the commit stamped in
  `bashy --version`. That relates the binary to whatever happens to be checked
  out beside it, which is not a binding at all. `candidate:binary_commit_not_head`
  and `TourExecutor.product_identity` are gone.

`docs/tour/candidate.tsv` declares the five components that must appear in the
manifest — `bashy`, `sh`, `coreutils`, `readline` and **`filebrowser`**. All
four dependencies are `replace`d in bashy's `go.mod` with sibling worktrees
whose commits the binary does not embed; `filebrowser` is the easy one to miss
because it enters `require` as an indirect dependency. The gate rejects a
declared component missing from the manifest (`candidate:unbound:<name>`) *and*
a manifest repository this contract never declared
(`candidate:undeclared_repository:<name>`, `candidate:repository_set`), so
neither direction can hide unreviewed product code.

The diagnostic candidate used for the run above is
`diagnostic-candidate-001`: launcher `454c25a8…`, payload `1126896175…`, built
`GOTOOLCHAIN=go1.27.0 … make build BASHY_GOSOURCE=1`, binding
`bashy 9298523…`, `sh 9c14f863…`, `coreutils ec91ea45…`, `readline b958823b…`,
`filebrowser cde11469…`. Its manifest records `status: diagnostic tag-enabled
build; not final default candidate`, and the ledger carries that string.

## Semantic comparators for the ten volatile rows

Ten rows of the denominator cannot reproduce a byte-exact digest. They are
measured in `docs/tour/volatility.tsv` and adjudicated by
`docs/tour/semantics.tsv` + `tools/tour/semantics.rb`.

**The anchor is a fresh native oracle, not the frozen baseline.** For each of
the ten rows the runner executes the very native binary the baseline stage just
built `TOUR_ORACLE_REPEATS` more times (default 7) and records every run — exit,
signal, raw streams, timestamps — as an `oracle` ledger record bound to that
binary's digest. All three modes are then compared against those repeats. The
pinned observation in `tests/tour/results.tsv` is **retained as historical**: for
these ten rows its exit statuses and stage shape are still enforced, its stream
digests are recorded as `historical_accepted` and are no longer a required
output, because they record one draw of a nondeterministic program on one day.

**Each comparator is narrow, and bound to one program.** The table carries the
row's pinned source digest; the loader refuses to bind a comparator to a row
whose inventory digest differs, so a comparator cannot be retargeted at an
easier program.

| Row | Comparator | What is verified |
|---|---|---|
| `basics/packages.go` | `rand_intn_line` | exactly one line, exact surrounding text, value in the declared support `0…9` |
| `concurrency/goroutines.go` | `say_interleaving` | closed line vocabulary, main's multiplicity exactly 5, the goroutine's multiplicity inside the natively observed range; only the interleaving is free |
| `concurrency/default-selection.go` | `tick_boom_sequence` | line grammar, exactly one BOOM and it is terminal, elapsed never decreases, the i-th tick cannot precede *i*×100 ms, BOOM cannot precede 500 ms, tick count inside the native range, at least one default selection |
| `flowcontrol/switch-evaluation-order.go` | `weekday_switch` | exact prompt, closed value set, and the answer **computed from the recorded run window** — a set member that disagrees with the clock the run actually had is rejected |
| `flowcontrol/switch-with-no-condition.go` | `hour_greeting` | closed value set plus the same clock derivation |
| `methods/errors.go` | `go_time_error_line` | every byte but the timestamp is exact; the timestamp must be a Go `time.Time` rendering, carry a plausible monotonic reading, and fall inside the run window |
| `methods/exercise-stringer.go`, `solutions/stringers.go` | `line_set` | exact line set, each line exactly once, order free — a wrong octet or a wrong rendering is rejected, and the two rows expect *different* renderings |
| `solutions/webcrawler.go` | `webcrawler_crawl` | closed URL vocabulary, exact page bodies, each page found and completed exactly once, exactly one error for the unfetchable URL, every `-> Crawling child` paired with its `<- Waiting for child` **and preceding it**, and a complete exact statistics block; only goroutine interleaving and the already-fetched short-circuit count are free |
| `welcome/sandbox.go` | `sandbox_time` | fixed greeting exact, timestamp shape + monotonic + run window |

**What is never semantic.** Exit status and stderr are compared **exactly**
against the oracle for every one of the ten rows. Only stdout is adjudicated,
and only for the element `volatile_element` names.

**The comparators check themselves.** Every invariant is applied to every
oracle observation as well as to the candidate: a comparator too loose to
describe the real program, or too tight to admit it, fails on the oracle before
it can excuse anything (`oracle:invariant_violation:*`). Where the volatile
element must vary within a burst, an oracle that produced one single distinct
stdout is a failure (`oracle:no_variation_observed`) — that is evidence the
comparator is not needed there. An oracle thinner than
`TourSemantics::MIN_ORACLE_RUNS` is a failure, not a licence.

**The gate does not take a verdict on trust.** It re-runs
`TourSemantics.compare` from the ledger's own raw bytes and the ledger's own
oracle and requires an exact match (`semantic_forged:`). Clock-dependent
comparators are evaluated against the recorded window, so the audit is
reproducible offline; the window itself is **derived**, not asserted — both
producer and gate compute it from the same timestamps
(`TourExecutor.semantic_window`), and the gate additionally bounds its length
and requires it to sit inside the manifest's run window
(`semantic_window_forged:`, `semantic_window_length:`,
`semantic_window_outside_run:`).

`tools/tour/semantics-selftests.rb` drives every comparator with wrong values,
wrong counts, wrong sets, wrong order, wrong exit status, wrong stderr, wrong
timing, degenerate oracles and **every other row's output**, and requires
rejection: 145 checks.

## Semantic migration: the pinned phase string and the current contract

The pinned inventory spells the build-only rows'
`bpp_compiled:transpile-build-run`, `bpp_interpreted:parse-or-run` and
`baseline:go-test-or-build`. Every one of those tokens contains a `run` the
master execution plan forbids for a `norun` row.

**The current master plan outranks the stale pinned string.** The four
build-only rows execute **no body** in any mode: baseline builds and stops,
interpreted uses the semantic `--check` selector, compiled stops after
`go build` of the transpiled Go. The current phases are named honestly —
`build-no-run`, `check-no-run`, `transpile-build-no-run`.

**The historical inventory schema is preserved byte-for-byte.**
`tests/tour/inventory.tsv`, `docs/tour/pin.tsv` and
`docs/tour/differential-schema.tsv` are untouched, and `tools/tour/validate.sh`
keeps deriving its vocabulary from them unchanged.

`docs/tour/phase-migration.tsv` is the bridge, and the gate enforces **both
ends**: every executable inventory row must still declare exactly the
historical token the table names (so the pinned schema cannot be quietly edited
into agreement), and the contract must declare exactly the current phase and
body policy the table names (so the new behaviour cannot be quietly widened
back into running a `norun` body). Each observation carries both its current
`phase` and its `historical_phase_token`, so a ledger row still joins to its
inventory row by identity.

## Input absence: exactly what is claimed, and no more

A `run` stage that executes a **native artifact** runs from a fresh, empty
runtime directory — the compilation inputs are moved to the durable artifact
directory first, so the artifact cannot read its own source out of its cwd —
with an **empty `PATH`**. Interpreted mode runs with an empty `PATH` too, but
necessarily keeps its module context, because the source *is* its input.

Every body stage records that exact scope:

> compilation cwd emptied before native execution; body PATH empty;
> interpreted mode necessarily retains its own source/module context;
> no OS sandbox

This is **cwd and command-lookup isolation**. Ruby does not deny a program
access to an absolute path, and no container or seccomp policy is in play, so
no source-inaccessibility certification is claimed. The gate rejects a stage or
a manifest that claims an OS sandbox (`input_absence:os_sandbox_claimed`), a
weakened scope string (`input_absence:scope`), a body stage with a populated
`PATH` (`input_absence:path`) or a native body stage that ran in the module
directory (`input_absence:cwd`). An OS-level certification would need a
manager-supplied container or equivalent gate.

`GOROOT` names the pinned SDK and is supplied **identically to all three
modes**: the product resolves Go stdlib imports through it exactly as
`go build` does, and withholding it from one mode would compare two different
environments rather than two engines. It is toolchain configuration, not a
source-access grant, and the input-absence scope above says so.

## Source maps must describe their own artifact

`--map` writes the transpiler source map. The ledger records its schema
version, its `origin`, the per-mapping `source_file` set, the mapping count,
whether every mapping carries positive line/column positions, and the
`go_digest` it claims for the generated Go. The gate requires the origin and
the source files to be **this row's original upstream path**, and the
`go_digest` to equal `sha256:` + the digest of the generated Go **that same
stage produced** (`source_map_generation_digest`). A map that describes another
file or another artifact is not preservation.

## Fresh per-mode state

Each mode gets its own freshly materialized, read-only (0444) module tree —
`go.mod`/`go.sum` for the pinned helper, the upstream `LICENSE` (BSD
redistribution requires the license to travel with the code), and all 97
sources verified byte-for-byte against their inventory rows on the way in.
Each **(row, mode)** additionally gets a fresh `HOME`, `TMPDIR`, artifact
directory and runtime directory. After every mode finishes, all 97 sources are
re-verified in both the materialized tree and the committed corpus: "original
upstream bytes unchanged" is only evidence if it is checked on the way out too.

Raw capture logs and every produced artifact stay on disk under
`TOUR_EXECUTOR_EVIDENCE` (default `.cache/tour/executor-evidence/`), next to
the ledger's base64 copy of the same bytes.

## The normalizer is unchanged, and the gate audits it

`tools/tour/normalize.rb` keeps its `tour-normalizer/v1` rules exactly as
pinned: a strict UTF-8 gate (invalid bytes are rejected, never transliterated),
CRLF/CR → LF, and pointer-sized (≥8 hex digit) values → `0xADDR`. Nothing else.
Timestamps, random draws, goroutine interleavings and scratch paths are **not**
masked — that is precisely what the comparators exist to adjudicate instead.

The gate does not take the recorded normalization on trust. For every stream of
every stage it decodes the stored raw bytes and recomputes the declared v1
rules with an **independent reimplementation** (`TourExecutor.audit_normalize`),
requiring an exact match on length and digest (`normalizer_drift:`). A second,
separate check flags any stream that survived normalization as nothing, or that
lost more than a quarter of its bytes (`blanket_masking:`).

## Denominator

The full-97 denominator is enforced in four independent places: the runner
aborts unless the inventory yields exactly 97 executable rows split 93 + 4; the
gate re-derives the same split from `tests/tour/inventory.tsv` itself; the gate
requires exactly 291 observations forming the complete (row × mode) cross
product with no duplicates and no unknown rows; and a `partial` ledger (any
`TOUR_ONLY` run) is rejected outright. The 71 `excluded_fragment` rows keep
their existing `exception:fragment` reason and stay outside the executable
denominator; an executable row citing any exception other than `none` is a
gate failure.

## What the gate rejects

| Class | Findings |
|---|---|
| missing | `missing:`, `observations=`, `denominator:`, `stage_count:` |
| PLANNED | `placeholder_status:` (PLANNED, TODO, SKIP, PENDING, …) |
| unexpected N/A | `placeholder_status:N/A`, `unexpected_na:`, `unexpected_exception:` |
| mismatched | `not_pass:`, `status_forged:`, `accepted_mismatch` |
| capture provenance | `capture:implementation`, `capture:library_sha256` |
| forged commands | `argv_literal:`, `argv_src:`, `argv_go:`, `argv_bashy:`, `artifact_set:` |
| stage substitution | `stage_substitution:`, `source_map_missing:`, `source_map_empty:`, `source_map_origin:`, `source_map_generation_digest:`, `source_map_unpositioned:` |
| body execution | `body_executed:`, `execute_body_drift:` |
| phase contract | `phase_drift:`, `historical_phase_drift:`, `phase_migration:*` |
| candidate | `candidate:unbound:*`, `candidate:undeclared_repository:*`, `candidate:repository_set`, `candidate:missing_payload`, `candidate:frozen_mismatch:*`, `candidate:unauthenticated_manifest`, `candidate:runner_hid_failures` |
| isolation claims | `input_absence:scope`, `input_absence:cwd`, `input_absence:path`, `input_absence:os_sandbox_claimed` |
| normalization | `normalizer_drift:`, `blanket_masking:`, `utf8_claim:` |
| semantic comparison | `semantic_forged:`, `semantic_undeclared:`, `semantic_no_oracle:`, `semantic_window_forged:`, `semantic_window_length:`, `semantic_window_outside_run:`, `semantics:*` |
| native oracle | `oracle:row_set`, `oracle:repeats:`, `oracle:source_binding:`, `oracle:run_not_clean:`, `oracle_binary_mismatch:` |
| binding/integrity | `binding:*`, `toolchain:*`, `helper:*`, `duplicate:`, `root:tampered`, `verdict:forged` |

`tools/tour/executor-selftests.rb` builds a synthetic 97-row / 291-observation
fixture **with a real oracle record and a real comparator verdict** that
**passes** — proving the gate is capable of passing and is not merely always
red — and then mutates exactly one thing per case, requiring the expected
finding each time. `tools/tour/executor-tamper-tests.sh` repeats that exercise
against the **real** ledger, differentially: each expected finding must be
absent from the gate's report on the pristine ledger and present after the
mutation.

## Open items for the manager

1. **Product defects, not harness gaps.** The interpreted and compiled failures
   above are recorded per stage with their real diagnostics. The largest
   interpreted class is `BASHPP-EEXPR-FORM: unsupported scalar call`; the
   largest compiled class is a `go build` failure on the transpiled Go. Each is
   a W1 lowering/eval item, visible row by row in the ledger.
2. **Frozen candidate commits.** `docs/tour/candidate.tsv` leaves
   `frozen_commit` empty; the manager fills it when the integrated revision set
   is frozen, after which the gate enforces equality against the manifest.
3. **Default-candidate rerun.** The run above used the diagnostic
   `BASHY_GOSOURCE=1` build, whose own manifest says it is not the final
   default candidate. The same command reproduces the ledger against the
   default candidate once the frontend ships there.
4. **OS-level source denial**, if it is ever required as a certification rather
   than a cwd control, needs a manager-supplied container or equivalent gate;
   this corpus states its limited scope instead of claiming one.

## Artifact identity and comparator correction (Sprint 118)

The gate re-renders every command placeholder from the row, mode, candidate,
and evidence root. A compiled run must use its own produced binary; a compiled
build must consume its own transpiled Go. Input artifacts are hashed before
execution and their identity is checked against the preceding producer. Candidate
component contracts and revisions must agree with the declared repository set.

Timer comparisons require each default branch's 50ms sleep (allowing 1ms for
rounded timestamps) and native-observed event counts. Crawler comparisons bind
the exact pinned graph, all URL-bearing events, and per-URL multiplicity.

Previously captured ledgers lack input-artifact observations and cannot satisfy
this corrected gate. Their raw observations remain diagnostic history; fresh
execution is required for acceptance. The checked-in failing ledger is such a
historical diagnostic, not evidence of passing the corrected rules.
