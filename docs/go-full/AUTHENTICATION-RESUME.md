# SDK relocation and authenticated continuations

Sprint #118, Story #17, Story-ID `b5d3bd1bd24c`.

`product.rb` verifies current SDK bytes before product execution. When native
evidence names a previous SDK location, supply `--relocation PATH` to the preserved
move manifest. The default reviewed manifest SHA-256 is
`3d061c0322b546005acf7ce1878aee4e4382a7dd2820feeb4c570fa267a23c2e`.
`--relocation-sha256 SHA256` explicitly selects a separately reviewed mapping;
the runner never derives its trust digest from the mapping being checked.

Verification authenticates the manifest, every destination's complete membership,
file bytes, modes and totals, and exact path-boundary mappings. It compares every
non-location SDK identity field, then invokes `sdk.py --verify-existing` against
only the current locations and requires the entire freshly derived identity to
equal the claim. Obsolete paths are strings used for mapping, never opened or
recreated. Missing current archives or trees fail without download or materialization.
Original identities, SDK bytes and raw native logs remain unchanged.

The durable Sprint 118 paths are:

- SDK identity: `/Users/qiangli/.bashy/sprint118/sources/go-full-sdk-identity-relocated.json`
- Relocation manifest: `/Users/qiangli/.bashy/sprint118/sources/issue8-relocation.json`
- Current SDK root: `/Users/qiangli/.bashy/sprint118/sources/go-full-sdk/root`
- Current source root: `/Users/qiangli/.bashy/sprint118/sources/go-full/go`

## Continuation contract

Supply `--resume /absolute/previous/evidence` together with a **new**, absent
`--evidence` directory and the same candidate, SDK, source, module context,
timeout, tools and environment. All prior evidence directories must remain in
place. The runner does not rewrite old records or append to an interrupted run.

Before the first root, each new run writes `context.json`, binding the complete
3,495-root set (2,726 testdir, 743 typechecker, 26 package), inventory digests,
current SDK, candidate/provenance, native oracle files, module inputs, timeout,
environment and runner/validator files. A diagnostic shard still binds that full
set. Each attempted root has a `go-full-product-root/v2` record, immutable
`root-records/ID.json` receipt, original input digests and actual phase captures.
Completed receipts can survive an interruption before the final summary; a
partial last JSONL line fails closed and requires separately reviewed recovery.

Resume rejects duplicate or foreign IDs, legacy schemas, changed context,
missing provenance, changed receipts, changed original/copied/module inputs,
changed candidate or SDK, missing/tampered streams, duplicate capture streams,
changed commands/environment, and missing or reordered required phases.
The cache directory may differ between runs, but its key and policy must match;
each retained command must still name its own original authenticated cache.

Eligible terminal observations retain their original verdict:

- Simple run/build/buildrun recipes: all three modes and exact source-mode
  commands are checked. PASS additionally requires the shared strict validator,
  retained native/generated artifacts, valid source map, and independently
  recomputed differential and upstream-output results. A failing attempt can
  retain FAIL after complete captures establish failure; a justified failing
  phase prefix never grants credit to later unexecuted phases.
- Unsupported recipes with complete diagnostic probes retain FAIL and their
  entire independently derived unfinished-phase list. Probe success never
  substitutes for execution of those phases.
- `UPSTREAM_SKIP` requires the exact retained native skip/ancestor-skip event,
  source/root binding and no product execution claim. It remains subject to
  source-bound manager applicability adjudication; it is never product PASS.

Generator and diagnostic-matcher terminal records do not yet have independent
resume adapters. They are reported as requiring fresh execution. Missing-artifact
or otherwise incomplete attempts also require fresh execution. All roots remain
in the declared denominator. Prior fresh-required adapters run after unattempted
roots so bounded continuations can make progress without repeatedly replaying
the same unsupported adapter. Resume authentication is an integrity gate for
retained observations, not a signature proving execution or a replacement for
independent product replay. No original program body is forwarded to native Go
as interpreter coverage.

## Existing 1,209-root evidence

`/Users/qiangli/.bashy/sprint118/evidence/go-full/product-all/roots.jsonl` contains
1,209 distinct v1 rows: 285 PASS, 895 FAIL and 29 upstream skips. It has no
checkpoint context or final summary; rows lack the new top-level provenance and
receipt contract and refer to the historical published-002 candidate. It cannot
legitimately become a checkpoint by attaching new metadata, relabeling paths or
selecting one embedded provenance row. Preserve it as historical partial evidence
and execute a fresh v2 run. This change does not claim a complete corpus replay
or close the remaining product execution obligations.

## Independent bounded checks

```sh
ruby tests/go-full/authentication_test.rb
python3 tests/go-full/test_sdk_authentication.py
ruby tests/go-full/execution_test.rb
python3 tests/go-full/test_inventory.py
python3 tests/go-full/test_directory.py
```

