# Sprint 118 / Story 4 — channel arrival-order review of `concurrency/channels.go`

Story-ID `759341a95870` · Bounded semantic oracle review · evidence root
`/Users/qiangli/.local/state/bashy/sprint118-evidence/tour-channel-order-review`

## Trigger

`docs/tour/volatility.tsv` pass 1 recorded `concurrency/channels.go` under
"rows deliberately NOT listed": byte-identical across seven runs, "they
synchronize, so they stay under exact comparison". That classification is
**incorrect**. The frozen candidate-010 interpreter prints `17 -5 12` for this
row while the accepted native observation (and a seven-run native burst) prints
`-5 17 12`; under byte-exact comparison one of the two is always wrong. Which
one is wrong depends only on which sender won an unsynchronized race, so the
row cannot sit under exact comparison.

## Why both outputs are legal

The program launches two independent goroutines — `sum(s[:3])` computing
`7+2+8 = 17` and `sum(s[3:])` computing `-9+4+0 = -5` — each sending on ONE
unbuffered channel, then receives twice (`x, y := <-c, <-c`) and prints
`x y x+y`. The channel synchronization guarantees that BOTH values arrive and
that the third value is the sum; it does not order which sender's value arrives
first. Both `17 -5 12` and `-5 17 12` are legal executions of the unchanged
source; nothing else is (exactly one line, exactly those integers, exit 0,
empty stderr).

## The bounded experiment (performed FIRST, before any change)

* **Source**: copied byte-for-byte from `tour/_content/tour/concurrency/channels.go`
  (334 bytes, sha256 `8c3ce8583c8274e42ee0522989bf4cf2003b6f8045bcb6b16a6a79364f97aa70`,
  inventory row 48); re-hashed before the build, after the build, after every
  burst and at the end. **No sleeps, yields, replays or reordering were
  injected.** Original SHA retained throughout.
* **Toolchain**: pinned `go1.27.0 darwin/arm64`, `go` binary sha256
  `a19a71df…0b267` matching `docs/tour/toolchain.tsv`; build exactly as the
  baseline stage does (`go build -o BIN SRC` in a module), exit 0, binary
  2 429 858 bytes, sha256 `7c0b15bf…e734`.
* **Protocol**: repeated execution of that one binary with `LC_ALL=C`, empty
  `PATH`, fresh empty cwd per run, under GOMAXPROCS 1, 2 and 4 (400 runs each,
  early stop when both orders are witnessed) plus one 7-run GOMAXPROCS=2 burst
  replicating the executor oracle shape. Raw stdout/stderr/exit/timing are
  retained per run under `runs/`, tallies in `runs.tsv`, commands in
  `commands.txt`, script in `run-experiment.sh`, summary in `burst-log.txt`.

| Burst | Runs | `17 -5 12` | `-5 17 12` |
|---|---:|---:|---:|
| GOMAXPROCS=1 bounded | 400 | 0 | 400 |
| GOMAXPROCS=2 bounded | 400 | 1 | 399 |
| GOMAXPROCS=4 bounded | 400 | 2 | 398 |
| GOMAXPROCS=2 harness-shape | 7 | 0 | 7 |
| **Total** | **1207** | **3** | **1204** |

Every run: exit 0, stdout exactly 9 bytes, stderr empty, no other output shape.
Both legal order witnesses are retained at the raw-byte level
(`runs/p2-bounded-139`, `runs/p4-bounded-212`, `runs/p4-bounded-243`, each
`17 -5 12\n`, sha256 `6181861d…c03d7`). The dominant draw `-5 17 12\n` hashes
to `5fe14584…9b276` — the pinned accepted digest in `tests/tour/results.tsv`.
The 7-run burst drawing one order 7/7 explains exactly why pass 1 measured the
row as stable; the measured flip rate (~1/400 at GOMAXPROCS=2, 0/400 at
GOMAXPROCS=1) makes a one-order burst the normal case, so
`burst_variation: not_required`.

## The extension prepared from that evidence

Because BOTH native orders were witnessed, the schema/comparator extension
below was prepared. It admits **exactly two outputs** and nothing else:

1. `docs/tour/volatility.tsv` — pass-3 measurement paragraph added; the
   "deliberately NOT listed" note now names only the five rows that remain
   byte-identical; one new data row (path, volatile element, comparator needed).
   All ten existing data rows are unchanged. The inventory denominator is
   untouched: this review is **not** corpus acceptance and changes no
   inventory/pin row.
2. `docs/tour/semantics.tsv` — one new row binding
   `_content/tour/concurrency/channels.go` to `channel_sum_order`, digest-pinned
   to the inventory (`8c3ce858…`), `not_required`, with params
   `{"halves":[17,-5],"sum":12,"outputs":["17 -5 12","-5 17 12"]}`.
