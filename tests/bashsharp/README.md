# Bash# executable acceptance matrix

This directory is the test-contract boundary for the five and only five Bash#
features approved for Sprint 114: keyword arguments, default parameters, deep
readonly, exhaustive enums, and null-safety checking. Fixtures intentionally
describe the design contract; they may remain red until implementation lands.
A red fixture must not be deleted, skipped, or weakened to match a current
binary.

`matrix.tsv` has exactly five feature rows. Each row names a closed
`cases.tsv` interpreted ledger and a separately closed `lowering.tsv` ledger.
The per-family ledgers expand the denominator without turning required cases
into extra feature rows. The validator rejects missing and unreferenced
fixtures, changed case sets, vague diagnostics, zero-case ledgers, fake shell
escapes, and loss of either phase.

## Sprint 114: interpreted semantics

Run:

```sh
BASH_ENGINE_BIN=/path/to/bash BASHY_BIN=/path/to/bashy \
  tools/bashsharp/acceptance.sh
```

`BASH_ENGINE_BIN` is the bash-compatible shell engine. It owns script
execution under plain, `--bashpp`, and `--posix --bashpp` modes. `BASHY_BIN` is
the bashy front door and is used only for `bashy check --bashpp`, because null
safety is a checker rule with no syntax. The Sprint 114 gate never invokes
`transpile` and does not require a Go compiler.

For every source fixture the gate captures status, stdout, and stderr from the
plain/POSIX-off engine and from `--posix --bashpp`. Those results must be
byte-identical. This is the POSIX inertness oracle:

```text
bash fixture  ==  bash --posix --bashpp fixture
```

The POSIX result is never compared with enabled Bash++ semantics or Bash#
diagnostics. Positive and invalid Bash# cases run separately under `--bashpp`;
invalid cases have exact one-line diagnostics with stable `BASHPP-E…` codes.
Near misses compare enabled Bash++ with plain shell behavior. Every positive
engine case is also required to differ from its selector-off result, so a no-op
runner cannot make the gate green. Checker negatives prove null-safety
activation by requiring their exact diagnostic under `--bashpp` and forbidding
that diagnostic code with the selector off.

Only `type Color enum { … }` has an escape obligation: it is Class E and rides
the committed `type` start site. `enums/forced-command.bpp` and
`enums/forced-quote.bpp` execute the escaped command forms. Keyword arguments
and defaults are Class R and require no escape; readonly extends an existing
builtin without new grammar; null safety is checker-only. Printing a Bash#
source string is not an escape test and is rejected by validation.

Coverage is contractual: kwargs/defaults include binding errors and their
interaction; readonly covers nested maps, slices, structs, aliases, subshells,
and imported values across mutation paths; enums cover invalid and duplicate
members plus exhaustive, default, nested, and invalid-value cases; null safety
covers flow narrowing, reassignment, dereference, index, call, and
false-positive guards.

## Sprint 117: lowering and parity

Run separately:

```sh
BASH_ENGINE_BIN=/path/to/bash BASHY_BIN=/path/to/bashy \
  tools/bashsharp/lowering.sh
```

This gate fails closed if the bashy front door, `transpile`, Go compiler,
generated source, deterministic second lowering, build, or interpreted versus
compiled byte parity is missing. Keeping it separate prevents Sprint 114 from
demanding a transpile command that belongs to Sprint 117 while preserving an
executable lowering obligation.

Rejected Bash# proposals remain excluded: comprehensions, ternary, `match`,
try/catch, operator or method overloading, inheritance, async/await, optional
chaining, nullish operators, decorators, arrows, and a separate Bash# mode.
There are no `planned`, `skip`, or `n/a` rows.
