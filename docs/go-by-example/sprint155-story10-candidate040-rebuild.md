# Sprint 155 / S155.10: Go port of the Go by Example harness, candidate040 rebuilt on novidesign.local

Sprint: #155; Story: S155.10; Story-ID: `67bdd9fae2b3`.

`tools/go-by-example/` is Ruby-free: the eleven Ruby files are one Go program,
`tools/go-by-example/gbe/`, behind the unchanged wrappers (see
[README.md](README.md), "Sprint 155"). This record is the proof run of that
port: the reviewed Sprint 118 candidate040 sources were rebuilt on
novidesign.local and replayed through the ported gate over all 85 rows in all
three modes.

## Candidate

The last row of [`candidates.tsv`](candidates.tsv) is the reproduction:
`~/sprint155/base/{bashy,sh,coreutils,readline,filebrowser}` cloned as flat
siblings into `~/sprint155/lanes/67bdd9fa/candidate/`, checked out at the
candidate040 commits (bashy `7e8abb38`, sh `704fa063`, coreutils `ec91ea45`,
readline `b958823b`, filebrowser `cde11469`, all clean) and built with the
reviewed recipe
`env PATH=/Users/noviadmin/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.0.darwin-arm64/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin CI=true GOTOOLCHAIN=local GOMAXPROCS=2 GOFLAGS=-p=2 make build`.

| field | candidate040 (reviewed) | this rebuild | why it cannot match |
| --- | --- | --- | --- |
| manifest_sha256 | `cf644a343b77...` | `6557ecec0db5...` | the manifest carries the absolute repository paths of the host that built it |
| launcher_sha256 | `454c25a8cfb7...` | `d1fd0029efb0...` | `bin/bashy` is `native/siglaunch.c.in` compiled by the host `cc`; a different clang/SDK emits different bytes |
| payload_sha256 | `22d88c86b2bf...` | `0b80c4064ebb...` | `make build` embeds the meet SPA only when node/pnpm exist; novidesign has neither, so this is the no-UI build of the same sources |
| repositories | five reviewed commits | the same five commits | — |

`gbe.sh validate-candidate --candidate candidate/candidate.json --bashy candidate/bashy/bin/bashy`:
`PASS: authenticated candidate 6557ecec0db5`.

## Replay

Command, from `~/sprint155/lanes/67bdd9fa`:

```
tools/go-by-example/gate.sh --candidate candidate/candidate.json \
  --bashy candidate/bashy/bin/bashy \
  --evidence ~/sprint155/evidence/67bdd9fa/gbe-full-001.jsonl
```

Two earlier starts of the same command were stopped and set aside
(`~/sprint155/evidence/67bdd9fa/aborted-nohup/`,
`aborted-background-job/`); both are diagnostics, not evidence. Started under
`nohup`, and then as a `&` job of a non-interactive `zsh -lc`, the gate
inherited signals set to `SIG_IGN` (HUP; INT and QUIT), the interpreter treats
those as hard-ignored on entry and exports its internal
`BASHY_HARD_IGNORE` bridge into the program's environment, and
`examples/environment-variables` -- which prints every key it can see --
recorded `interpreted=fail_mismatch` at ROW 20 in both. That is the product
behaving like bash (SIG_IGN inherited through execve), observed through the
gate's environment channel exactly as designed; the Ruby gate restored
inherited SIG_IGN dispositions the same way. The retained replay was run in
the foreground of an ssh session with default dispositions, and ROW 20 passes
in all three modes.

### Replay 001: the weekend defect of the VERSION 7 comparator

`gbe-full-001.jsonl.fail` (retained, not anchored) is the first complete
replay: **255 attempt records, 255 executed, 0 missing**, 254 passes, and
`examples/switch/switch.go` recorded `fail_normalization` ("wallclock shape")
in oracle, interpreted and compiled alike. The program prints `It's the
weekend` on Saturdays and Sundays; the Ruby comparator this port reproduced
only matched `It's a weekend`, a string `switch.go` never prints, and every
earlier replay in this directory ran on a weekday. Normalizer VERSION 8 accepts
the pinned rendering (`It's (?:the weekend|a weekday)`), still cancelling only
the day-class and noon-class lines; see [README.md](README.md).

