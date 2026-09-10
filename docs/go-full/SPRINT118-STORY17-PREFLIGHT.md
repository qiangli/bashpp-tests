# Sprint 118 Story 21 preflight advancing Story 17

Story 21 (`7a6a1e7ca5dd`) is a bounded, read-only preflight for its parent,
Story 17 (`b5d3bd1bd24c`). It records whether a complete official-Go replay
may be launched; it is not a replay result, product verdict, parity claim, or
completion claim. Story 17 remains **open**: no full 3,495-root replay ran.

## Decision: NO-GO

Do not launch or resume an official-Go corpus execution from this preflight.
The authenticated inputs and accounting are sound, but the retained-evidence
projection plus the required disk reserve exceeds free space. This is a launch
gate, not a PASS or FAIL for the product.

## Independently refreshed read-only evidence

The following checks were run against the live retained inputs without invoking
`product.rb`, `native.rb`, a phase shard, or a corpus executor:

| check | result |
|---|---|
| Relocated SDK re-authentication and relocation verification | PASS: Go `go1.27.0` darwin/arm64; current identity SHA-256 `209f68efa785e8ccb13f302eac5c8d1049567fd814c41d8bf5aaca44534851ad`; relocation manifest SHA-256 `3d061c0322b546005acf7ce1878aee4e4382a7dd2820feeb4c570fa267a23c2e`, state `complete`, 4 verified moves. |
| Source/inventory validation | PASS: authenticated source archive SHA-256 `7002403d7cc44529ef6d26f69a44818263395ead7c16c05a5808ae047ebeb0e5`; 2,726 testdir + 743 typechecker + 26 package roots = **3,495**; execution claim false. |
| Capped-attempt ledger regeneration | PASS: regenerated from retained `product-all-018` rows; ledger SHA-256 `f85bee883ccb1bd0fb984ce0f9e741ae178e4ebf9f268be1d04047bfbd5240d5`, byte-identical to the retained ledger. |
| SDK, inventory, and ledger unit checks | PASS: 3/3, 10/10, and 7/7 respectively. |

The capped attempt is correctly incomplete: 1,298 of 3,495 roots were
attempted, 2,197 are explicitly unattempted, the driver exited 143 at the
1,800-second cap, and 6,121 phase references remain missing. Its regenerated
report preserves `attempt_complete: false` and `completion_claimed: false`.
The report path necessarily names the temporary read-only regeneration output;
all substantive accounting fields and the retained ledger bytes match.

## Disk gate and reserve

Current `df -k` availability was 10,724,328 KiB (10.23 GiB). Retained
candidate018 product evidence measures 2,616,724 KiB across the 1,298
attempted roots. Linear extrapolation is therefore 7,045,802 KiB (6.719 GiB)
for 3,495 roots. The native evidence remains retained (2,055,816 KiB) and is
not credited as product execution.

The required 4 GiB reserve covers logs, temporary workspaces, and cache growth:

`6.719 GiB projected new retained evidence + 4.000 GiB reserve = 10.719 GiB`

That needs about 11,240,106 KiB, exceeding currently available space by about
515,778 KiB (0.49 GiB), before any unbounded shared-cache growth. Obtain more
disk or an independently approved lower-retention budget before launching a
new, absent evidence directory. Preserve existing evidence; do not convert this
preflight into execution.

## Parent-story continuation boundary

After the disk gate is independently cleared, Story 17 must authenticate the
same relocated SDK, source, candidate018 binding, module context, and retained
native oracle before using a new evidence directory for an unsharded resume or
complete shard. Any stopped attempt must again account for every inventory root
and every missing phase without assigning a verdict to an unattempted root.
Only a full authenticated replay can advance Story 17 beyond this preflight.

Sprint: #118
Story: #21 ID 7a6a1e7ca5dd
Story: #17 ID b5d3bd1bd24c
