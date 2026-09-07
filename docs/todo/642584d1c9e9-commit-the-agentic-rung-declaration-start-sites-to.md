---
id: 642584d1c9e9
kind: task
title: 'Agentic MVP: measure source forms and gate functions, scripts and tools'
seq: 7
status: done
priority: p2
created: 2026-09-07T08:33:48.101616Z
sprint: 134
---

Execution 2026-09-07: accountable owner codex-gpt5.6-sol; internal helper
`/root/agentic_corpus` owns Phase A in bashpp-tests; manager owns final gates.
Both baseline oracles measured definitions Class R and the block prefix Class E.

Final manager acceptance 2026-09-07: both rebuilt product matrices independently
pass 546 executions each; current two-oracle --check and --posix-gate pass all
205 shapes. Engine and native-adapter broad/race gates pass. The umbrella guard
migration preserves original Go coverage and mapping hashes, passes all 29
validator self-tests and 36 strict-closure checks. Exact integration/handoff
is recorded in the umbrella docs/sprint-134-handoff.md.

Moved from Sprint 131 to Sprint 134 for the user-approved bare `agentic` MVP.
An action is input -> output | error, including methods, functions, scripts,
commands, utilities and tools. Numeric determinism levels are not the contract.

Phase A (prerequisite for parser story be84e6c6dedf):
Commit the selected typed-function/method and shell-function prefixes to
tools/startsites/shapes.tsv and baseline.tsv. Prior scratch measurement recorded
eight Class-R candidates with bash 5.3.15 and bashy bc9e466; keep that historical
fact distinct from newly committed evidence and the selected bare spelling.
Measure the NEW `agentic {` block at its commitment point with completing
contexts, both required oracles, and buffered/one-byte parser cases. Do not
assume the block inherits the definition forms' classification. Where Class E,
require the decision-table row, near-miss fallback and command/quote escapes.
Numeric alternatives are rejection/compatibility cases, not accepted features.
Run the existing --check and --posix-gate according to repository gate policy.

Phase A measurement evidence (2026-09-07):
`tools/startsites/shapes.tsv` and its generated baseline now contain 17 selected
`agentic-*` rows, measured with GNU Bash 5.3.15 and baseline bashy bc9e466.
The three definition prefixes and completed bodies are Class R. The exact
`agentic {` prefix and `agentic { : }` argv form are Class E; a later rejected
multiline closing brace does not change the prefix's classification.
`tools/startsites/README.md` records the commitment table, command/quote escapes,
near-miss fallback, and numeric rejection versus ordinary numeric arguments.
Both `tools/startsites/classify.sh --check` and `--posix-gate` exit 0 over
205 shapes (86 R, 119 E, zero oracle disagreements). These checks only parse;
buffered/one-byte feature admission remains with parser story be84e6c6dedf and
product execution remains Phase B below. No final sprint gate is claimed here.

Phase B (final verification after runtime 1a1dc881f966 and bridge 872f9f15885f):
Add a bounded agentic fixture group using existing harness conventions. Prove
normal input/output/error behavior for a typed function, receiver method, shell
function, standalone script and command/utility/tool wrapper. Include a marked
callable passed by value/interface; an explicit region in a closure; ordinary
helpers; eval/source; restoration on return/failure; and concurrent isolation.
A marked call outside explicit scope must fail before its body executes.
An unmarked helper must not inherit implicit assistance.

The bounded source/product corpus is `tests/agentic/cases.tsv` (13 cases), run
by `BASHY_BIN=/path/to/current/bash ruby tools/agentic/acceptance.rb`. The
main harness invokes it and excludes its expected negatives from generic
fixture grading. It exercises file/stdin/-c with ambient opt-in unset/set,
plus GNU-oracle Classic/POSIX comparisons. The baseline product bc9e466
correctly fails the new feature assertions; passing evidence requires the
updated product binary. Native adapter/provider tests remain owned by bashy.

Phase B product evidence (2026-09-07): both commands below exit 0 and report
13 cases / 546 product-oracle executions each against GNU Bash 5.3.15:

```sh
BASHY_BIN=/tmp/sprint134.JlFdIu/bash ruby tools/agentic/acceptance.rb
BASHY_BIN=/tmp/sprint134.JlFdIu/bashy ruby tools/agentic/acceptance.rb
```

The runner sets existing `BASHY_HINTS=off` to suppress optional advice during
stream comparisons, while still testing `BASHY_AGENTIC` unset and `1`.
Binary SHA-256: bash `96bb4509998c02165841ee3309c65e6f5f1ace977865c572c08cec08d8996dd1`;
bashy `c15b25297bddb04fedd71484321499d8d90d2c7d2d4d5e895ce76392dcb4f52e`.
The earlier product exposed 22 `-c` parsing failures; the corrected build now
passes those same assertions. Engine and native adapter evidence, final commits
and Sprint 117 handoff are recorded by the manager in the umbrella.

Drive one production LLM adapter through its injectable runner/local fixture:
success, provider error and cancellation. Assert actual dispatch and scope
observations, not only emitted prose. Verify command argv/stdin/stdout/stderr/
status preservation, ordinary tool pass-through, no automatic retries, and that
BASHY_AGENTIC does not supply source opt-in. Run the actual file/stdin/-c product
entry paths and the existing Classic/POSIX matrix. No paid model is needed for
the deterministic gate; provide a runnable configured-provider example.

Record exact revisions, commands/results and the Sprint 117 handoff in the
umbrella. Sprint 134 proves interpreted execution only. Sprint 117's lowering
story adds compiled parity with the SAME deterministic provider fixture;
independently sampled live-model prose is never the byte-equality oracle.
Do not claim syntax admission or behavior from scratch measurements alone.
