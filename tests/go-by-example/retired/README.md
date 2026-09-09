# Retired Go by Example evidence

`sprint98-story198-schema6.jsonl.fail` is the Sprint 98 evidence chain, kept
verbatim as historical record. It is **not** verifiable by the current
`tools/go-by-example/validate-evidence.rb` and must not be presented as
coverage, for reasons that are all recipe changes rather than bookkeeping:

- it is evidence schema 6; the current chain is schema 8;
- its oracle ran `go run`, so a deliberate `os.Exit(3)` was recorded as the
  wrapper's exit 1 plus an `exit status 3` line on stderr, and was compared
  through the `goexit_status` normalization that no longer exists;
- its product commands were `bashy --bashpp <file>` and the never-implemented
  `bashy --bashpp --compile -o`, not the unchanged-Go-source contract;
- its rows claimed the `fake_clock` and `seeded_random` adapters, which the
  gate never performed;
- it has no per-stage records and no filesystem-effect channel, so it cannot
  distinguish a successful transpile from an artifact that ran.

It is preserved rather than deleted. A failed chain is part of this corpus's
history, and the reasons it was retired are only legible while the document
itself is still readable.

Sprint 118 / Story #3 replaced it with a real one. `--source=go` shipped in the
tag-enabled candidate, so the gate now drives the product instead of documenting
a missing flag, and
`tests/go-by-example/sprint118-story3-candidate001.jsonl.fail` is the current
chain: schema 8, the authenticated `gosource-v1` candidate, all 85 rows in all
three modes, `fail`, anchored in `docs/go-by-example/evidence-roots.tsv`.

Anchoring a *failing* chain is not the forged pass this harness exists to
prevent — the forged pass was manufacturing a GREEN root from a stand-in
executable. `validate-evidence.rb` still accepts `pass` only at
`denominator == executed == 255` with every attempt spawned, complete and
passing. What the anchor buys is that the document is independently
re-verifiable and that `tools/go-by-example/tamper-tests.sh` mutates something
the product actually produced, instead of generating its own input from a
fixture that no longer exists.
