# Test-Driven Development (TDD) Plan for bash++ (Go 1.26 Support)

**Strategy:** Test-Driven Development (TDD) — **Red → Green → Refactor**  
**Fidelity Goal:** 1:1 Parity/Fidelity with official **Go 1.26** tests (`../go/test/`)  
**Target Engine:** `bashy` (`sh/syntax` parser dialect `LangBashPP`, `sh/expand` `Object` values, `sh/interp` goroutine channels)

---

## 1. Scope Strategy: Tier 1 (Language Spec) vs Tier 2 (Exposed Stdlib)

- **Tier 1 (Mandatory - 1:1 Language Spec):** 100% of `../go/test/` (3,404 `.go` files).
  - Validates `for`, `if`, `switch`, `range`, `defer`, `struct`, `map`, `slice`, `interface`, generics, `go f(x)`, `chan`, `select`, `clear()`, and `:=` short assignments.
- **Tier 2 (Selective - Exposed Stdlib Packages):** Selective `*_test.go` files from `../go/src/` (`encoding/json`, `strings`, `bytes`, `sync`, `math`, `time`).
- **Excluded:** Internal compiler and host OS runtime packages (`runtime`, `syscall`, `cmd/compile`).

---

## 2. TDD Workflow & Cycle

```text
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ 1. RED: Add 1:1 Go 1.26 Test Fixture to bashpp-tests/tests/              │
 │    - Copy AST structure, assertions (panic/assertequal), and error checks│
 │    - Run harness -> Assert expected test failure                           │
 └─────────────────────────────────────┬─────────────────────────────────────┘
                                       │
 ┌─────────────────────────────────────▼─────────────────────────────────────┐
 │ 2. GREEN: Implement Feature in bashy Engine                               │
 │    - Add syntax tokens to sh/syntax (LangBashPP)                          │
 │    - Implement evaluation in sh/interp & sh/expand                        │
 │    - Run harness -> Assert test passes (both interpreted & transpiled)    │
 └─────────────────────────────────────┬─────────────────────────────────────┘
                                       │
 ┌─────────────────────────────────────▼─────────────────────────────────────┐
 │ 3. REFACTOR: Clean & Optimize Implementation                              │
 │    - Refactor AST handlers & Value unions                                 │
 │    - Run full regression matrix -> Ensure all tests stay green            │
 └───────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 1:1 Parity Mapping Table (Go 1.26 `../go/test/` → `bashpp-tests/tests/`)

| Go 1.26 Original (`../go/test/`) | bash++ Test Fixture (`bashpp-tests/tests/`) | Go Category & Semantics | Action Header |
|---|---|---|---|
| `for.go` | [`tests/for.bpp`](tests/for.bpp) | For loop, break, continue, range | `// run` |
| `clear.go` | [`tests/clear.bpp`](tests/clear.bpp) | Go 1.21+ / Go 1.26 `clear()` builtin for map/slice | `// run` |
| `chan/select.go` | [`tests/chan/select.bpp`](tests/chan/select.bpp) | Channel select, default, non-blocking send/recv | `// run` |
| `chan/fifo.go` | [`tests/chan/fifo.bpp`](tests/chan/fifo.bpp) | FIFO channel ordering across goroutines | `// run` |
| `assign.go` | [`tests/assign.bpp`](tests/assign.bpp) | `:=` short assignments, type checking | `// errorcheck` |

---

## 4. TDD Test Fixture Header Standard

Every 1:1 `.bpp` test fixture retains Go's exact header comments so the test harness can parse action modes automatically:

- `// run`: Executable test. Must run to completion and exit 0.
- `// errorcheck`: Diagnostic test. Must fail at compile/parse time with expected error pattern.
- `// build`: Compilation test. Must transpile to Go and build successfully.
