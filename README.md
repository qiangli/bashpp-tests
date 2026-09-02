# bashpp-tests — Go 1.27 profile & POSIX 1003.1-2016 conformance suite for Bash++

This suite implements **Test-Driven Development (TDD)** for **Bash++** in `bashy`, maintaining the enumerated **Go 1.27 profile** against official Go tests (`../go/test/`), **POSIX 1003.1-2016 (IEEE Std 1003.1-2016 / VSC-PCTS2016)**, and **GNU Bash 5.3**.

> **Headline goal:** validate `bashy`'s `bash++` extensions against the
> **enumerated `go1.27-profile-v1`** — the Go-1.27-shaped constructs the design
> of record actually claims — alongside the GNU Bash 5.3 gate and the POSIX
> 1003.1-2016 baseline.
>
> **Not** "Go 1.26 compliant/conformant", which this file used to say. Go 1.27
> is an upstream *language coordinate*, not a promise to accept arbitrary Go
> source: `package`, `goto` and labels are permanent shell fallback, and every
> other construct is delivered by a named phase. The claim is the profile, and
> the profile is enumerated in
> `../docs/bashpp-posix-superset-syntax.md` §Committed Start Sites.

---

## 2-Tier Test Scope & Coverage Matrix

To maximize language fidelity while avoiding irrelevant host runtime internals, the suite adopts a 2-tier scope strategy:

| Tier | Source Directory | Included Scope | Purpose & Rationale |
|---|---|---|---|
| **Tier 1 (Mandatory)** | **`../go/test/`** | Language-spec corpus — see the denominator note below | `for`, `if`, `switch`, `range`, `defer`, `struct`, `map`, `slice`, `interface`, generics, `go f(x)`, `chan`, `select`, `clear()`, `:=`. Scope is the enumerated `go1.27-profile-v1`, not the whole language. |
| **Tier 2 (Selective)** | **`../go/src/`** | **Exposed Utility Packages** (~150 `*_test.go` files) | Validates standard library utility packages exposed to `bash++` scripts via builtins & the Go bridge: `encoding/json`, `strings`, `bytes`, `sync`, `math`, `time`. |
| **Excluded** | **`../go/src/`** | Internal compiler & host OS runtime (`runtime`, `syscall`, `cmd/compile`, assembly) | Internal Go host implementation details not surfaceable to shell scripts. |

---

## TDD Workflow & Cycle (Red → Green → Refactor)

1. **🔴 Red Phase (Write 1:1 Test First):**
   - Add 1:1 adapted test fixtures from `../go/test/` directly into `bashpp-tests/tests/`.
   - Action headers (`// run`, `// errorcheck`, `// build`) are parsed automatically by `harness/run.sh`.
   - Run `harness/run.sh` to confirm expected test failure for unimplemented Go features.

2. **🟢 Green Phase (Implement Engine Support):**
   - Implement syntax tokens in `sh/syntax` (`LangBashPP`), type evaluation in `sh/expand` (`Object`), and goroutines/channels in `sh/interp`.
   - Pass tests in both interpreted mode (`bashy --bashpp`) and transpiled mode (`bashy transpile -> go build`).

3. **🔵 Refactor Phase:**
   - Optimize AST evaluation, channel synchronization, and memory allocations while keeping the full test suite green.

---

## 5-Layer Testing Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│                   Layer 1: Measured Superset Gate                       │
│  Assert zero regressions on GNU Bash 5.3 (86/86) & POSIX 1003.1-2016  │
│  with bashy --bashpp and bashy --posix --bashpp                       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│              Layer 2: Dual-Mode Execution Verification                 │
│   Byte-identical output: Interpreted (bashy) vs Transpiled (go build) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│               Layer 3: Go 1.27 Profile Conformance                     │
│   1:1 Parity with ../go/test/ (for, chan, select, defer, clear, etc.) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│               Layer 4: Auto-JSON OS Boundary Verification              │
│   Native Go objects <--> JSON auto-serialization across pipes/binaries │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│            Layer 5: Compiler Diagnostics & Negative Checks             │
│   1:1 // errorcheck validation for unassignable/invalid Go constructs  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Key References

- [**`TDD_PLAN.md`**](TDD_PLAN.md): Detailed TDD methodology, 1:1 test parity plan, and tiering matrix.
- [**`PLAN.md`**](PLAN.md): Conformance architecture and dual-mode runner specification.
- [**`harness/run.sh`**](harness/run.sh): Master test runner script.

## Spelling: exact Go, no substitutes

Constructs are written in **exact Go**. `go f(x)`, not `go routine { … }`;
`defer f(x)`; `x, err := f()`; `make(chan T, n)`; `select { … }`. The two-word
and builtin-style forms an earlier draft of this suite used —
`go routine`, `gather`, `call` — were **abolished** by the L4 addendum in
`../docs/bashpp-posix-superset-syntax.md`, which is the design of record.

The reason is now measured rather than argued: `go build ./...` **parses** in
bash 5.3 while `go worker(a, b)` is **already a syntax error**, so the collision
the two-word form was invented to avoid is resolved by the parens. See
`tools/startsites/` for the derivation.


## The Tier-1 denominator is currently unverifiable

This suite has claimed a Tier-1 corpus of **3,404 `.go` files** under
`../go/test/`. **That tree is not mounted here** — it is absent from disk and
from `.gitmodules` — so the denominator cannot be checked, and the handful of
adapted fixtures were transcribed by hand rather than derived from it.

Recorded rather than quietly dropped, because a denominator nobody can check is
the exact shape of a number that drifts into being quoted as fact. Two honest
resolutions, either acceptable:

- **mount it** as a pinned sibling and let the runner derive the denominator; or
- **restate the scope** as the fixtures actually present, and describe
  `../go/test/` as the upstream *source* the corpus is adapted from rather than
  a suite this repo runs.

Until one of those happens, treat "3,404" as provenance, not coverage.
