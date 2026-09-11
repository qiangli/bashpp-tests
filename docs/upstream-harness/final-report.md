# Sprint 157 differential result

Story `5b4efc2910e6` closes the migration gate with the exact authenticated Go
1.27 `cmd/internal/testdir` harness as the sole semantic authority. The active
runtime and documentation contain only Go, shell, data, patches, Markdown, and
the retained upstream license.

The representative matrix produces these honest outcomes:

| Path | issue21808 | cmplxdivide | Remaining rows |
|---|---|---|---|
| unmodified upstream native | pass | pass | upstream results retained |
| instrumented upstream native | pass, identical | pass, identical | 9/9 terminal verdicts identical |
| Bash++ interpreted | exact `A\n\nB\n` pass | exit 2 with current `complex128` diagnostic | non-run phases explicitly unsupported; upstream skip/bypass retained |
| Bash++ compiled | exact `A\n\nB\n` pass | two source inputs, empty program argv, pass | non-run phases explicitly unsupported; upstream skip/bypass retained |

The backend phase records repeat the compile-input/program-argument boundary
already chosen by upstream, and the independent observer confirms exact ordered
output, phase exit/timeout, terminal state, and identities. No native tested
source command is executed in backend mode.

## Recommendation

**GO for the Sprint 157 execution substrate.** It is a direct, authenticated
path from the current upstream Go harness to Bash++ interpreted and compiled
source execution. The future conversion of that same harness remains outside
this sprint.

**NO-GO for broad recipe-family expansion.** Compile-only, diagnostic,
directory/package, generated-output, and other non-run phases are intentionally
reported as unsupported rather than emulated. The current interpreted
`complex128` result is also a product limitation, not a harness success.
Sprints 149 and 150 remain blocked and every one of their trackers remains in
`todo`.

`tools/upstream-harness/final-gate.sh` enforces the active-surface removal rule,
the blocked tracker state, and then runs the existing native-equivalence,
direct-source backend, and minimal observer gates. It adds no new receipt chain,
packet format, broad negative suite, or process-management subsystem.

The final gate passed locally through `bashy gate` in 45.972 seconds. The same
gate passed on the authorized Linux host through one coordinator in 3m23.059s
at 2026-09-11T07:24Z, using the authenticated S157.2 identities. The post-run
process table was clean.
