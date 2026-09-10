---
id: fefd7568230c
kind: task
title: 'S4 the reproducibility gate: make the guarantee runnable'
seq: 26
status: todo
priority: p1
created: 2026-09-10T10:45:34.548954Z
sprint: 146
---

The v1.0.0 agentic product IS this gate. Today every guarantee in the spec is prose.

Authored BEFORE the implementation it gates, per the output-reduction-eval
precedent: write the harness while there is no incentive to soften it.

POSITIVE - the determinism guarantee. With agentic OFF, run an action twice with
every input pinned - clock, RANDOM seed, environment, cwd, filesystem state -
and require BYTE-IDENTICAL stdout, stderr and exit status. Cover each action
form: typed function, receiver method, shell function, block, script, compiled
command and a builtin that declares support. A form with no case is a form with
no guarantee.

NEGATIVE - the guarantees that are the product. With agentic OFF prove: no model
is selected, no network connection is opened, nothing is spent, no permission is
granted, and no environment variable supplies authority the source did not.
Prove inertness under --posix, where no Bash++ grammar may activate at all.
Prove numeric forms are still rejected: the MVP chose a bare boolean and
agentic(1) must remain a syntax error.

WITH AGENTIC ON, assert only what the contract actually promises: that
divergence is PERMITTED. Do not assert that output differs - a deterministic
lower rung resolving is a legitimate result, and a test demanding difference
would force non-determinism the contract never required.

ANTI-LAUNDERING, both domains. Without an opt-in, assist output stays on stderr,
marked model-derived, never merged into stdout, never altering an exit code or a
stdout format. With an opt-in, altering stdout and exit status is permitted -
that is what the opt-in released. Gate both directions; a rule with only one
tested side is half a rule.

TAMPER CONTROLS. A harness that cannot reject forged evidence does not gate
anything: prove the gate fails on a substituted binary, an empty result counted
as a pass, and a case silently skipped.

Sprint: #146