3. `tools/tour/semantics.rb` — the `channel_sum_order` comparator: exactly one
   terminated line; three space-separated integers; `x+y` re-derived and
   required to equal the source's own sum (12); the value pair required to be
   the source's own halves {17, −5}; and the whole line required to be one of
   the two declared outputs byte-for-byte. Wrong multiplicity, wrong sum, wrong
   values, additional bytes, unterminated output, nonzero exit and nonempty
   stderr are all findings (exit/stderr stay exact, as for every comparator).
   `reconcile` holds the oracle to the declared two-output support, mirroring
   `rand_intn_line`: an order the seven-run burst did not draw is still legal.
4. `tools/tour/semantics-selftests.rb` — 17 new checks for the comparator plus
   cross-rejection in both directions (every other comparator must reject this
   row's output; `channel_sum_order` must reject every other row's output);
   the table-binding count moved to 11. Suite: 185 passed, 0 failed.
5. `docs/tour/executor.md` — ten→eleven narrative and the new comparator row.

**No sorting of arbitrary output, no exclusions, no broad comparator
relaxation, no normalizer change** (`tools/tour/normalize.rb` untouched).

## Verification on this branch

| Suite | Before | After |
|---|---|---|
| `tools/tour/semantics-selftests.sh` | PASS (145) | **PASS (185)** |
| `tools/tour/executor-selftests.sh` | PASS | **PASS** |
| `tools/tour/corpus-tamper-tests.sh` | PASS | **PASS** |
| `tools/tour/evidence-tamper-tests.sh` | PASS | **PASS** |
| `tools/tour/validate.sh` (inventory/pin) | PASS | **PASS** |
| `tools/tour/tamper-tests.sh` | FAIL 1/16 (pre-existing "bounded run" probe) | FAIL 1/16 — identical outcome |
| `tools/tour/executor-tamper-tests.sh` | FAIL 1/27 | FAIL 3/27 — see below |

The two additional `executor-tamper-tests` probe outcomes are guard-trips, not
lost rejections: those probes credit a finding only if it is NEW relative to the
pristine committed ledger, and after this extension the pristine ledger — which
predates the eleventh row — already produces `oracle:row_set` (its 10 oracle
records vs the 11-row table) and `status_forged:` (channels.go statuses
recomputed under a semantic row the old ledger lacks). The probes' mutations
are still rejected by the gate; the retained ledger is simply bound to the
pre-extension tables. This is the same failure class as the pre-existing
"tampered root hash" probe on this already-red ledger. A fresh manager-side
executor run (11 oracle records, channels.go semantic verdicts, current table
digests) restores the suite's baseline discrimination.

`tools/tour/validate-executor.sh` over the committed
`tests/tour/executor-results.jsonl` was already FAIL before this change (59
findings — that ledger is the retained failing candidate-002 replay; the
tamper suite's own pristine-gate baseline was 29 report lines, now 34 for the
reasons above). After this change it additionally reports the re-bound
`semantics`/`volatility` digests and the new oracle row set: expected, because
a ledger is bound to the tables it was produced with. **Producing a fresh
ledger is the manager's acceptance run** (requires `BASHPP_BIN` + candidate
manifest, which this story does not own); no PASS over the corpus is claimed
here.

## Ownership and standing obligations

* This story owns only the tour semantics/volatility/docs/tests listed above;
  the executor runner/gate, inventory, results, evidence ledgers and frozen
  inputs are untouched.
* Two stale "ten rows" mentions are deliberately left alone: the comment in
  `tools/tour/executor-runner.rb` (executor code, outside this story's
  ownership; the runner reads the table dynamically and its behavior is
  unchanged) and `docs/tour/sprint118-published-candidate-002.md` (a
  historical report of the candidate-002 replay, which really did have ten
  semantic rows and 70 oracle runs).
* Manager reviews this extension and independently gates (fresh executor run +
  offline gate) before merge.

## Manager acceptance, 2026-09-09

The manager authenticated all 1,207 native captures and independently rebuilt
the unchanged source, observing both exact legal outputs within 110 new runs.
The independent native witness gate passed in 1.909 seconds. Semantic, executor,
corpus and tamper checks passed in 51.319 seconds.

A fresh complete frozen-candidate010 run used the reviewed tables: all 291 mode
observations plus 77 native semantic oracle runs completed. Counts are native
97 PASS, interpreted 83 PASS / 14 FAIL, and compiled 97 PASS. The executor
gate remains FAIL because of those 14 runtime failures; its offline validation
reports those failures and the aggregate FAIL verdict, with no integrity findings.
No source bytes, old result records or runtime acceptance threshold changed.

Fresh root: `68fa76b3f0e2f87f35ca969d5424efb46863a32f0e4a2c74b741205be7836b90`.
Manager evidence root: `/Users/qiangli/.local/state/bashy/sprint118-evidence`.
Receipts: `tour-channel-order-manager-gate.json`,
`tour-channel-contract-manager-gate.json`,
`tour-channel-contract-full-manager-gate.json`.
Fresh observations: `tour-channel-contract-full/results.jsonl`; exact offline
findings: `tour-channel-contract-full/offline-gate.txt`.
This accepts the bounded channel contract correction; story 4 remains open.
