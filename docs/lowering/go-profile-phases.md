# Go-profile compiler phases

Sprint 117 / Story 9 / Story-ID `e400885f8746`.

[go-profile-phases.tsv](go-profile-phases.tsv) assigns an explicit compiler
phase to all 120 identities from [go-profile-cases.tsv](go-profile-cases.tsv)
and [profile-additional.tsv](profile-additional.tsv). Their source files,
public test references, status codes and exact expected streams remain the
original contract. The five metadata columns are `id`, `phase`,
`source_sha256`, `reason`, and `public_test_ref`.

| Compiler phase | Cases | Required result |
|---|---:|---|
| `artifact-run` |105|Build and execute a native artifact: 100 successful runs and 5 runtime errors.|
| `semantic-reject` |15|Reject the particular language-invalid source with the exact expected semantic diagnostic, status 2, and no emitted Go or source map.|

The original manifests record interpreted observations. Their public tests
parse source and invoke the interpreter; they do not assign a compiler phase.
The interpreter must still execute every case and match its original status
and streams. This metadata adds a separate compiler contract for invalid
programs; an arbitrary compiler error is never a successful negative test.

Each row binds the phase to exact source bytes and the original public
reference. Missing, duplicate or unknown identities, changed source hashes,
unknown phases, and a changed 105/15 split fail the contract. Validate it with:

```sh
ruby tests/lowering/go_profile_phases_test.rb
```

## Artifact observations

All 105 `artifact-run` cases require successful deterministic transpilation,
a valid source map, a real native build and source-absent artifact execution.
Compare exact stdout, stderr, exit status and filesystem effects with the
interpreter and original manifest. A transpiler rejection cannot substitute
for executing one of these cases.

The five required runtime failures are `assert-fail-neg`, `nil-deref-neg`,
`readonly-clear-neg`, `readonly-bypass-neg`, and `panic-unrecovered`. They
exercise dynamic assertion failure, nil dereference, runtime readonly state
and aliasing, or panic unwinding. The panic case must retain its preceding
`before\n` output and suppress subsequent effects. Readonly shell commands
change runtime state; they are not interchangeable with static annotations.

## Semantic diagnostic observations

The 15 exact `semantic-reject` cases have a statically invalid operand,
declaration, type relationship, generic call or receiver. Each row states the
specific violation. Inspection of these exact fixtures found no printed
output or external filesystem/process effect before the designated error.
Some first create types, constants, functions or local values; this contract
makes no general promise that arbitrary effectful programs can reject early.

A semantic-rejection gate must:

- Run both independent transpile attempts and require exact status 2 and the
  full original stdout/stderr bytes, with a recognized semantic diagnostic.
- Require no emitted Go or map, unchanged input and no undeclared side effects.
  Keep diagnostic streams and evidence even when the gate fails.
- Independently execute the interpreter and require the original observation.
  A timeout, forced descendant kill or incomplete lifecycle cannot pass.
- Reject `LOWER-EUNSUPPORTED`, raw Go/type-check failures, incorrect diagnostic
  identities, partial output, wrong statuses and missing evidence.

Rendered diagnostic text is part of the contract. `cap-type-neg` requires
both its cap operand-type error and the positioned `BASHPP-ESHORT-NONEW`
secondary error. `undefined-receiver-neg` requires the exact legacy text
`invalid receiver type Missing (type is not declared in this session)\n`;
it has no `BASHPP-` prefix. A structured diagnostic identity may retain that
rendering. Prefix-only matching or accepting arbitrary unprefixed Go errors
would weaken the contract. Likewise, `cannot-infer-neg` requires the specified
inference error, even if an ordinary Go compiler would diagnose its generic
function body first.

Future fixtures with effects before an error require explicit review of those
effects and their execution phase. Their behavior must not be discarded to
fit the diagnostic phase. Existing 33 Bash# lowering cases have their own
explicit `run`/`reject` ledgers and remain a separate denominator. For example,
Bash#'s static `BASHPP-ENULL-DEREF` warning is distinct from this profile's
runtime `BASHPP-ENIL-DEREF` error.

Report the totals as 120 phase-aware cases: 105 artifact observations and 15
semantic diagnostic rejections. This is not 120 native executions. The metadata
and structural test alone establish no transpiler or runtime acceptance.
