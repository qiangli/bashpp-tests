// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #150; Story: S150.8; Story-ID: 65db485f62ab
//
// Direct Bash++ backend for Go's own package-test runner (cmd/go). The
// unmodified cmd/go enumerates the tests (load.TestPackagesFor generates
// _testmain.go from Go's own test metadata) and builds the native test
// binary; the one patched site in test.go asks this file, right before the
// test binary would be executed, for the Bash++ program that IS that test
// binary: the package under test with its in-package test files, the
// external test package if any, and the generated _testmain.go — handed to
// Bash++ as an explicit package map — with the exact test argv. The native
// test binary is never run while the backend is selected.
package test

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"cmd/go/internal/load"
	"cmd/go/internal/work"
)

const bashppGoTestSchema = "bashpp-tests/upstream-gotest-backend/v1"

var bashppEventMu sync.Mutex

func bashppEmit(record map[string]any) {
	path := os.Getenv("BASHPP_GOTEST_EVENTS")
	if path == "" {
		return
	}
	record["schema"] = bashppGoTestSchema
	line, err := json.Marshal(record)
	if err != nil {
		return
	}
	bashppEventMu.Lock()
	defer bashppEventMu.Unlock()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	f.Write(append(line, '\n'))
}

// bashppTestCount counts the tests, benchmarks, fuzz targets and examples in
// the _testmain.go cmd/go generated: Go's own enumeration, read back from
// Go's own artifact. It never looks at the tested sources.
func bashppTestCount(testmain string) (tests, benchmarks, fuzz, examples int, err error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, testmain, nil, 0)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.VAR {
			continue
		}
		for _, spec := range gen.Specs {
			value, ok := spec.(*ast.ValueSpec)
			if !ok || len(value.Names) != 1 || len(value.Values) != 1 {
				continue
			}
			lit, ok := value.Values[0].(*ast.CompositeLit)
			if !ok {
				continue
			}
			switch value.Names[0].Name {
			case "tests":
				tests = len(lit.Elts)
			case "benchmarks":
				benchmarks = len(lit.Elts)
			case "fuzzTargets":
				fuzz = len(lit.Elts)
			case "examples":
				examples = len(lit.Elts)
			}
		}
	}
	return tests, benchmarks, fuzz, examples, nil
}

func bashppFiles(p *load.Package) []string {
	files := make([]string, 0, len(p.GoFiles))
	for _, f := range p.GoFiles {
		files = append(files, filepath.Join(p.Dir, f))
	}
	return files
}

func bashppQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

