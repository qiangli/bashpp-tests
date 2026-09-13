# Sprint 162.6 — the Bash++-ON classic regression (`cprint`, `procsub`)

Story `5c6251698ece` (#70 here); product half `e838e8895341` (sh #96).
Lane `classic-confirm`. Seam here: `tools/classic-gate.sh` + `docs/`.
No product code is changed by this record.

## The claim under test

`tools/classic-gate.sh` (S155.8) on the published candidate at the darwin
venue: Bash++ OFF 86/86; Bash++ ON 84 PASS + `cprint` FAIL (output differs
from `cprint.right`) + `procsub` TIMEOUT (60.02 s). One record, container
gate (`make test-bash-container[-bashpp] BASH53_OCI=podman`), unconfirmed on
Linux.

## What "Bash++ ON" measures (read before interpreting either fixture)

`make test-bash-container-bashpp` passes `BASHY_BASHPP=1` into the hermetic
container; `tools/bash53suite` inherits it and launches every fixture as
`bash ./<name>.tests` (NOT `bash ./run-<name>`: `fixtureFiles` maps the
`run-*` driver to its `.tests` payload). The shell consumes the selector at
its own process boundary (`internal/cli/main.go`, `consumeInvocationSelectors`
+ `os.Unsetenv`), so:

- the fixture script itself (`cprint.tests`, `procsub.tests`, …) runs with
  the Bash++ dialect live (`interp.Lang(LangBashPP)`, option hidden from
  `set -o` via `HideBashPPOption`);
- every nested `${THIS_SH}` it launches is Classic (verified: a `x := 5`
  probe parses only at the top level, never in a nested script).

So the ON gate is exactly the isolation contract: *a Classic-shaped script
must behave byte-identically with the Bash++ dialect active*. The Makefile's
"selected only for each top-level run-* harness process" wording is
inaccurate by one level (the `.tests` file is the top-level process) but the
intent is the same.

## Step 1 — Linux confirmation (the leaf host, native serial gate)

No podman on the leaf host; the hermetic SERIAL gate (`make test-bash`, the
same `tools/bash53suite` runner the container bakes) was run natively under
the coordinator lock, against clones of the published base trees, by
`classic-on-sprint162/leaf-classic-native.sh` (committed here; the exact
commands are in it). Venue: the leaf host, 2 vCPU, Ubuntu 24.04, pinned Go
1.27.0 linux/amd64 (`GOTOOLCHAIN=local`), `GOMAXPROCS=2`; the fixture tree is
the SHA-256-verified GNU Bash 5.3 tarball bashy fetches into its user cache.

LINUX_RESULTS_PLACEHOLDER

## Step 2 — root cause (read-only in `sh`; the product fix is sh #96)

### `procsub` — the shell's own open of a process-substitution FIFO waits for a Bash++ peer that can never register

`procsub.tests` passes every construct up to line 58 (`cat <(…)`, `source f
<(…)`, `f1 <(…)`): the FIFO path is handed to an external command or to a
function that hands it to `cat`, so the FIFO is opened natively by that
process. Line 74 is the first place the *shell itself* opens a
process-substitution FIFO through a redirection:

```sh
	while read -ru3 x
	do
		echo -n :
	done 3< <(echo x)
```

Path under Bash++ (all in `sh/interp`):

1. `Runner.Run` on a `*syntax.File` sets `bashPPFileRun = true` and, when the
   dialect is `LangBashPP`, creates the File's task group
   (`bashPPConcurrency`) — `api.go` ~3185.
2. `redir` → `openFile` → `bashPPTaskOpen` (`runner.go` ~9950,
   `bashpp_concurrency.go` 496). `groupOpen` is true because
   `r.bashPPFileRun && r.Dialect() == LangBashPP` — no `go`/`chan` has to
   exist.
3. `bashPPFIFOOpen` (`bashpp_fifo.go` 56) → `bashPPFIFOAcquire`
   (`bashpp_fifo_unix.go`): `fstatat` reports `S_IFIFO` (process
   substitution is a `mkfifo` in `r.tempDir`, `runner.go` 226–330), so the
   open is treated as a Bash++ FIFO rendezvous: a non-blocking read
   descriptor plus a probe, registered in `c.fifos`, then a `select` on
   `e.ready` until *a descriptor registered in the same task group* opens the
   opposite direction. The file's own comment: "A native peer is deliberately
   insufficient … an external writer must not turn an unmatched read into
   premature EOF."
4. The process-substitution writer is exactly such a native peer: the
   `ProcSubst` goroutine does a plain `os.OpenFile(path, O_WRONLY)`
   (`runner.go` ~279). That open succeeds at once (the probe from step 3 is a
   reader), `echo x` writes into the pipe, the goroutine exits, and nothing
   ever closes `e.ready`. The main goroutine sits in the `select` forever.

Darwin shows the shape directly: the Go runtime reports `fatal error: all
goroutines are asleep - deadlock!` with goroutine 1 in
`(*Runner).bashPPFIFOOpen` ← `bashPPTaskOpen` ← `redir.func3` ← `redir` ←
`stmtSync` (2.1 s, FAIL). In the container / on Linux a runtime goroutine
(signal/netpoll) is not parked, the detector stays silent, and the fixture
is the 60 s TIMEOUT that was recorded.

Classic never enters this path: with `LangBash` `groupOpen` is false and
`bashPPTaskOpen` falls through to `r.open` — a plain blocking open, matched
by the goroutine's blocking open, exactly Bash.

**Outside-corpus reproducers** (`classic-on-sprint162/reproducers/`, darwin
+ the leaf host, Classic vs `BASHY_BASHPP=1` / `--bashpp` — same result for
both selectors, and for `-c`):

| script | Classic | Bash++ ON |
| --- | --- | --- |
| `procsub-redir.sh` — `read -r x < <(echo hello)` | 3 lines, rc 0 | darwin: Go deadlock fatal, rc 2; Linux: hang (rc 124 under a 10 s bound) |
| `procsub-redir-out.sh` — `echo out > >(cat)` | `out`, rc 0 | hang, rc 124 |
| `procsub-external-control.sh` — `cat <(echo viacat)` (positive control) | `viacat` | `viacat` |
| `fifo-external-peer.sh` — `mkfifo p; cat p & echo x > p` | 2 lines, rc 0 | hang, rc 124 |
| `fifo-subshell-peer-control.sh` — `( echo > p ) & read < p` (negative-set control) | `read: bg-writer` | `read: bg-writer` |

`fifo-external-peer.sh` is the same defect one level up: any Classic script
that opens a named FIFO whose peer is an external process hangs under
Bash++ activation. Process substitution is the instance the GNU corpus
happens to exercise.

**Fix brief for sh #96 (two mechanisms, both general, neither keyed to a
fixture):**

