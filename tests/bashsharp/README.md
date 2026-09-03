# Bash# executable acceptance matrix

This directory is the executable acceptance boundary for the five Bash#
features accepted by the design of record:

1. keyword arguments;
2. default parameters;
3. deep readonly;
4. exhaustive enums; and
5. null-safety checking.

`matrix.tsv` is deliberately a small, closed denominator. Every feature has a
positive case, a near-miss, a forced-shell escape, an invocation with the
Bash++ selector disabled, an inert POSIX invocation, an unsupported-form
diagnostic, and a transpile/build/run parity check. Null safety additionally
uses the `check` command because it is a static rule and has no new syntax.

Run the executable gate with:

```sh
BASHY_BIN=/path/to/bashy tools/bashsharp/acceptance.sh
```

The gate is fail-closed. It requires a real executable target, exactly five
matrix rows, all fixture files, no `planned`/`skip` status, and a successful
selector probe. A missing selector or a missing compiler is a failure, never a
planned result. The target must be run from each fixture's directory so that
relative imports and source locations retain their meaning.

The plain-shell result is captured for each near-miss and escape. Bash++ must
match that result byte-for-byte, including exit status. POSIX+Bash++ must also
match the plain result, proving the ergonomics tier is inert in certification
mode. Positive and lowering cases require exact expected output and equal
interpreted/compiled exit status.

The top-level harness invokes the schema and tamper gates before checking the
target binary, then invokes this executable gate once the binary is available.
Thus a missing compiler cannot conceal a malformed denominator, while an
unavailable Bash++ selector remains a hard failure rather than a skip.
