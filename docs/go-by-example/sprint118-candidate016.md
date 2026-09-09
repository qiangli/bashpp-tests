# Sprint 118 candidate016 — complete failing Go by Example replay

Dated 2026-09-09. All **85 unchanged originals and 255 observations** ran against
frozen candidate016 in 250.506 seconds. The measured result
is **FAIL**; there are no missing or unspawned observations.

| Mode | PASS | Mismatch | Normalization failure | Missing/unspawned |
|---|---:|---:|---:|---:|
| Native Go | 85 | 0 | 0 | 0 |
| Bash++ interpreted | 51 | 29 | 5 | 0 |
| Bash++ compiled | 85 | 0 | 0 | 0 |

[The full ledger](sprint118-candidate016-ledger.tsv) records every mode result.
[The receipt](sprint118-candidate016-receipt.json) binds the exact candidate,
payload, complete raw ledger, source/behavior contracts, and comparison hashes.
The existing retained-evidence validator independently authenticated this
complete FAIL ledger. All five retained tamper controls rejected their mutated
inputs for the expected reasons. No failure was waived or relabeled as PASS.

Compared with [candidate013](sprint118-candidate013.md), there are **zero newly
passing observations and one regression**: interpreted
`examples/tickers/tickers.go` changed from PASS to `fail_normalization`. It
actually exits 1 with empty stdout and this product diagnostic:

```text
tickers.go:28:16: BASHPP-ESELECTOR-ROOT: ticker is not a structured value
bash++: task failed: exit status 2
```

Native and compiled observations each print three ticks and `Ticker stopped`,
then exit 0. The normalization failure is a consequence of the runtime error;
it is not permissible clock variation. The other 254 mode verdicts are
unchanged from013. Corpus, behavior schema, classification, normalizer, and
pinned SDK identities match across both ledgers, so this comparison does not
mix changed acceptance rules with product changes.

The TCP server passed all three declared observations: exact protocol check,
required empty streams, expected termination status 143, and released listener.
This replay waited for the complete sh gate and its interpreter process to
exit, then checked TCP8090 before starting. The endpoint was not shared with
the broader sh tests. Original source bytes and the full 85-row denominator
were preserved; there were no filters, source adaptations, or native original
body forwarding. The rejected native string conversion remains excluded.

The frozen runtime is sh `f80d9e90c6f3c23b9f586bc3fac673a2f46b466b`, Bashy
`865240797c3a2cb9740a35f1de40f068fd3c2dbb`, with corpus harness
`c0749fef7764ecb9528c44cc252760d748490d42`. Candidate manifest SHA256:
`223d69fadad541d931c08c9999e4db24c48f04e855c93fc350cd0036354b2c2f`.
Raw-ledger SHA256: `331aacd3b72a58690f7e9bb1cd3ca9a773a1880e5b271763a1670eb42fce30ab`.
Root digest: `82c9c068d1ce30843421600e9d40d55ac8eb62a3a869c580b2ec158a89036c74`.
The retained evidence is separately anchored in `evidence-roots.tsv`.

Story3 remains open. This receipt does not certify Go by Example parity,
the complete official-Go corpus, or sprint completion. Candidate013's earlier
raw evidence and passing ticker observation remain intact.
