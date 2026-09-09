# Sprint 118 Story 19: goroutine prefix contract

Candidate023 exposed a false negative in `say_interleaving`, the source-bound
comparator for `_content/tour/concurrency/goroutines.go`. Its baseline and
compiled observations each contained exactly five `hello` lines and four
`world` lines, while that run's seven native repeats happened to contain five
of each. Version 1 treated the minimum and maximum of seven scheduler draws as
semantic bounds and rejected `4` against `5..5`.

That range was not a program invariant. Candidate018 demonstrated the inverse:
its seven native repeats all contained four `world` lines while all three mode
observations contained five. Candidate021 and Candidate022 each retained both
four- and five-line native draws and passed. Those samples diagnose the
sampling mistake, but do not establish a new lower bound: source semantics
also permits zero through three `world` lines when the launched goroutine
receives correspondingly less scheduler progress.

## Version 2 contract

The unchanged pinned source calls `say("hello")` synchronously and starts
`say("world")` as a goroutine. Each call has a five-iteration ordered loop.
The two calls advance through the same sleep/print loop; when the synchronous
call finishes, `main` returns and terminates the concurrent call at whatever
point it has reached. Go provides no scheduler-progress guarantee for the
launched goroutine. Version 2 therefore checks the observable source semantics
directly:

- stdout is newline-terminated and every complete line is exactly `hello` or
  `world`;
- `hello` occurs exactly five times;
- `world` occurs zero through five times, representing an observable prefix
  of the launched call (including no launched-goroutine progress);
- no unknown, joined, partial, duplicated-above-five, or extra line is
  accepted; exit status and stderr remain exact;
- every native oracle observation must satisfy the same invariants and the
  minimum oracle size remains enforced. Burst variation is not required:
  Candidate018 proves seven legal scheduler draws can all have one stdout.

Because each call prints one repeated value, its count is the full observable
form of its internal order. There is no source-level cross-goroutine order to
invent. In particular, a finite native burst may establish that scheduling is
volatile, but it may not turn its sampled minimum into a semantic lower bound.
No other comparator changed.

## Retained-ledger compatibility

New executions record `tour-semantics/v2`. The offline gate recognizes v1 only
when the manifest carries the exact retained v1 library digest. It first
recomputes every stored semantic verdict and status with the v1 sampled-range
rule and verifies the sealed summary, verdict, and canonical root. It then
recomputes acceptance from the same immutable raw streams with v2. Thus old
PASS and FAIL claims remain authenticated under the contract that produced
them; no evidence record is rewritten. A historical FAIL can become a current
gate PASS only when every one of its 291 observations passes v2 and all normal
source, command, artifact, oracle, completeness, and integrity checks pass.

Candidate023 consequently validates offline under v2 for the principled
reason that both four-line observations are legal goroutine prefixes; the same
source rule also admits the zero-line prefix. A forged v1 digest, forged
semantic verdict, missing `hello`, sixth `world`, unknown or joined line,
unterminated output, missing observation, or tampered root still fails.
