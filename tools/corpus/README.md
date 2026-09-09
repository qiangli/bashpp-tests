# Shared unchanged-Go execution contract

Sprint #118, Story-ID `e29305614139`. Ruby standard library only. `executor.rb`
is reusable process, provenance and phase machinery. `validate.rb` checks an
independent expected inventory against retained evidence. Corpus workers own
upstream inventory rules, diagnostic matching, test drivers, generators, network
control and semantic comparators; these must not be silently approximated by
this library.

```ruby
require_relative '../corpus/executor'
executor = Corpus::Executor.new(
  bashy: '/absolute/candidate/bashy', go: '/absolute/sdk/bin/go',
  evidence_root: '/durable/s118/tour',
  candidate: JSON.parse(File.read('candidate.json')),
  sdk: { 'sha256' => pinned_go_sha, 'identity' => pinned_go_version },
  timeout: 60
)
record = executor.execute(
  id: 'hello', source_root: '/pinned/upstream', sources: ['hello.go'],
  assets: ['templates/index.html'], phase: 'run', args: [],
  module_files: { 'go.mod' => reviewed_module_bytes }, runtime_env: {}
)
```

Candidate keys (strings): `launcher_sha256`, `payload_sha256`,
`frontend_version`, `build_recipe`, `repositories: [{path, commit}]`.
The launcher and its adjacent `.real` payload are hashed separately. Every
repository must be at the supplied clean revision including untracked files.
The manager supplies the authenticated build manifest; the library does not
infer that an arbitrary binary was produced by an asserted build recipe.
SDK executable digest and exact `go version` output must match supplied pins.
Include all replaced runtime dependencies in `repositories` and the reviewed
`go.mod`/`go.sum` in `module_files`; module bytes are hashed in every result.

`execute` returns string-keyed evidence with `modes` keys `baseline`,
`interpreted`, `compiled`. For `phase: 'run'` their stages are respectively:

- `go build -o program original.go`, then the native `program`.
- `bashy --bashpp --source=go original.go [args...]`.
- `bashy transpile --bashpp --source=go original.go -o generated.go --map generated.go.map`,
  then real `go build -o program generated.go`, then the native `program`.

For `phase: 'build'`, native run stages are omitted and interpreted mode calls
`bashy --bashpp --source=go --check original.go`. A successful parse is never
accepted as a semantic check. No `go run`, obsolete `--compile`, or shell syntax
fallback is used. `package_input: '.'` selects the explicit package-directory
CLI contract for multi-file inputs; all source files still belong in `sources`.
`subdir` and `./subdir` both become `./subdir` for native Go builds; paths with
parent traversal, empty components or absolute roots are rejected.
An unsupported package CLI fails as a stage failure, never a successful skip.

Original source/asset paths are relative and may not traverse or contain
symlinks. Every mode receives fresh inputs preserving relative asset paths,
private HOME/TMPDIR and its own module context. Go builds share one cache keyed
by candidate, SDK, platform, executor and build environment; `cache_root:` can
select its parent directory (default `evidence_root/.cache`). The key, policy
and absolute cache path are bound in provenance. Concurrent Go cache users
share the same immutable candidate context, avoiding one stdlib rebuild per
case/mode. A changed candidate or SDK obtains a different cache directory. Original files are
hashed before and after all execution, source copies are checked after stages,
and generated files cannot replace an upstream input. Runtime assets may
change in the mode workspace; their effects are compared to the oracle.

All three modes run from fresh runtime directories containing only declared
assets, with the same supplied `runtime_env` overrides. Interpreted mode reads
the absolute copied source/package path in its retained module directory; the
product must resolve imports relative to that source/module context.
The compilation cwd is emptied before native execution, and the default runtime
PATH is empty. Explicit `runtime_env: {'PATH' => reviewed_command_directory}`
is necessary for process examples. This is **cwd and command-lookup isolation**;
Ruby does not deny access to absolute source/SDK locations. Runtime Go
environment settings are retained equally across modes for import bridges;
empty PATH is command lookup restriction, not SDK removal. Durable source and
artifact copies remain for review. An OS-level source/SDK denial certification
requires a manager-supplied container or equivalent sandbox gate. The record
states this limited scope, never claims full source inaccessibility.

Every subprocess uses argv (no shell), an explicit environment without inherited
secrets, file-backed raw stdout/stderr, monotonic deadline, separate process
group, status/signal, duration, and cleanup. Surviving children fail the stage.
A timeout, absent tool, empty/missing generated/native artifact, executable script masquerading as a
native binary, invalid source-map schema/positions/digest or source mutation fails closed. A nonzero native program exit remains
an observation and can match `os.Exit` across modes. Build failures cannot.

Default verdict compares exact stdout/stderr bytes, exit/signal and filesystem
effects. No normalizers are applied. Runtime nondeterminism and negative-program
phases need corpus-specific adjudication; an unsupported recipe stays FAIL.
For advanced recipes use:

```ruby
Corpus.capture(argv, cwd: work, log_prefix: durable_log_prefix,
               env: explicit_environment, timeout: 30, stdin: input_file)
Corpus.success?(stage)
Corpus.file_record(path)
Corpus.snapshot(work)
```

`Corpus::Validation.validate!(records, expected:, provenance:)` requires an
independently constructed map `id => {phase, sources, assets, inputs, args,
module_files, package_input, runtime_environment}` (string keys), validates
exact phase/command/artifact/log identities and rejects missing/duplicate modes
or rows. Do not derive expected inventory from the result being validated.
Hash validation detects modification, not fabrication by a writer able to
rewrite every hash. Independent execution replay is required before story
closure. This generic validator accepts only exact comparisons; corpora with
reviewed semantic comparison must validate their own adapter evidence as well.

Run `ruby tests/corpus/executor_test.rb`. Tests deliberately exercise rejection
and real native Go execution; they provide no fake successful Bash++ candidate
and are not Sprint 118 corpus certification.

Test-program (`_test.go`), errorcheck and generator recipes must use explicit
corpus-owned drivers around these primitives. The generic `execute` path does
not claim those recipes are supported: it will preserve their failed build or
phase rather than convert a native `go test` result into Bash++ coverage.
Generated-child source hashes and parent/child obligations belong in the corpus
recipe evidence, including implicit compiler launches from `os/exec` upstream
runners. A native child is never an interpreted or compiled product observation.

Source, module and asset copies are checked before and after compile/check
phases, and runtime assets are checked before launch. Asset mutations during
execution are observations; mutating the retained compilation input fails.

## Source Map Provenance Hardening
To prevent empty or fake source maps from erroneously certifying nonempty mapped programs, the suite implements exact source provenance binding (Sprint 118). When validating generated source maps with `source_kind=go` and `front_end=gosource-v1`, the validator checks that the embedded source metadata matches the exact original filenames, SHA-256 digests, Base, and Size. Additionally, `source_file` and `source_file_offset` mappings are checked to ensure ranges verify exactly against the original bytes and generated line/column indices. Empty source maps are rejected unless they map legitimately empty programs (containing no generated `// lower:` markers), preventing tampered maps from hiding failed compilation mappings.

The validator independently reads and hashes the supplied generated and original
files; stale caller-provided hashes cannot authenticate changed bytes. Source
metadata follows lexical filename order with exact concatenated Base offsets,
and mappings must cover the lowerer's next-nonempty-line marker positions in
order. A real empty package with no emitted markers may have an empty map.
Portable retained fixtures under `tests/corpus/fixtures/source-map` exercise this
contract offline; their provenance describes actual compiler output and does not
constitute new product certification.
