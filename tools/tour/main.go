// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// `tour` — the single Go program behind every tools/tour/*.sh wrapper: the
// three-mode executor and its offline gate (tour-executor/v2), the superseded
// tour-evidence/v2 runner and validator, the comparator/gate/subprocess
// selftests, the tamper suites, the pinned normalizer and the inventory
// extractor. Built by the pinned Go toolchain (see tools/tour/tour-build.sh).
//
// Usage: tour <subcommand> [args]
//
//	executor                  produce tests/tour/executor-results.jsonl
//	validate-executor         offline gate over that ledger
//	executor-selftests        unit + end-to-end gate tests on a synthetic fixture
//	executor-tamper-tests     differential tamper probes against the real ledger
//	semantics-selftests       negative-first comparator tests
//	evidence                  produce tests/tour/evidence.jsonl (tour-evidence/v2)
//	validate-evidence         structural + replay validation of that ledger
//	evidence-selftests        real launch/deadline/process-tree probes
//	evidence-tamper-tests     synthetic-equality and provenance forgery probes
//	normalize [--version]     tour-normalizer/v1 on stdin
//	utf8-check FILE           strict UTF-8 gate
//	refresh-inventory ...     inventory extractor for tools/tour/refresh.sh
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

func repoRoot() string {
	if env := os.Getenv("TOUR_REPO_ROOT"); env != "" {
		abs, _ := filepath.Abs(env)
		return abs
	}
	exe, err := os.Executable()
	if err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		// The wrappers build into <repo>/.cache/tour/bin/tour.
		candidate := filepath.Clean(filepath.Join(filepath.Dir(exe), "../../.."))
		if fileExists(filepath.Join(candidate, "docs/tour/executor-contract.tsv")) {
			return candidate
		}
	}
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "../.."))
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: tour <executor|validate-executor|executor-selftests|executor-tamper-tests|semantics-selftests|evidence|validate-evidence|evidence-selftests|evidence-tamper-tests|normalize|utf8-check|refresh-inventory> [args]")
		os.Exit(2)
	}
	args := os.Args[2:]
	var code int
	switch os.Args[1] {
	case "normalize":
		code = cmdNormalize(args)
	case "utf8-check":
		code = cmdUTF8Check(args)
	case "semantics-selftests":
		code = cmdSemanticsSelftests(repoRoot())
	case "executor":
		code = cmdExecutor(repoRoot())
	case "validate-executor":
		code = cmdExecutorGate(repoRoot())
	case "executor-selftests":
		code = cmdExecutorSelftests(repoRoot())
	case "executor-tamper-tests":
		code = cmdExecutorTamperTests(repoRoot(), args)
	case "evidence":
		code = cmdEvidenceRunner(repoRoot())
	case "validate-evidence":
		code = cmdEvidenceValidator(repoRoot())
	case "evidence-selftests":
		code = cmdEvidenceSelftests(repoRoot())
	case "evidence-tamper-tests":
		code = cmdEvidenceTamperTests(repoRoot(), args)
	case "probe":
		code = cmdProbe(args)
	case "refresh-inventory":
		code = cmdRefreshInventory(args)
	default:
		fmt.Fprintf(os.Stderr, "tour: unknown subcommand %q\n", os.Args[1])
		code = 2
	}
	os.Exit(code)
}