The checkpoint tests use explicitly authored contract tools with real process
captures; their PASS is a validator unit result, never a corpus execution result.
Tamper cases reseal receipts where appropriate so that independent semantic
checks, rather than only an outer digest mismatch, must reject the mutation.

## Required module and shared-cache contract

Full product execution now requires `--module-context PATH`. The default reviewed
context digest is `a886a3618bcacccbb5df4030ad9e0f58442f3440a75dab3b6e62e6e0a4550dd6`;
`--module-context-sha256 SHA256` supplies an explicitly reviewed replacement.
The existing candidate006 manifest is
`/Users/qiangli/.bashy/sprint118/sources/go-full-candidate006-modules/manifest.json`.
Its module-files argument digest is
`67c580c9ebf262d50db38bc4fe70460dafcf21cf99cbbd0fbcbd11b0e527b376`.
It binds candidate006, not a later candidate binary or repository revision.

The runner authenticates the manifest before reading its configuration, current
candidate and SDK bindings, the two scaffold files, all 19 dependency archives
and module metadata files, and exact membership and bytes of 4,391 extracted
module files. The scaffold sums must match the declared dependency sums.
It rechecks these inputs and candidate binaries after execution. Original source
files remain independent, unchanged inputs. `--modules`, if also provided, must
contain exactly the authenticated scaffold bytes; it cannot override them.

`GOENV=off`, `GOWORK=off`, `GOFLAGS=-mod=readonly -p=2`, and the authenticated
`GOMODCACHE` are propagated into the actual executor environment. Network access
remains disabled. `--cache-root PATH` selects the build-cache parent; it defaults
to the manifest's declared parent. Its directory is keyed first by module
manifest digest, then by the shared executor's candidate/SDK/environment digest.
It cannot overlap the SDK, module cache, or candidate repositories.

Simple and generated-program execution, unsupported-recipe probes, typechecker
checks, and both diagnostic matcher build/run paths use that same keyed GOCACHE.
Each process retains its private working, home and temporary directories and
complete streams. Probe and checker workspaces receive the same scaffold bytes
as ordinary execution and verify those bytes after the phase. Cache sharing does
not alter original programs, compiler recipe arguments, phase obligations,
verdict rules or native delegation policy. No per-root cold GOCACHE is created by
the full-run configuration.

Checkpoint context now binds the authenticated module proof and exact module
and environment values. Resume checks those same settings in retained simple
executions and probes, including scaffold bytes and the original shared cache
path. The existing diagnostic/checker/generator resume limitations still apply;
new context is required, and old receipts are never upgraded.

The integration seam is `GoFullProduct.execution_setup`, which constructs the
executor and `options[:runtime]`. `GoFullProduct.stage_environment(runtime, dir)`
provides the shared environment/cache with per-process HOME and TMPDIR. Both
reviewed checker matchers use this seam without changing matching semantics.

```sh
ruby tests/go-full/module_context_test.rb
```

This test executes real authored fixture processes through the production setup
path and checks all three execution modes, probes, and both matcher/checker paths.
It also tests archive/tree/scaffold/SDK mutation, extra or missing dependency
files, symlinks, changed candidate/SDK claims, mutable module flags, duplicate
dependencies, and wrong retained cache/scaffold evidence. Authored fixture output
is validator evidence only, not official corpus success.

## Original typechecker language-version recipes

The pinned SDK `go/types/check_test.go` binds first-line `-lang` to `types.Config.GoVersion` (the types2 runner does the same). The product adapter now maps the exact original `-lang=go1.N` or separated `-lang go1.N` value to `--go-version=go1.N` in both checking modes. Repeated values use the last value, as upstream flag.FlagSet does. Unknown flags, absent/invalid values, multi-file checking and build-constraint applicability remain explicit unsupported obligations. No fixture bytes or diagnostics are rewritten.

The original 743-root typechecker inventory remains fixed. Exactly 50 previously unsupported single-file language-version recipes become adaptable: 713 adaptable and 30 still unsupported, including two native-skipped roots. The 16 other language-version recipes retain their independent build-tag blocker. Adaptability is not PASS; both original checking phases and exact annotation matching must still complete.

Mode evidence records the raw recipe flags and checker version alongside exact argv, immutable source hashes and environment/cache provenance. Tool changes invalidate earlier resume contexts; this does not upgrade any previous candidate006 row. New full runs require new candidate/module-context authentication.

`product.rb --phase-shard typechecker` runs the complete 743-root typechecker
axis after authenticating the full 3,495-root inventory and joining every native
root to its retained event log. The selection includes unsupported recipes and
native skips; it does not filter for adaptable or passing fixtures. Missing,
duplicate, or extra selected IDs fail before execution. Results retain the full
manifest denominator and are labeled `typechecker-phase-discovery-shard`, with
the existing explicit overall FAIL and incomplete runtime-coverage fields.
This diagnostic run cannot certify the other axes or close the sprint.
