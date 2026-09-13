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

// bashppOverlay writes cmd/go's overlay before the replacement command starts.
// Its keys are the source files cmd/go selected; cmd/go consequently retains
// ownership of package identity and internal-import policy.
func bashppOverlay(name string, replace map[string]string) error {
	data, err := json.Marshal(struct {
		Replace map[string]string `json:"Replace"`
	}{Replace: replace})
	if err != nil {
		return err
	}
	return os.WriteFile(name, append(data, '\n'), 0o600)
}

func bashppOverlayProof(eventFile, pkg, overlay, trace, goTool string, originals, generated []string) string {
	lines := []string{
		"sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum \"$1\" | awk '{print $1}'; else shasum -a 256 \"$1\" | awk '{print $1}'; fi; }",
		"{",
		"printf '%s' " + bashppQuote(`{"schema":"`+bashppGoTestSchema+`","kind":"overlay-proof","package":"`+pkg+`","go_tool":"`+goTool+`","overlay":{"path":"`+overlay+`","sha256":"`),
		"sha256 " + bashppQuote(overlay),
		"printf '%s' " + bashppQuote(`"},"compile_trace":{"path":"`+trace+`","sha256":"`),
		"sha256 " + bashppQuote(trace),
		"printf '%s' " + bashppQuote(`"},"files":[`),
	}
	for i := range originals {
		if i != 0 {
			lines = append(lines, "printf ','")
		}
		lines = append(lines,
			"printf '%s' "+bashppQuote(`{"original":"`+originals[i]+`","generated":"`+generated[i]+`","sha256":"`),
			"sha256 "+bashppQuote(generated[i]),
			"printf '%s' "+bashppQuote(`"}`))
	}
	lines = append(lines,
		"printf '%s\\n' "+bashppQuote(`],"compiler_argv":["`+goTool+`","test","-overlay=`+overlay+`","`+pkg+`"]}`),
		"} >> "+bashppQuote(eventFile))
	return strings.Join(lines, "\n")
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
	var overlayOriginals []string
	var overlayImports []string
	var assemblyCompanions []string
	for _, imp := range pmain.Internal.Imports {
		if imp.ImportPath != p.ImportPath && imp.ImportPath != p.ImportPath+"_test" {
			continue
		}
		if len(imp.CgoFiles) != 0 || (mode != "compiled" && len(imp.SFiles) != 0) {
			record["disposition"] = "unsupported"
			record["deviations"] = []string{fmt.Sprintf("package %s has non-Go inputs %v; no direct Go-source meaning", imp.ImportPath, append(append([]string(nil), imp.SFiles...), imp.CgoFiles...))}
			bashppEmit(record)
			return []string{"/bin/sh", "-c", "echo 'Bash++ gotest backend: non-Go inputs' >&2; exit 1"}
		}
		assemblyCompanions = append(assemblyCompanions, imp.SFiles...)
		files := bashppFiles(imp)
		overlayOriginals = append(overlayOriginals, files...)
		for range files {
			overlayImports = append(overlayImports, imp.ImportPath)
		}
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
		goTool := os.Getenv("BASHPP_GOTEST_GO")
		overlayDir := filepath.Join(pmain.Dir, "bashpp-overlay")
		if err := os.MkdirAll(overlayDir, 0o700); err != nil {
			record["disposition"] = "configuration-error"
			record["deviations"] = append(deviations, "could not create overlay directory: "+err.Error())
			bashppEmit(record)
			return []string{"/bin/sh", "-c", "exit 1"}
		}
		overlay := filepath.Join(overlayDir, "overlay.json")
		trace := filepath.Join(overlayDir, "go-test-n.trace")
		replace := make(map[string]string, len(overlayOriginals))
		generated := make([]string, len(overlayOriginals))
		var lines []string
		for i, original := range overlayOriginals {
			generated[i] = filepath.Join(overlayDir, fmt.Sprintf("%03d.go", i))
			replace[original] = generated[i]
			transpile := []string{tool, "transpile", "--bashpp", "--source=go", "--go-import-path", overlayImports[i], "--go-file", original, "-o", generated[i], "--map", generated[i] + ".map"}
			words := make([]string, len(transpile))
			for j, w := range transpile {
				words[j] = bashppQuote(w)
			}
			lines = append(lines, strings.Join(words, " "))
		}
		if err := bashppOverlay(overlay, replace); err != nil {
			record["disposition"] = "configuration-error"
			record["deviations"] = append(deviations, "could not write cmd/go overlay: "+err.Error())
			bashppEmit(record)
			return []string{"/bin/sh", "-c", "exit 1"}
		}
		goTest := append([]string{"env", "-u", "BASHPP_GOTEST_BACKEND", goTool, "test", "-overlay=" + overlay, p.ImportPath}, testArgs...)
		words := make([]string, len(goTest))
		for j, word := range goTest {
			words[j] = bashppQuote(word)
		}
		dryRun := append([]string{"env", "-u", "BASHPP_GOTEST_BACKEND", goTool, "test", "-n", "-overlay=" + overlay, p.ImportPath}, testArgs...)
		dryWords := make([]string, len(dryRun))
		for j, word := range dryRun {
			dryWords[j] = bashppQuote(word)
		}
		lines = append(lines, strings.Join(dryWords, " ")+" > "+bashppQuote(trace))
		lines = append(lines, bashppOverlayProof(os.Getenv("BASHPP_GOTEST_EVENTS"), p.ImportPath, overlay, trace, goTool, overlayOriginals, generated))
		lines = append(lines, "exec "+strings.Join(words, " "))
		plan = []string{"/bin/sh", "-c", "set -e\n" + strings.Join(lines, "\n")}
		record["artifacts"] = generated
		record["overlay"] = overlay
		record["disposition"] = "transpile-overlay-go-test"
		deviations = append(deviations,
			"every GoFiles, TestGoFiles and XTestGoFiles source is transpiled as a library at its original import path and mapped by cmd/go -overlay",
			"cmd/go's original _testmain.go enumerates and runs the tests; cmd/go retains internal-import policy and assembles any .s companion natively")
		if len(assemblyCompanions) != 0 {
			deviations = append(deviations, "D3(b): cmd/go assembles the package's .s test companions natively under the overlay; they are an authority compiler-artifact step, never Bash++ tested-source execution")
		}
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
