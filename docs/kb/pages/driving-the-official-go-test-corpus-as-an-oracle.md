---
type: lesson
title: Driving the official Go test corpus as an oracle
description: 'How to actually execute GOROOT/test/**/*.go with a pinned Go toolchain — WHEN building a conformance oracle against upstream Go tests (keywords: testdir, go corpus, compiledir, rundir, runoutput, GOTOOLCHAIN, importcfg)'
status: validated
evidence: |-
    bashpp-tests Sprint 98 Story 175: tools/go-oracle executes a 35-file tranche of go1.27.0 test/ across run/build/errorcheck/compile/compiledir/rundir/runoutput; 35/35, 71 spawned commands, re-verified after the integrity hardening below.

    SEMANTICS LIVE IN src/cmd/internal/testdir/testdir_test.go, not test/run.go — run.go was removed in Go 1.21 and is NOT in the corpus. Read the action switch there; the flag parsing (-1/-0/-s/-t/-goexperiment/-godebug), stdlibImportcfg via 'go list -export -f {{if .Export}}packagefile {{.ImportPath}}={{.Export}}{{end}} std', errorCheck's splitOutput/partitionStrings/matchPrefix, and the fixed 'dirs' list are all load-bearing. A '<name>.dir' subdirectory holds INPUTS, never test cases.

    TOOLCHAIN VS CORPUS ARE TWO DIFFERENT DOWNLOADS. GOTOOLCHAIN=goX.Y.Z gives you a distribution under $(go env GOMODCACHE)/golang.org/toolchain@v0.0.1-goX.Y.Z.<goos>-<goarch>/ whose src/ is byte-identical to the source tarball but which has NO test/ directory. Use the tarball for test/, the module-cache dist for bin/go. Verify they agree by sha256-ing a shared src/ file — that also gives you the digest to pin the runner semantics against, so a Go upgrade fails the gate instead of silently invalidating your reimplementation.

    MUTATION-TESTING A COMPILER DRIVER: a stub 'go' that exits non-zero for everything fatals during startup probes, never reaching a compile — so the sabotage proves nothing. The stub must answer 'version', 'env' and 'list' successfully and fail only the real work. Assert on the recorded argv and exit code, not just on pass/fail counts.

    Determinism: normalize $GOTOOL/$GOROOT_TEST/$WORK out of recorded commands and use index-named scratch dirs (t-%04d) instead of MkdirTemp, or results are undiffable between runs.

    EXIT 0 IS NOT AN ARTIFACT. `go tool compile`/`link`/`go build` can exit 0 and write nothing, or a zero-byte file. Assert the artifact after every step: exists, regular file, non-empty, right kind — Go object archives (.o AND .a) begin "!<arch>\n", linked binaries are ELF/Mach-O/PE and mode +x. Mutation-test it with a fake `go` that exits 0 and touches an empty -o target; a driver that only RECORDS artifact_bytes will report 0 bytes next to status "pass".

    THE .out SIDECAR IS THE EXPECTED RESULT, SO PIN IT — and pin its ABSENCE. GOROOT/test inventories are usually **/*.go only, which leaves every .out, .s and .dir membership unchecked. A missing .out means "must print nothing", so a .out created after review silently rewrites the expectation: record absent sidecars as real rows. For a "<name>.dir", digest the sorted "<relpath>\t<sha256>" listing rather than each file, so ADDED and DELETED members are caught too — neither is an edit to any file a *.go inventory lists, and both change package grouping and compile order.

    `go version` IS FORGEABLE — IDENTIFY THE TOOLCHAIN BY CHECKSUM. Three layers that a stub cannot fake: (1) `go env GOROOT` must contain the byte-identical upstream sources of the pinned release (VERSION, go.env, src/... ), digests taken from the officially-checksummed SOURCE tarball — a binary distribution's src/ and VERSION are byte-identical to it; (2) the `go` binary must be a native executable (ELF/Mach-O/PE magic), which excludes shell-script stubs outright; (3) its sha256 must match a reviewed per-(goos,goarch) row. Two independent origins for that digest: the go.dev/dl published archive sha256 (`https://go.dev/dl/?mode=json&include=all`) and the module-cache ziphash at $GOMODCACHE/cache/download/golang.org/toolchain/@v/<ver>.ziphash, which sum.golang.org attests. Verified for go1.27.0 darwin/arm64: the tarball's go/bin/go and the module distribution's bin/go are the SAME bytes. Consequence for testing: sabotage toolchains must then be COMPILED binaries, not scripts.

    ENV COMES FROM `go env -json` OF THE PINNED TOOLCHAIN, NOT runtime.GOOS. GOOS/GOARCH/GOEXPERIMENT/GODEBUG/CGO_ENABLED. The -goexperiment/-godebug recipe flags APPEND comma-separated to those bases (replacing them runs the test in a different environment than upstream). Upstream's "run" fast path also requires goos/goarch/goexp/godebug to be unchanged — drop that and a -godebug test runs without its GODEBUG. $GO_TEST_TIMEOUT_SCALE multiplies every `-t N`; an unparseable value is fatal upstream, not silently 1.

    STATE THE BOUNDARY IN THE MACHINE-READABLE OUTPUT. testdir_test.go's `switch action` has 17 actions; a bounded tranche that executes 7 must enumerate the other 10 with reasons, publish them in the result summary, and re-derive the 17 from the pinned source so a new upstream action fails the gate instead of going unclassified. And make every fatal path write the summary with executed/failed counts — a fatal that leaves only prose is indistinguishable from a run that never started.
source:
    tool: claude-opus5-d
    host: dragon
    episode: weave-issue-4
created: "2026-09-03T10:01:29Z"
---
