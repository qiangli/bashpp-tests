# Additional executable source scenarios

These 68 cases record interpreted source behavior. They do not claim compiled
parity. `docs/lowering/profile-additional.tsv` gives each source's exact numeric
exit status and JSON-encoded stdout/stderr. Paths in its `fixture` column are
relative to this directory. Run each source with this directory as cwd:

```sh
"$BASH_ENGINE_BIN" --bashpp scalar-operator-00.bpp
```

Use the same explicit Bash++ mode, cwd, empty `BASH_ENV` and `ENV`, disabled hints,
and `GOTOOLCHAIN=go1.27.0` for comparisons. The standard-library import cases
require the declared Go toolchain. Compare the integer status and both streams
independently; an exit status of zero alone is insufficient. In particular,
`tuple-rollback` finishes with status zero after printing preserved values but
also emits an assignment diagnostic on stderr. `panic-unrecovered` exits 2.

## Extraction and observation

The first 64 cases preserve source from the exact public `sh/interp` test and
subtest named in `public_test_ref`. The scalar and compound operator cases retain
all 11 rows of each public table and its original generated wrapper. Their names
use table ordinals; the reference column identifies the actual operator. This
source execution does not replace the original bytewise parser-input tests.

Exceptions and explicit adaptations:

- The three `stdlib-import*` cases join each original session's import and call
  into one source file. The original test resets its interpreter between those
  sessions; this directory keeps them separate. It does not assert incremental
  session reset behavior.
- The variadic spread cases include the original shared `sum` source prelude.
- `tuple-rollback` retains the complete observed CLI diagnostic including the
  fixture filename and line 5. Its public helper's expectation has no CLI source
  prefix. The extraction crosscheck removed only that known prefix when matching
  the public message and preserved-value output; the manifest retains raw stderr.
- `recursive-substitution` preserves the source and checks the public test's
  `"Second":7` assertion before recording the complete observed JSON output.
- The three `literal-*` cases are new executable cases, not extracts of a named
  sh test. Their manifest reference points to the new public source itself.
  Integer, floating and rune values were independently checked with Go 1.27's
  `go/constant.MakeFromLiteral(...).ExactString()`, the public mechanism used by
  `sh/interp/bashpp_scalar.go:bashPPBasicScalar`. The interpreter prints `1.5` as
  exact rational `3/2`; that spelling is intentionally preserved.
- `array-range` is a new fixed-array counterpart of the public named-slice range
  scenario in `TestBashPPStory201NamedCompositeClosure`. Its two literal values
  and indices are explicit. The single-key `named-map-range` case preserves its
  public source and has deterministic order without sorting.

All 68 expectations were written after the source ran against the same observed
interpreter binary, SHA256
`0c8481d6dec38e127e0f50e137f75842ff89a7c2f7fa60dedc254bbc7e2e8959`.
Source extraction used the public tests available at sh commit
`5282c58a079b26e045c8510617fe3e7ebdd310c7`.
Public test expectations were crosschecked before manifest emission; the final
manifest was then replayed independently against that binary. This directory
contains no captured machine paths, private coverage ledger, or live providers.

## Remaining scenarios and observed limitations

These cases are a bounded addition, not a complete language or runtime inventory.
The following still need separate coverage or implementation work:

- A source-language `error` interface: the reduced probe's `var e error = p`
  reports `undefined type: error`. A following successful shell command can hide
  that failure in the final exit status. No success expectation was added.
- Raw backtick strings in short or typed declarations: observed probes execute
  shell substitution and report command-not-found diagnostics. They were not
  recorded as valid literal behavior.
- Parenthesized expressions in short/typed declarations and inline `println`
  within certain brace forms: probe parse failures need independent diagnosis.
  The successful array-range fixture uses the established public `printf` form.
- Independent method type parameters, generalized function-type inference beyond
  the concrete multiple-argument case, and further inference rejection cases.
  Generic receiver methods do not establish independent method type parameters.
- Complete lexical rejection/invalid-UTF-8 and numeric-width boundaries,
  additional assignment rollback/type failures, and three-index slice bounds.
- Local-module import sidecars, export visibility, module replacement, and
  incremental import-session behavior.
- Signal/context cancellation harnesses, callback/trap setup, channel-capability
  forgery/revocation, source/eval/file boundaries, task cancellation and resource
  cleanup. The deterministic channel cases here cover send/receive/close/select,
  channel range and nested task registration, not those external harness hooks.
- Agentic callbacks and the five Bash# feature matrices remain separately owned
  suites; none is replaced by this addition.

Failed exploratory sources and their raw observations were retained outside this
repository for the sprint manager. They were not turned into passing expectations
or silently reclassified as supported language behavior.
