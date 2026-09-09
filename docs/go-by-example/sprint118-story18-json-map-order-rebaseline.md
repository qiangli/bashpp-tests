# JSON map-order classification rebaseline

Sprint: #118; Story: #18; Story-ID: 2ab04e37d660

## Decision

`examples/json/json.go` is classified as `map_iteration / map_order / none`.
The pinned `encoding/json/v2` oracle and the compiled artifact both emit the
two `map[string]int` JSON objects in Go map iteration order. This is variance
between independent executions, not a deterministic output contract.

The licensed normalizer is deliberately narrow: it accepts the exact
15-line example stream, preserves the other thirteen lines byte-for-byte, and
canonicalizes only lines 6 and 14 after requiring exactly the `apple:5` and
`lettuce:7` members. It rejects changed members, changed deterministic output,
extra output, and any other stream shape.

## Rebaseline boundary

This changes authored classification and its derived inventory only; the copied
corpus bytes and behavior schema are unchanged. It therefore changes the
`classification_sha256` and `corpus_sha256` that `gate.rb` records in a
manifest:

| field | historical baseline | Story #18 baseline |
| --- | --- | --- |
| `classification_sha256` | `bfe087332a2b4deb702503b39c0e390d84d1b60f0f2716acc8b476bb7b78bad2` | `9ef2a995041b76e921759d7ec73a77532f368cc581625a376b5894925e79b8a1` |
| `corpus_sha256` | `57712273341a7918cf8ae8829aee43f86c09e04720989592897eb7e40d8060c2` | `add688b034869ae4b5401507c41d301670d972663d6e2c1fd7cea2f8ce017e3a` |

The pin's inventory data digest correspondingly changes from
`2b8b6a763049805e39caeb09fce1441d838f300f97e56d34c8f0f2ae8cfa7c6b` to
`0ffb16f1908d10cec932361b58fe935b5238a589db8989cc75ec89d2557e1c28`.

Candidate021 and Candidate022 remain historical evidence under their original
hash bindings. They are not rewritten or reinterpreted as an accepted replay:
their `json` observations were order-sensitive and are no longer suitable for
cross-baseline comparison. Any future evidence root must bind this new pair of
hashes before it can compare the reclassified row.
