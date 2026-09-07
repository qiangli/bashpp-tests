# Sprint 134 interpreted product fixtures

Run `ruby tools/agentic/acceptance.rb` from the repository root with
`BASHY_BIN` pointing to the current **bash or bashy product binary**. Set `BASH53`
to GNU Bash 5.3, or put GNU Bash 5.3 on `PATH` for automatic discovery.
Neither binary is built by this runner. Ruby uses only its standard library;
the repository's Go-by-Example and tour harness tools already require Ruby.

The existing TSV + `.bpp` + output-sidecar convention declares 13 cases. The
runner requires the exact denominator and rejects unlisted fixtures. Every case
runs through file, stdin and `-c`, with `BASHY_AGENTIC` unset and set to `1`.
Positive cases compare stdout exactly and require empty stderr. Scope negatives
require the scope diagnostic and empty stdout, proving the action body did not
run. Numeric syntax must fail. Every subprocess has a 15-second bound.
Child processes set the existing `BASHY_HINTS=off` configuration so advice such
as `cd` hints does not enter deterministic stderr comparisons. This does not
grant agentic scope; the independent unset/set `BASHY_AGENTIC` matrix remains.

Classic (`--no-bashpp`), POSIX and the Classic front door's
`--posix --bashpp` profile compare parse verdicts with independent GNU Bash 5.3
(the combined profile uses Classic GNU semantics, matching the product resolver);
the near-miss/quote compatibility script executes and compares all streams and
status. These fixtures do not depend on `.bpp` automatic selection.

`actions.bpp` presents typed functions, receiver methods, function and method
values, interface dispatch, a closure with an explicit block, shell functions,
and an ordinary utility pipeline. The same file is a standalone script with
normal arguments. Other cases cover ordinary helper/closure isolation,
eval/source behavior, return/failure restoration and current-shell state.

The production command-handler/chat adapter success, error and cancellation
fixture belongs to bashy. The engine owns positioned AST, one-byte parsing,
panic/cancellation and race checks. This corpus proves product source behavior;
it neither claims compiled parity nor closes the sprint by itself.