- **A — process-substitution endpoints are shell-owned peers.** In
  `ProcSubst` (`interp/runner.go` ~279/~293) open the FIFO through the same
  group-aware path the redirection uses — `r2.bashPPTaskOpen(ctx, path,
  os.O_WRONLY|…, 0, false, false)` on the subshell runner (which shares
  `bashPPConcurrent`, `api.go` ~3556) — instead of the raw `os.OpenFile`.
  Under `LangBash` that is the identical blocking open (no Classic change);
  under `LangBashPP` both ends register in `c.fifos` and match, exactly as
  the `( … ) &` subshell peer already does. Reproducers A/A' turn green;
  the corpus fixture follows. Test under
  `interp/testdata/sprint162/classic/` with A, A', the external-cat control
  and the subshell-peer control, run in both dialects.
- **B — the isolation gap.** `groupOpen` fires for every FIFO in a Bash++
  File even when the File has no task; the "native peer is insufficient"
  rule is only meaningful once a task group has concurrent members. A
  Classic-preserving refinement is to require the registered-peer
  rendezvous only when the group has (or has had) a task — before that, a
  FIFO open is single-threaded and the plain blocking open is Bash. This is
  a design choice for the sh lane (the early-descriptor snapshot comment in
  `bashPPFIFOOpen` is the constraint to keep); A alone certifies the corpus,
  B is what the isolation contract literally says. Recorded, not decided
  here.

### `cprint`

CPRINT_PLACEHOLDER

## Requests to other seams

- **sh (#96, e838e8895341):** mechanisms A and B above, with the reproducer
  set; the leaf evidence paths are listed under Step 1.
- **bashy (`Makefile`, `test-bash-container-bashpp` doc line):** wording —
  the selector reaches the fixture's `.tests` process, not a `run-*` driver.
  No behaviour change requested.
