# leaf-152 run 1b — the 84 run-0 roots on candidate 2

Input: `../leaf-152/roots-r1b.tsv` (the 84 roots 152 owned after run 0).
Candidate 2: bashy `963ef4b` on shell runtime `074f29aa` (`bashy.real`
sha256 `3bd715b1…`, rebuilt on the host) — S152.1 identity lowering (emitter
classes C2, C4, C5, C6, C7, C9, C10, the lower half of C1 and the C11 layout
parts), S152.2 converter localizations, S152.4 source maps; harness `c222dba`
(H1 listing normalization, file-argument asm build, `-race` link pairing).
2026-09-12 10:22Z–10:37Z, exit 3, zero seam failures.

| lane | terminals | non-PASS |
|---|---:|---:|
| native | 84 | 0 |
| interpreted | 84 | 62 (44 of them the declared asmcheck `unsupported`) |
| compiled | 84 | **25** (was 84 at run 0) |

Ownership (v6 rules): **152 = 23** (was 84), retained = 44 (asmcheck roots
whose compiled mode now passes), 153 = 2 (`bug367.go`, `reorder.go` — runtime,
per the triage in `sh/gosource/testdata/sprint152/triage/`), 154 = 2
(`closure3.go`, `devirtualization.go` — `-m` diagnostics now that their
compiled lowering succeeds), both-mode PASS = 13.

The 23, by mechanism: asmcheck `opcode not found` — 11 roots (C1 converter
half: `clobberdead`, `clobberdeadreg`, `issue59297`, `regabi_regalloc`,
`zerosize`; C3 constants: `condmove`, `switch`; to re-attribute on candidate
3: `append`, `comparisons`, `issue60324`, `memops`); unused aliased imports
(C8) — 8 roots; `alias3.go` (alias declaration across the package map) and
`fixedbugs/issue24801.go` (a `compiledir` root reaching the single-file path)
— converter; **interpreted-mode** user `//line` position reporting
(`issue18149.go`, `issue22662.go`: `want /foo/bar.go:N`) — the interpreter's
`runtime.Caller` view, not the emitter (the compiled side was closed by
S152.4). Every one of these is either owned by the two converter lanes in
flight (C1/C3/C8/C11) or routed at closure.
