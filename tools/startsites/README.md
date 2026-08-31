# Committed start sites — the derivation

The Bash++ design of record needs a **finite table of the exact shapes at which
the parser leaves shell grammar and commits to a Go production**. Two L4
reviewers blocked implementation on its absence: without it, neither the claimed
shell compatibility nor the proposed conformance gates are testable.

That table had been treated as prose someone would eventually write. It is not.
It is **derivable**, and this derives it.

## The two classes

Run a candidate shape through real GNU Bash 5.3 with `bash -n`:

| | | |
|---|---|---|
| **Class R** | stock bash **rejects** it | Purely additive. No existing script can contain it, so Bash++ may claim the shape with no table row, no escape, and no compatibility risk. |
| **Class E** | stock bash **accepts** it | Meaning-changing. Claiming it changes what an existing script does, so it needs a table row, a near-miss fallback, and an explicit `command`/quote escape. |

## The law the corpus exposed

**The parenthesised call is Bash++'s free disambiguator.** Bash's only
`word (` production is `name ()`, so nearly every Go construct whose committed
shape contains a `NAME(` call form is *already* a bash syntax error. Everything
that is keyword-plus-bare-words is not.

Two consequences worth stating on their own:

- **`go build ./...` parses; `go worker(a, b)` does not.** The collision the
  original design feared — `go` shadowing the Go toolchain, which bashy itself
  ships as a verb — is resolved by the parens. That is measured evidence for the
  L4 decision to abolish the `go routine { … }` spelling, which until now rested
  on argument alone.
- **The `:=` start site splits.** `x := 42` is Class E; `x := f()` and
  `x, y := f()` are Class R. One start site, two rows, opposite risk — invisible
  without running the oracle.

## Measure the commit point, not the construct

A parser decides at the **opening line**; it never gets to see the closing
brace first. So a multi-line construct is classified at its prefix, and the two
do not always agree: the complete `type T struct { … }` is a parse error, while
`type T struct {` — the line the parser actually commits on — is an ordinary
bash command. Measuring only complete forms records such a site as free when it
is not.

A prefix that **opens a bash compound** cannot be judged bare at all. `bash -n`
on `if err != nil {` reports the missing `then`; that is *incompleteness*, not
unavailability, and reading it as a rejection produces a false Class R. Those
rows carry an optional fifth column, a minimal **completing context**, and that
is what the oracles parse. It changes the answer:

```text
if err != nil {
then echo b
fi
```

parses in bash 5.3 — the `{` is just the last word of the condition — so
`if <expr> {` is Class E and needs bounded lookahead, while `for i := range
10 {` stays Class R because no completing context makes it parse. Both results
are measured; neither is reasoned from the other.

## Usage

```sh
./classify.sh                 # the classification table (TSV)
./classify.sh --markdown      # the table as it appears in the design doc
./classify.sh --check         # ratchet: fail if any shape changed class
```

`BASH53` and `BASHY` select the oracles. Both are **required**: a
classification produced from one of them would quietly become an assertion
again, which is the thing this tool exists to stop.

## What it does not do

**Nothing is ever executed.** Every shape is checked with `bash -n`, which
parses and exits. Several shapes in the corpus would be destructive if run.

It also never builds anything. It consumes whatever `bashy` binary it is
pointed at; on unix `bin/bash` is a C launcher over `bin/bash.real`, and
rebuilding it in place silently destroys that pair while `bin/` being gitignored
hides the damage from `git status`.

## The second oracle, and why disagreement matters

Every shape is also parsed by bashy's own engine. Where the two **disagree**,
Bash++ is not the subject: that is a bash-5.3 fidelity divergence in the engine,
and it belongs to the certification workstream.

The corpus found one on its first run, and the five `NAME[...]` rows are kept as
its regression net. At command position a word like `f[[]int]` or `f[*T]` is an
ordinary glob word to real bash, but the engine parses the subscript as
*arithmetic* and hard-errors. Argument position (`echo f[[]x]`) is unaffected.
Reported to the certification sprint; deliberately not fixed here.

## Adding a shape

Append a tab-separated row to `shapes.tsv` — `id`, `phase`, `feature`,
`shape`, and an optional `probe` (the completing context, when the shape opens
a bash compound) — then regenerate the baseline:

```sh
./classify.sh --tsv > baseline.tsv
```

Write the shape exactly as it would appear at the start of a line; use `\n` for
a newline. Whether it parses is **not** yours to assert — that is what the
oracles are for. If the new row changes an existing shape's class, `--check`
will say so, and the design of record needs updating before it lands.
