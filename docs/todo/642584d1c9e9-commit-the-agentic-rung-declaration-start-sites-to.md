---
id: 642584d1c9e9
kind: task
title: Commit the agentic rung-declaration start sites to the corpus (measurement DONE — all Class R)
seq: 7
status: todo
priority: p2
created: 2026-09-07T08:33:48.101616Z
sprint: 131
---

THE MEASUREMENT IS DONE AND IT IS RECORDED HERE. What remains is to make it DURABLE by committing the rows, so the ratchet covers them. Design of record: docs/agentic-tool-duality-design.md section 14 in the umbrella (sprint 131, story dbe12300f0e1); the consuming Bash++ story is 72cd8bec on sprint 117, PROPOSED and owned by the Bash++ gates.

WHAT WAS ASKED. Bash# admissibility test 1 requires a COMMITTED START SHAPE, and the standing rule in the design is that test 1 is MEASURED by tools/startsites and NEVER ASSERTED. An earlier probe in the umbrella session had rejected four candidate spellings under a stock bash and was recorded as an INDICATION of Class R rather than a classification, deliberately, for three reasons this tool makes explicit: it used ONE oracle where classify.sh requires TWO, since a classification produced by only one would silently become an assertion again; it ran bash 3.2 rather than the 5.3 the tool enforces; and it measured COMPLETE FORMS rather than the commit point, which the README warns records a site as free when it is not, because a parser decides at the opening line and never sees the closing brace first.

THE MEASUREMENT, run with classify.sh --tsv against a SCRATCH corpus via the SHAPES override, so nothing committed was touched. Oracles: bash53 = GNU bash 5.3.15(1)-release aarch64-apple-darwin25.4.0, bashy = GNU bash 5.3.0(1)-bashy-dev bc9e466. Eight shapes, classified at the COMMIT POINT: agentic function f() open-brace; agentic f() open-brace; agentic func f() open-brace; agentic 3 func f() open-brace; agentic(3) func f() open-brace; at-agentic func f() open-brace; agentic:3 func f() open-brace; plus one complete form as a control.

RESULT: 8 shapes, 8 CLASS R, 0 class E, 0 engine disagreement, both oracles agreeing on every row. Every candidate spelling of the declaration is PURELY ADDITIVE - no existing script can contain it, so Bash++ may claim the shape with NO TABLE ROW, NO NEAR-MISS FALLBACK, NO command-or-quote ESCAPE and no compatibility risk. Two things worth drawing out. The level-carrying parenthesised form agentic(3) is also Class R, which matters because the declaration must carry a LEVEL rather than a boolean - a boolean would collapse five rungs into two, keeping the TRUST boundary and losing the COST boundary entirely - and it is a further instance of the law this corpus already exposed, that the parenthesised call is Bash++'s free disambiguator, since bash's only word-open-paren production is name-open-paren-close-paren. And the prefix and complete forms agreed here, which is NOT guaranteed in general and is exactly why the commit point is the thing to measure.

THE WORK REMAINING, and it is small. Add these rows to the committed shapes.tsv with a real id, phase and feature, regenerate baseline.tsv, and confirm classify.sh --check is green so the ratchet catches a future class flip. Also run --posix-gate, the cert-safety mode that proves Bash++ syntax is inert under posix, since section 14.9's hard limit is that the construct is inert under posix and the GNU Bash and POSIX gates stay green with the feature absent, disabled and enabled - that gate is the one that proves it rather than asserting it.

SCOPE NOTE. This story covers the CORPUS ROWS only. It does NOT admit the keyword to the language, does not choose the spelling among the seven, and does not authorize any parser change: per section 14.8 the declaration syntax, the Bash# interaction and the activation semantics are Bash++ design decisions owned by the Bash++ gates, and this measurement is an INPUT to that decision rather than a substitute for it. A Class R result says a spelling is FREE to claim, not that it SHOULD be claimed.

COORDINATION. This repo is actively worked - recent commits integrate the Bash# executable contract - so the corpus edit should either be taken by that lane or coordinated with it before landing. The measurement above required no repo change and none was made.
