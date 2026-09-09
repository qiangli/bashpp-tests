# Sprint 118 candidate017 — ticker corrected, complete corpus still FAIL

Dated 2026-09-09. The full **85-row / 255-observation** replay completed in
256.115 seconds with no missing or unspawned observations.
The overall result remains **FAIL**.

| Mode | PASS | Mismatch | Normalization failure |
|---|---:|---:|---:|
| Native Go | 85 | 0 | 0 |
| Bash++ interpreted | 52 | 29 | 4 |
| Bash++ compiled | 85 | 0 | 0 |

[All 255 results](sprint118-candidate017-ledger.tsv) and the
[exact receipt](sprint118-candidate017-receipt.json) are retained. The existing
validator independently authenticated the complete FAIL ledger, and all five
retained-evidence tamper controls rejected their altered inputs as expected.
Original source bytes, behavior contracts, and normalizers were unchanged.

Compared with [candidate016](sprint118-candidate016.md), the sole verdict gain
is interpreted `examples/tickers/tickers.go`: it now passes, printing three
valid timestamped tick lines and `Ticker stopped`, exiting0 with empty stderr.
Native and compiled modes pass the same source. The previous selector/task
failure is absent. No other mode verdict changed and there are no regressions.
Compared with [candidate013](sprint118-candidate013.md), all 255 verdicts match:
zero newly passing rows and zero regressions. This restores the prior passing
ticker observation without upgrading any of the 33 remaining interpreter
failures. Prior raw ledgers remain intact.

The complete run used frozen sh `037aaf8687e0aa049efb4f7a2dceb3a4941e9bbc`, Bashy
`fdd3fac99579b9b923c5c6389a943c986f697a80`, and corpus harness
`cf3e444cca26c1d42bfd5119aa3901465c80576a`. Candidate manifest SHA256:
`bb531a83039cd10679b91a840c9196a64e3f89e449a049f22c216db498c2010e`.
Raw-ledger SHA256: `94a917a8397fff8399a5df5c4c78e913b0baa8c41129c76230d86435505bab5a`.
Root digest: `0590f81a612ec62a8676497a7f82a1130935187751a1eec14de3b7c89c33db25`.
The final root is separately anchored in `evidence-roots.tsv`.

There were no row filters, source adaptations, or native execution credit for
original interpreted bodies. The rejected native string-wire patch was not
included. Story3 stays open. This receipt does not certify Go by Example
parity, the complete official-Go corpus, or sprint completion.