### Replay 002: PASS

`gbe-full-002.jsonl.pass` is the anchored chain.

`PASS: verdict=pass denominator=255 executed=255 evidence=/Users/noviadmin/sprint155/evidence/67bdd9fa/gbe-full-002.jsonl.pass root_digest=0a1ff72eeac3c183472a8292195e4ef431d874adce836d70087d55237285ca98`

| mode | pass | failed | spawned | missing |
| --- | ---: | ---: | ---: | ---: |
| oracle | 85 | 0 | 85 | 0 |
| interpreted | 85 | 0 | 85 | 0 |
| compiled | 85 | 0 | 85 | 0 |
| **total** | **255** | **0** | **255** | **0** |

The derived repository ledger,
[`sprint155-story10-candidate040-rebuild-derived/ledger.tsv`](sprint155-story10-candidate040-rebuild-derived/ledger.tsv)
(`gbe.sh summarize`), is **byte-identical** to the reviewed candidate040 ledger
[`sprint118-candidate040-full-derived/ledger.tsv`](sprint118-candidate040-full-derived/ledger.tsv):
both hash to `508da714507ef23f0e05e70bd4e8afdfa323bc0923536d66e3e5b3b27707308a`
(`shasum -a 256`, `diff` empty).

## The retained candidate040 record, field by field

| field | candidate040 record | this replay | status |
| --- | --- | --- | --- |
| attempt_records / executed / missing_or_unspawned | 255 / 255 / 0 | 255 / 255 / 0 | reproduced |
| verdict | pass | pass | reproduced |
| classification_sha256 | `9ef2a995041b76e921759d7ec73a77532f368cc581625a376b5894925e79b8a1` | same | reproduced |
| corpus_sha256 (inventory) | `add688b034869ae4b5401507c41d301670d972663d6e2c1fd7cea2f8ce017e3a` | same | reproduced |
| corpus_root_sha256 | `7cd79e725fd401821957d6c31ef8bf1aded43bb39140e0aa9313cc2ec4febfc5` | same | reproduced |
| behavior_schema_sha256 | `2d8c0a55b9d5542b4c058a15a49a59dd5bb483df9524a4143652f26df6380d05` | same | reproduced |
| toolchain_sha256 / go_sha256 | `eeacfc3b...` / `a19a71df...` | same | reproduced |
| derived ledger.tsv | `508da714...` | `508da714...` | reproduced, byte-identical |
| normalizer_version | 7 | 8 | cannot match: VERSION 8 corrects the weekend day-class rule (above) |
| normalizer_sha256 | `ff0a51c5...` (normalizer.rb) | `3201a026df50d74372a1c29efeeac9fa559a69ee3871aebf268021b0cb2776fd` (gbe/normalizer.go) | cannot match: the Ruby file is gone; the anchor binds the Go source |
| corpus_executor_sha256, input_binding_sha256, runtime_config_sha256 | executor.rb, inputs.rb, runtime-config.rb | gbe/corpus.go, inputs.go, runtimeconfig.go | cannot match: same reason |
| candidates_sha256, candidate manifest / launcher / payload | row 040 | the reproduction row (previous section) | cannot match: host-built launcher and no-UI payload, absolute manifest paths |
| root_digest | `165f4d14...` | `0a1ff72e...` | cannot match: the manifest it chains carries every field above plus host paths, inodes and per-run capture ids |

No comparator was loosened; the only comparator change is VERSION 8, which
admits a line the pinned program prints and VERSION 7 could not read.

## Gates run on novidesign.local (all from `~/sprint155/lanes/67bdd9fa`)