// bashppTestPlan returns the argv that replaces the native test binary, or
// nil when the backend is not selected. args[0] is the built test binary
// (or an exec wrapper); args[1:] are the exact test flags cmd/go chose.
func bashppTestPlan(p *load.Package, buildAction *work.Action, args []string) []string {
	mode := os.Getenv("BASHPP_GOTEST_BACKEND")
	if mode == "" {
		return nil
	}
	tool := os.Getenv("BASHPP_GOTEST_TOOL")
	pmain := buildAction.Package
	testmain := filepath.Join(pmain.Dir, "_testmain.go")
	record := map[string]any{
		"kind":        "plan",
		"package":     p.ImportPath,
		"mode":        mode,
		"native_argv": append([]string(nil), args...),
		"testmain":    testmain,
		"tool":        map[string]any{"path": tool, "version": os.Getenv("BASHPP_GOTEST_VERSION")},
	}
	tests, benchmarks, fuzz, examples, err := bashppTestCount(testmain)
	if err != nil {
		record["disposition"] = "unsupported"
		record["deviations"] = []string{"cmd/go's generated _testmain.go could not be read: " + err.Error()}
		bashppEmit(record)
		return []string{"/bin/sh", "-c", "echo " + bashppQuote("Bash++ gotest backend: "+err.Error()) + " >&2; exit 1"}
	}
	record["enumeration"] = map[string]any{"tests": tests, "benchmarks": benchmarks, "fuzz_targets": fuzz, "examples": examples}

	// The program: every package pmain imports that cmd/go built for this
	// test — the package under test (with its in-package test files merged
	// by load.TestPackagesFor) and the external test package — in import
	// order, then _testmain.go as the main package.
	var mapArgs []string
	var packages []map[string]any
	for _, imp := range pmain.Internal.Imports {
		if imp.ImportPath != p.ImportPath && imp.ImportPath != p.ImportPath+"_test" {
			continue
		}
		if len(imp.SFiles) != 0 || len(imp.CgoFiles) != 0 {
			record["disposition"] = "unsupported"
			record["deviations"] = []string{fmt.Sprintf("package %s has non-Go inputs %v; no direct Go-source meaning", imp.ImportPath, append(append([]string(nil), imp.SFiles...), imp.CgoFiles...))}
			bashppEmit(record)
			return []string{"/bin/sh", "-c", "echo 'Bash++ gotest backend: non-Go inputs' >&2; exit 1"}
		}
		files := bashppFiles(imp)
		mapArgs = append(mapArgs, "--go-package", imp.ImportPath+"="+strings.Join(files, ","))
		packages = append(packages, map[string]any{"path": imp.ImportPath, "files": files})
	}
	record["program"] = map[string]any{"path": pmain.ImportPath, "packages": packages, "files": []string{testmain}}
	testArgs := args[1:]
	record["program_argv"] = testArgs
	deviations := []string{
		"cmd/go enumerated the tests and built the native test binary; the binary is never executed while the backend is selected",
		"the tested package, its in-package test files and the external test package are handed to Bash++ as an explicit package map with the generated _testmain.go as the main package",
	}
	var plan []string
	switch mode {
	case "interpreted":
		plan = append([]string{tool, "--bashpp", "--source=go", "--go-import-path", pmain.ImportPath}, mapArgs...)
		plan = append(plan, "--go-file", testmain)
		if len(testArgs) != 0 {
			plan = append(plan, "--")
			plan = append(plan, testArgs...)
		}
		record["disposition"] = "run-package-map"
	case "compiled":
		goTool, shellrt := os.Getenv("BASHPP_GOTEST_GO"), os.Getenv("BASHPP_SHELLRT_ROOT")
		moduleDir := filepath.Join(pmain.Dir, "bashpp")
		os.MkdirAll(moduleDir, 0o700)
		os.WriteFile(filepath.Join(moduleDir, "go.mod"), []byte(fmt.Sprintf("module bashpp_s1508\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.13.1\nreplace mvdan.cc/sh/v3 => %s\n", shellrt)), 0o600)
		generated, artifact := filepath.Join(moduleDir, "main.go"), filepath.Join(moduleDir, "program")
		transpile := append([]string{tool, "transpile", "--bashpp", "--source=go", "--go-import-path", pmain.ImportPath}, mapArgs...)
		transpile = append(transpile, "--go-file", testmain, "-o", generated, "--map", generated+".map")
		build := []string{goTool, "build", "-C", moduleDir, "-o", artifact, "."}
		run := append([]string{artifact}, testArgs...)
		var lines []string
		for i, command := range [][]string{transpile, build, run} {
			words := make([]string, len(command))
			for j, w := range command {
				words[j] = bashppQuote(w)
			}
			if i == 2 {
				words = append([]string{"exec"}, words...)
			}
			lines = append(lines, strings.Join(words, " "))
		}
		plan = []string{"/bin/sh", "-c", "set -e\n" + strings.Join(lines, "\n")}
		record["artifacts"] = []string{generated, artifact}
		record["disposition"] = "transpile-build-run-package-map"
		deviations = append(deviations, "generated source is built in a temporary module with a caller-supplied mvdan.cc/sh/v3 replacement")
	default:
		record["disposition"] = "configuration-error"
		bashppEmit(record)
		return []string{"/bin/sh", "-c", "echo 'Bash++ gotest backend: unknown mode' >&2; exit 1"}
	}
	record["argv"] = plan
	record["deviations"] = deviations
	bashppEmit(record)
	return plan
}
