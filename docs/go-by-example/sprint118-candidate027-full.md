# Sprint 118 Candidate027 full Go-by-Example replay

Sprint: #118; Story: #3; Story-ID: `fa07603b71dc`.

Candidate027 was replayed once, unfiltered, over all 85 immutable Go-by-Example
program rows in oracle, interpreted, and compiled modes. The production gate
recorded exactly 255 attempt observations, all spawned and complete. No
official-Go or Tour lane was run. Port 8090 had no listener before the replay,
was used only by the corpus adapters during the replay, and had no listener
after release. The SDK was the pinned `go version go1.27.0 darwin/arm64`, whose
binary SHA-256 is
`a19a71df81715c12d9a7e81bab036c12696fec1ddbd4258b48a2131a9080b267`.

The result is **FAIL**. Story #3 remains open; no parity is inferred.

| mode | pass | fail mismatch | fail normalization | spawned | missing |
| --- | ---: | ---: | ---: | ---: | ---: |
| oracle | 85 | 0 | 0 | 85 | 0 |
| interpreted | 62 | 18 | 5 | 85 | 0 |
| compiled | 85 | 0 | 0 | 85 | 0 |
| **total** | **232** | **18** | **5** | **255** | **0** |

The exact 255-row repository ledger is
[`sprint118-candidate027-full-ledger.tsv`](sprint118-candidate027-full-ledger.tsv)
(SHA-256
`93fdb73dd970c5f9544a43590fcfd7dee9b2e94ed18793ffac820b1edd34cd24`).

## Retained receipt

All new evidence is under
`/Users/qiangli/.local/state/bashy/sprint118-evidence/runtime-integration-027/`.
The earlier bounded Candidate027 evidence remains byte-for-byte unchanged.
Nothing from either attempt was deleted or pruned.

| retained artifact | SHA-256 / identity |
| --- | --- |
| `gbe-full-001.jsonl.fail` | `0fb0c1b02b0211ebcf688ecf0199609df25f0bbb347cf17f4de29e02a0acb180` |
| summary-bound root digest | `334f8cc658b5f6824021181e83137a2073858b3a83277740ff73a75a0bd50bb2` |
| `gbe-full-001.jsonl.progress.jsonl` | `e299fda2687f75d8bcba8de78f9fbda42ab376b2aa9d891809c3c6b26c72c456` |
| `gbe-full-001.console.log` | `0852d750fe7b653ddd8b4013dda72b9279b54346fa0d762c3e393df5bc8c8d3f` |
| retained derived ledger | `b196e7fb4e2ee8319910297b47ddb96e17c5f6a88add7bbdffd69f88f8bf2051` |
| retained failure stream | `6c37c388b47039536954ef547901def1060804a3e285b3fc436adfffe5f361ee` |
| retained taxonomy | `170ff83ab96212c773cc4a1b7453d20371e4aa282f55a98de9701590f743c316` |
| candidate manifest | `f86c94dffe4d734e00be21cf15a622a24072427653f2caeba8bb440fc77ba279` |
| launcher | `454c25a8cfb70a45e2bcb4fe57f64e7726164ed1ec8b7e46f3c243f4b87930a4` |
| payload | `d2da6d9cf2e369069c20c4b390092f6225ec8c36ac8349fca01ab64c4b139f3a` |

The final evidence has 257 JSONL records (manifest, 255 attempts, summary); the
progress ledger has 256 records (manifest plus every attempt). The retained
work tree contains 7,246 files, including every stage capture and failure
stream. The full Candidate027 evidence root is 737 MiB before filesystem
allocation rounding.

## Validation gates

