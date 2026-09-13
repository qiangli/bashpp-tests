// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// One Go program for the Go by Example corpus tooling. It replaces the eleven
// Ruby files that used to live in tools/go-by-example/ (gate.rb, candidate.rb,
// inputs.rb, normalizer.rb, runtime-config.rb, validate-candidate.rb,
// validate-evidence.rb, validate-bounded-evidence.rb, summarize-evidence.rb,
// bounded-evidence-selftests.rb, tamper-retained-evidence.rb) and absorbs the
// tools/corpus/executor.rb primitives the gate required. The .sh wrappers keep
// their names and CLIs and exec this binary; build.sh compiles it with the
// pinned Go toolchain the same way the gate builds launch.go.
//
//	gbe gate --candidate MANIFEST --bashy LAUNCHER [--evidence PATH]
//	gbe validate
//	gbe refresh [--inventory-only] [GBE_ROOT]
//	gbe validate-candidate --candidate MANIFEST --bashy LAUNCHER
//	gbe validate-evidence EVIDENCE
//	gbe validate-bounded-evidence EVIDENCE INVENTORY
//	gbe summarize EVIDENCE_JSONL OUTPUT_DIRECTORY
//	gbe tamper-tests
//	gbe tamper-retained-evidence AUTHENTICATED_EVIDENCE
//	gbe bounded-evidence-selftests
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ROOT is the repository root: GBE_ROOT when the wrapper supplies it, else
// derived from the binary's own location. DOCS is the corpus table directory.
var (
	ROOT string
	DOCS string
)

func fatal(message string) {
	fmt.Fprintln(os.Stderr, "FATAL: "+message)
	os.Exit(1)
}

func resolveRoot() string {
	if env := os.Getenv("GBE_ROOT"); env != "" {
		root, err := realPath(env)
		if err != nil {
			fatal("GBE_ROOT is not a directory: " + env)
		}
		return root
	}
	exe, err := os.Executable()
	if err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		dir := filepath.Dir(exe)
		for i := 0; i < 8; i++ {
			if isRegularFile(filepath.Join(dir, "docs/go-by-example/pin.tsv")) && isDir(filepath.Join(dir, "tools/go-by-example")) {
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	fatal("cannot locate the repository root; set GBE_ROOT")
	return ""
}

func usage() {
	fmt.Fprintln(os.Stderr, strings.TrimSpace(`
usage: gbe <subcommand> [args]
  gate --candidate MANIFEST --bashy LAUNCHER [--evidence PATH]
  validate
  refresh [--inventory-only] [GBE_ROOT]
  validate-candidate --candidate MANIFEST --bashy LAUNCHER
  validate-evidence EVIDENCE
  validate-bounded-evidence EVIDENCE INVENTORY
  summarize EVIDENCE_JSONL OUTPUT_DIRECTORY
  tamper-tests
  tamper-retained-evidence AUTHENTICATED_EVIDENCE
  bounded-evidence-selftests`))
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	sub, args := os.Args[1], os.Args[2:]
	// The leak fixtures never touch the repository; resolve ROOT lazily for them.
	switch sub {
	case "leak-descendant":
		leakDescendantMain(args)
		return
	case "leak-survivor":
		leakSurvivorMain(args)
		return
	}
	ROOT = resolveRoot()
	DOCS = ROOT + "/docs/go-by-example"
	switch sub {
	case "gate":
		gateMain(args)
	case "validate":
		os.Exit(validateMain(args, os.Stdout))
	case "refresh":
		refreshMain(args)
	case "validate-candidate":
		validateCandidateMain(args)
	case "validate-evidence":
		validateEvidenceMain(args)
	case "validate-bounded-evidence":
		validateBoundedEvidenceMain(args)
	case "summarize":
		summarizeMain(args)
	case "tamper-tests":
		tamperTestsMain(args)
	case "tamper-retained-evidence":
		tamperRetainedMain(args)
	case "bounded-evidence-selftests":
		boundedSelftestsMain(args)
	default:
		usage()
	}
}
