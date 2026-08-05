# bashpp-tests — Go 1.26 & POSIX 1003.1-2016 Conformance Test Suite for bash++

This suite implements **Test-Driven Development (TDD)** for **`bash++`** in `bashy`, maintaining **1:1 parity/fidelity** with official **Go 1.26** tests (`../go/test/`), **POSIX 1003.1-2016 (IEEE Std 1003.1-2016 / VSC-PCTS2016)**, and **GNU Bash 5.3**.

> **Headline Goal:** Certify `bashy` as **Go 1.26 compliant/conformant** for its `bash++` Go extensions, alongside its 100% GNU Bash 5.3 pass rate and POSIX 1003.1-2016 Shell baseline.

---

## 2-Tier Test Scope & Coverage Matrix

To maximize language fidelity while avoiding irrelevant host runtime internals, the suite adopts a 2-tier scope strategy:

| Tier | Source Directory | Included Scope | Purpose & Rationale |
|---|---|---|---|
| **Tier 1 (Mandatory)** | **`../go/test/`** | **100% Language Spec Suite** (3,404 `.go` files) | Validates 1:1 language compliance: `for`, `if`, `switch`, `range`, `defer`, `struct`, `map`, `slice`, `interface`, generics, `go routine`, `chan`, `select`, `clear()`, and `:=` assignments. |
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
│               Layer 3: Go 1.26 Feature Conformance                     │
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
