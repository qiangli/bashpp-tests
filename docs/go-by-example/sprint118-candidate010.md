# Sprint118 candidate010 — complete failing replay

Frozen manifest `8b8203c4c679e2bba4bfed3b49c51bfe061054594bb4164bc368ffc59f67d040`
binds sh `b83807fa` and Bashy `ea60f34`. All85 originals and255 attempts ran.

| Mode | PASS | Mismatch | Normalization failure | Incomplete |
|---|---:|---:|---:|---:|
| Native oracle |85|0|0|0|
| Interpreter |39|37|8|1|
| Compiled |84|0|0|1|

Compared with candidate008, new interpreter passes: examples/structs/structs.go, examples/switch/switch.go.
Three prior passes regressed under a new copied-slice boundary: examples/execing-processes/execing-processes.go, examples/sha256-hashes/sha256-hashes.go, examples/text-templates/text-templates.go.
They remain failures in this frozen record. Corrections are assigned to the native
bridge worker; this candidate is not published as the canonical runtime.
TCP remains incomplete in both product modes. All original source bytes,
comparators, raw streams, process records and compiled artifacts are retained.

Full ledger: `sprint118-candidate010-ledger.tsv`.
Raw evidence: `~/.local/state/bashy/sprint118-evidence/runtime-integration-010/gbe/results.jsonl.fail`.
Root digest: `0b4e23d70a888436ad562a961a75cb93bcef280ad6fac11c8463b71a36088b90`.
Story3 remains open. No native-only interpreter credit or release certification.
