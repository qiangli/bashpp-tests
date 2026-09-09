# Sprint 118 candidate008 — complete failing replay

The frozen manifest `95ac6edc0d61bb01959953022309313821acee0b70795120371c9c55c01f79c2`
binds sh `0c840ac9` and Bashy `ea60f34`. All 85 unchanged examples have three
attempt records and all 255 attempts spawned. This is a failing diagnostic.

| Mode | PASS | Mismatch | Normalization failure | Incomplete |
|---|---:|---:|---:|---:|
| Native oracle | 85 | 0 | 0 | 0 |
| Interpreter | 40 | 35 | 9 | 1 |
| Compiled | 84 | 0 | 0 | 1 |

All 35 candidate007 interpreter passes remain. New passes: file-paths, interfaces,
string-formatting, temporary-files-and-directories and text-templates.

The corrected harness binds each staged input tree to the mode consuming it.
Shared source/binary mutations still fail every mode; undeclared source additions
still fail their owning mode. Adapter thread errors are recorded against their
attempt and do not abort the rest of the replay. The old raw ledgers remain.
TCP still fails: interpreted source scratch survives signal termination, and the
compiled adapter reports a connection reset. Neither result receives PASS.

Raw commands, original source bindings, artifacts and streams are retained at
`~/.local/state/bashy/sprint118-evidence/runtime-integration-008/gbe/results.jsonl.fail`
and the adjacent work directory. The full parallel ledger is
`sprint118-candidate008-ledger.tsv`. No source or comparator was weakened.

Root digest: `350b335204d2ef888786bffe1b1709873564dd0d071920a21df47058e0defd15`.
Story #3 remains open; this anchor records the actual failing result.
