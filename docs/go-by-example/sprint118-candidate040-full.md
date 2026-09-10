# Sprint 118 Candidate040 full Go-by-Example replay

Sprint: #118; Story: #3; Story-ID: `fa07603b71dc`.

Candidate040 was replayed once, unfiltered, over all 85 immutable
Go-by-Example program rows in oracle, interpreted, and compiled modes. The
production gate recorded exactly 255 attempt observations; every attempt was
spawned, complete, and passing. No official full-Go replay or Tour lane was
run as part of this receipt.

The result is **PASS**. Story #3's Go-by-Example parity gate is complete.

| mode | pass | failed | spawned | missing |
| --- | ---: | ---: | ---: | ---: |
| oracle | 85 | 0 | 85 | 0 |
| interpreted | 85 | 0 | 85 | 0 |
| compiled | 85 | 0 | 85 | 0 |
| **total** | **255** | **0** | **255** | **0** |

The exact repository ledger is
[`sprint118-candidate040-full-derived/ledger.tsv`](sprint118-candidate040-full-derived/ledger.tsv)
(SHA-256
`508da714507ef23f0e05e70bd4e8afdfa323bc0923536d66e3e5b3b27707308a`).

## Retained receipt

The evidence is retained under
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-040/`.

| retained artifact | SHA-256 / identity |
| --- | --- |
| `gbe-full-001.jsonl.pass` | `81e501547a700ff09fb890dac8373e9f2288c5c9f44feaada4bb53254feaab7d` |
| summary-bound root digest | `165f4d14c2386219cf3e75a262ac28946ef5ab99d1466b5b773faebc6f56ec26` |
| `gbe-full-001.jsonl.progress.jsonl` | `79f58e45bd2a41adc791addeb30dbf7bf6f7c2ba4d2e617716ff4d275c521b5b` |
| candidate manifest | `cf644a343b7709349cf71f8ba1c26f80de4cbca109d45148332019357e2ac8b5` |
| launcher | `454c25a8cfb70a45e2bcb4fe57f64e7726164ed1ec8b7e46f3c243f4b87930a4` |
| payload | `22d88c86b2bf6d0e2b0eed606703fab7d3dd5c2310623ffe6d732692532b71aa` |

The final evidence has 257 JSONL records (manifest, 255 attempts, summary);
the progress ledger has 256 records (manifest plus every attempt). Candidate
runtime repositories were frozen read-only at `bashy 7e8abb38cebe` and
`sh 704fa0635f1d`, with the reviewed Go 1.27 darwin/arm64 SDK.

## Validation gates

| gate | result |
| --- | --- |
| production `validate-evidence.rb` | PASS: authenticated pass evidence, denominator 255, executed 255, missing 0, root digest matched |
| independent candidate authentication | PASS for Candidate040 launcher, payload, five repositories, lowering runtime, and Go 1.27 SDK |
| production inventory validation | PASS: 89/89 files and all 85 programs verified |
| focused interpreter regressions | PASS, including callback testing and forwarded-signal paths |

The broader `go test ./interp` run attempted during diagnosis is not claimed
as green: it timed out in the unrelated
`TestGoSourceNativeChannelStandardLibraryThreeModes/context_done_closed` test
and exposed three existing expectation-drift failures. Those are outside this
Go-by-Example acceptance receipt and remain explicit follow-up work.
