# S157.2: direct Bash++ backend

Story `31520c72b5e0` keeps the authenticated Go 1.27
`cmd/internal/testdir` runner as the sole recipe authority. Two small patches
attach at its existing `planExec`/`runcmd` boundary. They do not select tests,
parse recipes, infer companions, or reproduce the action switch.

For an upstream `execute` phase, the backend receives the exact
`compileInputs` and `programArgv` slices already selected by the Go runner.
Interpreted mode invokes:

```text
bashy --bashpp --source=go --check --go-file <input> [...]
bashy --bashpp --source=go --go-file <input> [...] [-- <program argv>]
```

Compiled mode invokes `bashy transpile --bashpp --source=go` with the same
repeated `--go-file` inputs, builds the generated Go source with the pinned Go
1.27 tool and caller-supplied pinned shell runtime, and executes that artifact
with only `programArgv`. The original native Go command is never executed in a
backend phase. A minimal shell coordinator keeps check/run and
transpile/build/run inside the upstream command timeout boundary; it receives
only those direct-source commands, never the upstream native argv. A phase
without Go source inputs, a non-Go input, or a recipe phase without direct
run-program meaning fails explicitly as unsupported. Sprint 149 adds one
narrow exception: an upstream `compile` action's `compile` phase runs Bash++
check-only in interpreted mode, or transpile-with-map then pinned-Go build-only
in compiled mode. It never executes the generated program.

The backend records one small JSON event for each observed upstream phase. The
event repeats the mode, structured action and recipe flags, source/argument
boundary, native argv evidence, tool identity, disposition, and declared
deviations. `backend-verify.go` checks the one-to-one phase/event identity and
the required canaries. Compiled compile results additionally prove the actual
generated source, map, and artifact by path, existence, size, and SHA-256. The
verifier does not make recipe decisions.

## Behavioral delta

`fixedbugs/issue21808.go` passes in both modes with the exact five-byte combined
output selected by the upstream comparison. `cmplxdivide.go` retains both Go
files as compile inputs and an empty program argv. Compiled mode passes. The
current direct interpreter exits 2 on its unsupported `complex128` collection
element; the upstream harness therefore reports an expected, honestly retained
failure. The other authenticated rows are either explicit unsupported backend
phases or unchanged upstream skip/bypass decisions.

The backend deliberately does not translate native Go flags for S157 execute
phases because the direct Go-source interface has no representation for them.
For the compile-only exception, exact upstream recipe flags are transported as
structured values and, when non-empty, become one unpatterned
`-gcflags=<space-joined flags>` argument to the pinned Go build. The native argv
is retained only as evidence. The backend also disables the upstream `go run`
fast path while backend mode is selected so that the existing source-execution
plan reaches the seam.

## Verification

`tools/upstream-harness/backend-gate.sh` first runs the S157.1 native-equivalence
gate, authenticates every source and patch, and then exercises all nine matrix
rows in each backend mode. It requires a non-POSIX startup environment because
the direct Go-source interface intentionally refuses POSIX mode; the environment
received at the seam is otherwise preserved.

The local gate passed through `bashy gate` in 47.885 seconds with Go 1.27,
Bash++ version `118bb3f`, and shell runtime commit
`01bbf2e957970e689b6ed2bf4f0a1633b99709a0`.

On 2026-09-11 at 07:06Z, one authoritative Linux coordinator passed the exact
reviewed candidate through `bashy gate` in 3m20.123s on
`root@138.68.155.86`. It used:

- Go 1.27 Linux/amd64 binary SHA-256
  `1db869c560a193573a71be466a34e0d4abb7792d78165c6102cdda069276a3a8`;
- Bash++ source commit `118bb3f6841a57a7010b7858bf02564c445416f7`
  and Linux binary SHA-256
  `b5d2b6b30a4c890b9005b4acb58ea176b93208375b882c2de0e559b2e115b80d`;
- shell runtime commit `01bbf2e957970e689b6ed2bf4f0a1633b99709a0`;
- the authenticated Go 1.27 corpus and unchanged S157.1 runner pin.

The host's inherited `POSIXLY_CORRECT=1` was explicitly absent from the
authoritative gate environment. An earlier run retained that host selector and
failed interpreted mode exactly as Bash++ specifies; compiled mode and native
9/9 equivalence still passed in that diagnostic run. The accepted rerun had no
second coordinator, and the post-run process table contained no surviving gate,
test, compiler, linker, or Bash++ process.