| gate | command | result |
| --- | --- | --- |
| Go unit tests of the port | `tools/go-by-example/selftests.sh -count=1` | `ok gbe` (15 tests) |
| inventory validation | `tools/go-by-example/validate.sh` | `Go by Example inventory OK: 7d705626... — 89/89 files verified (85 programs, 3 runtime assets, 85 .go)` |
| candidate authentication | `tools/go-by-example/gbe.sh validate-candidate --candidate candidate/candidate.json --bashy candidate/bashy/bin/bashy` | `PASS: authenticated candidate 6557ecec0db5` |
| full replay | `tools/go-by-example/gate.sh --candidate ... --evidence ~/sprint155/evidence/67bdd9fa/gbe-full-002.jsonl` | PASS, 255/255/0, root `0a1ff72e...` |
| evidence validation | `tools/go-by-example/gbe.sh validate-evidence ~/sprint155/evidence/67bdd9fa/gbe-full-002.jsonl.pass` | `PASS: authenticated pass evidence, denominator=255 executed=255 missing=0 root_digest=0a1ff72e...` |
| retained-evidence tamper suite | `tools/go-by-example/gbe.sh tamper-retained-evidence ~/sprint155/evidence/67bdd9fa/gbe-full-002.jsonl.pass` | `PASS 5 retained-evidence mutations against authenticated real execution` |
| broad tamper suite | `GBE_CANDIDATE=... BASHY_BIN=... GBE_EVIDENCE=.../gbe-full-002.jsonl.pass tools/go-by-example/tamper-tests.sh` | `PASS: 51 genuine mutations/invariants checked` (22 Phase A, 29 Phase B) |
| summary | `tools/go-by-example/gbe.sh summarize .../gbe-full-002.jsonl.pass .../gbe-full-002-derived` | `{"complete_ledger":true,"recorded_rows":85,"recorded_attempts":255,"modes":{"oracle":{"pass":85},"interpreted":{"pass":85},"compiled":{"pass":85}}}` |

Not run: `gbe.sh bounded-evidence-selftests` needs the retained Candidate024-027
trees under `~/.local/state/bashy/sprint118-evidence`, which exist on neither
this workstation nor novidesign.local (`GBE_BOUNDED_STATE` points it elsewhere);
it is ported, not exercised.

The broad suite needed three corrections to expectations the Ruby script had
carried since the table and validator grew past them -- each would have failed
the Ruby suite the same way: (1) `candidate_revision_mismatch` and
`missing_sh_module` re-pointed *every* reviewed row at the rewritten manifest,
which with more than one darwin/arm64 row is refused as "duplicate reviewed
candidate identity" before the case under test is reached; only the selected
row moves now. (2) `self_hashes_are_not_authentication` painted product
attempts with the oracle's raw streams, which the retained-capture check
(added after the case) refuses as "run raw bytes differ from retained capture";
on a green source chain the invented document now keeps its real streams and
records an `invented` detail instead, so the anchor is the only refusal left.
(3) `arrays_raw_stale_normalized` expects the retained-capture refusal for the
same reason. The Go-1.26 case is the one already recorded as stale in
`sprint118-candidate027-full.md`.

## Retained artifacts (novidesign.local, `~/sprint155/evidence/67bdd9fa/`)

| artifact | SHA-256 |
| --- | --- |
| `gbe-full-002.jsonl.pass` (257 records) | `83f8b13e5c258bb2be111ec55347f4c5808d693cb7dc79dba375c2ac0ffd873d` |
| `gbe-full-002.jsonl.progress.jsonl` | `184521ba990fd4bf73caf6c87278c075bafc24426e3b8ff56ce16666b6a88493` |
| `gbe-full-002.console.log` | `feaebf1c3d9e08f7107d78c40e28447877f08d37e645e3e08ee3d05119dc515e` |
| `gbe-full-002.jsonl.work` (8,263 files, 741 MiB) | retained; every capture the chain names |
| `gbe-full-001.jsonl.fail` (VERSION 7 weekend diagnostic) | `7fad5a7d3ec2dc39043a4da81b1a2bd5b59c1f82e337edc3677219a395206bb5` |
| `tamper-tests.console.log` | `9cd600fdb69c6b5f1149a0188d90e2c4ac3417c2829b143288507b1c7289bf3c` |
| candidate manifest `~/sprint155/lanes/67bdd9fa/candidate/candidate.json` | `6557ecec0db585d47721ef000316ccce18eaba95d9df30df08afa2115b8dc9fd` |
