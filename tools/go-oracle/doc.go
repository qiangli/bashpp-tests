// Command go-oracle executes a bounded, reviewed tranche of the pinned official
// Go test corpus with a real Go toolchain and emits one machine-readable result
// record per selected file.
//
// WHAT THIS IS, AND WHAT IT IS NOT.
//
// This is the trusted Go *oracle*. It establishes what the upstream corpus
// actually does when the pinned toolchain runs it, so that later Bash++ work has
// a ground truth to be compared against. It makes NO Bash++ parity claim, and it
// never reports a file as executed unless a process was actually spawned for it.
//
// The predecessor of this driver classified corpus files from their action
// header and stopped there. A metadata-only contract like that cannot tell a
// green suite from an empty one: every counter it printed was derived from the
// same inventory row it was supposed to be checking. Nothing here is derived
// from the inventory. Every verdict below is the exit status of a command whose
// argv, exit code, wall duration and produced artifact are recorded in the
// output.
//
// SEMANTICS.
//
// The action semantics are those of the official upstream runner — historically
// GOROOT/test/run.go, since Go 1.21 GOROOT/src/cmd/internal/testdir/testdir_test.go.
// This driver is a clean-room reimplementation of that runner restricted to the
// tranche-1 action set (run, build, errorcheck, compile, compiledir, rundir,
// runoutput), and it refuses to run unless the upstream runner it was written
// against is byte-identical to the one in the corpus under test: see the
// -semantics-sha256 flag. Semantic drift is therefore fail-closed rather than
// silent.
//
// Upstream structure is preserved rather than flattened:
//
//   - Directory grouping. compiledir and rundir compile the sibling
//     "<name>.dir" directory as packages, grouped by package name in
//     lexicographic file order, in dependency order, through a generated
//     importcfg — not as a bag of loose files.
//   - Generator semantics. runoutput runs the corpus file, treats its stdout as
//     a Go program, writes it to tmp__.go and runs *that*. The generated program
//     is recorded as the artifact.
//   - Directory scope. Only the upstream "dirs" list is a valid test location;
//     a ".dir" subdirectory holds inputs, not test cases.
//   - Expected output. A sibling "<name>.out" file is compared byte for byte,
//     and its absence means the output must be empty.
//   - Environment. GOOS, GOARCH, GOEXPERIMENT and GODEBUG are read from the
//     PINNED TOOLCHAIN via `go env -json`, as upstream reads them; the recipe's
//     -goexperiment/-godebug flags append to those, and $GO_TEST_TIMEOUT_SCALE
//     multiplies every -t timeout.
//
// SCOPE. This driver executes SEVEN of the pinned upstream runner's SEVENTEEN
// actions. The other ten — asmcheck, builddir, buildrun, buildrundir,
// errorcheckandrundir, errorcheckdir, errorcheckoutput, errorcheckwithauto,
// runindir and skip — are enumerated with their reasons in unsupportedActions,
// published in every run summary, and rejected by name if offered. It is a
// bounded tranche and says so in its machine-readable output; nothing here may
// be read as "upstream's runner is green".
//
// WHAT IS ASSERTED. Every compile, link and build step declares the artifact it
// must produce, and the claim is checked after the process exits: existence,
// regular file, correct kind (Go object archive / native executable / Go
// source), and non-empty. A toolchain that exits 0 and writes nothing fails.
//
// PROVENANCE, ALL MANDATORY. There is no unprovenanced mode:
//
//   - -inventory       digests every .go file read (docs/go-corpus/inventory.tsv).
//   - -aux-inventory   digests every .out sidecar and .dir manifest consumed,
//     including the sidecars upstream deliberately does NOT ship — "absent" is
//     an assertion, because no .out means the output must be empty.
//   - -toolchain       identifies the toolchain from pinned distribution
//     checksums and from the upstream sources in its own GOROOT. `go version` is
//     a string this package's own tests forge, so it is a diagnostic only.
//   - -semantics-sha256 pins the upstream runner this driver reimplements.
//
// EVIDENCE ON FAILURE. Every fatal path writes the run summary — verdict, reason
// and the executed/reported/pass/fail counts reached so far — and prints it as
// one JSON line, because a fatal run that leaves only prose is indistinguishable
// from one that never started.
package main