| gate | result |
| --- | --- |
| production `validate-evidence.rb` | PASS: authenticated fail evidence, denominator 255, executed 255, missing 0, root digest matched |
| independent candidate authentication | PASS for Candidate027 launcher, payload, five repositories, lowering runtime, and Go 1.27 SDK |
| production inventory validation | PASS: 89/89 files and all 85 programs verified |
| inventory tamper suite | PASS: 39/39 defect classes rejected |
| retained-evidence tamper suite | PASS: 5/5 mutations rejected against this full evidence |
| bounded-evidence preservation suite | PASS: 32/32 mutations across Candidates024–027 |
| gate contract tests | PASS: 18 runs, 120 assertions |
| JSON/closing-channel normalizer tests | PASS: 8 runs, 69 assertions |
| broad production tamper suite | PARTIAL: first 10 cases passed; the Go-1.26 case stopped on a stale expected diagnostic because Candidate027 pins Go through authenticated `PATH` plus `GOTOOLCHAIN=local`, not a `go1.27.0` substring in the recipe |

The broad-suite stop is a test-contract discrepancy, not acceptance of the
mutation. Its actual rejection was `reviewed build recipe does not pin the Go
toolchain`. No production gate, candidate row, corpus source, classification,
or normalizer was changed to conceal it.

## Every remaining interpreted failure

| path | verdict | classification | observed diagnostic |
| --- | --- | --- | --- |
| `command-line-flags` | mismatch | native-reference mutation | `StringVar` cannot mutate interpreter-owned references |
| `command-line-subcommands` | mismatch | pointer target | `fooEnable` is not a pointer |
| `context` | mismatch | callback signature bridge | callback requires unsupported parameters/results |
| `directories` | mismatch | native-handle range | `*os.unixDirent` is not scalar |
| `embed-directive` | mismatch | runtime output | oracle writes four embedded-value lines to stderr; interpreted writes none |
| `errors` | mismatch | aggregate composite expression | `BashPPCompositeLit` unsupported in scalar expression |
| `http-server` | mismatch | callback signature bridge | callback requires unsupported parameters/results |
| `json` | normalization | native-slice mutation | `encoding/json/v2.Unmarshal` retention/mutation unsupported |
| `logging` | mismatch | native-reference mutation | logger output begins, then `log.New` mutation is rejected |
| `maps` | mismatch | imported symbol/method | imported `maps.Equal` is unknown |
| `panic` | mismatch | panic reporting | exit 2 and panic line agree; interpreted omits native stack frame |
| `pointers` | mismatch | `new` value expression | `new` rejected outside the supported value-expression shape |
| `regular-expressions` | mismatch | native-slice mutation | `Regexp.ReplaceAllFunc` retention/mutation unsupported |
| `signals` | mismatch | signal propagation | interpreted prints readiness then exits 130 before handled-signal output |
| `sorting-by-functions` | mismatch | copied-slice callback | callback with copied slice references unsupported |
| `sorting` | mismatch | native-slice mutation | `slices.IsSorted` retention/mutation unsupported |
| `spawning-processes` | normalization | tuple assignment | two targets receive zero values |
| `stateful-goroutines` | normalization | channel element bridge | scalar cannot be used as `chan int` |
| `strings-and-runes` | mismatch | imported aggregate selector | ranged value `s` is not structured |
| `testing-and-benchmarking` | normalization | callback signature bridge | generated test callback requires unsupported signature |
| `time` | normalization | callable/method bridge | `Duration.Hours` and callable `diff` are unavailable |
| `variadic-functions` | mismatch | variadic slice expansion | slice value is passed as one `int` argument |
| `xml` | mismatch | copied-slice callback | callback with copied slice references unsupported |

## Smallest next repairs

The three smallest isolated repairs are interpreted `go:embed` value emission,
handled SIGINT propagation, and panic stack-frame reporting. The next
higher-leverage repairs are the callback bridge (five rows: `context`,
`http-server`, `sorting-by-functions`, `testing-and-benchmarking`, `xml`) and
native reference/slice mutation (five rows: `command-line-flags`, `json`,
`logging`, `regular-expressions`, `sorting`). Each repair still requires a new
authenticated candidate and a fresh full 255-observation replay; these
classifications are diagnostics, not inferred parity.
