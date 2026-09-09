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
