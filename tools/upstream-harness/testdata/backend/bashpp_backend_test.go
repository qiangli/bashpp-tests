// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #157; Story: S157.2; Story-ID: 31520c72b5e0
// Sprint: #149; Stories: S149.1 (3f416ade73ef), S149.2 (1e87cb008ec3), S149.3 (60d35d1ec914)
// Sprint: #150; Stories: S150.6 (4228ed646074), S150.5 (e87e1cbcbb20), S150.1 (a136a527c0b3), S150.2 (8f758b9dcd5a)
// Sprint: #154; Story: S154.0; Story-ID: 4877afd3a207
//
// Direct Go-source backend for the authenticated Go 1.27 testdir seam. The
// only program description accepted here is the compileInputs/programArgv
// boundary selected by upstream and handed to planExec, plus the package
// identity (-D base, -p path) upstream chose for a directory package.
package testdir_test

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

const backendSchema = "bashpp-tests/upstream-testdir-backend/v1"

func goFileArgs(inputs []string) []string {
	args := make([]string, 0, len(inputs)*2)
	for _, input := range inputs {
		args = append(args, "--go-file", input)
	}
	return args
}

func directSourceCommand(selected *exec.Cmd, name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.Dir = selected.Dir
	cmd.Env = append([]string(nil), selected.Env...)
	cmd.Stdin = selected.Stdin
	cmd.Stdout = selected.Stdout
	cmd.Stderr = selected.Stderr
	cmd.ExtraFiles = selected.ExtraFiles
	cmd.SysProcAttr = selected.SysProcAttr
	return cmd
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func shellCommand(selected *exec.Cmd, commands ...[]string) *exec.Cmd {
	lines := []string{"set -e"}
	for i, command := range commands {
		words := make([]string, len(command))
		for j, word := range command {
			words[j] = shellQuote(word)
		}
		if i == len(commands)-1 {
			words = append([]string{"exec"}, words...)
		}
		lines = append(lines, strings.Join(words, " "))
	}
	return directSourceCommand(selected, "/bin/sh", "-c", strings.Join(lines, "\n"))
}

func (t test) backendEvent(mode, action, phase, disposition string, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations []string) {
	t.backendEventMap(mode, action, phase, disposition, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations, nil)
}

// backendEventMap is backendEvent plus the structured package map handed to
// Bash++ for a directory package phase, so a verifier can check it without
// parsing prose.
func (t test) backendEventMap(mode, action, phase, disposition string, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations []string, packageMap map[string]any) {
	t.backendEventProgram(mode, action, phase, disposition, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations, packageMap, nil)
}

func (t test) backendEventCompiler(mode, action, phase, disposition string, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations []string, packageMap map[string]any, compilerArgv []string) {
	t.backendEventProgram(mode, action, phase, disposition, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations, packageMap, map[string]any{"compiler_argv": compilerArgv})
}

// backendEventProgram is backendEventMap plus the program record a later
// phase of the same upstream test acted on (S150.5): the files and package
// map earlier phases were handed and, in compiled mode, the artifact they
// built. A verifier can then check that link/execute acted on exactly what
// upstream compiled, without the seam ever looking for anything on disk.
func (t test) backendEventProgram(mode, action, phase, disposition string, compileInputs, programArgv, recipeFlags, nativeArgv, artifacts, maps, deviations []string, packageMap map[string]any, program map[string]any) {
	var compilerArgv []string
	if program != nil {
		compilerArgv, _ = program["compiler_argv"].([]string)
	}
	events.emit(t.eventName(), "backend", map[string]any{
		"program":        program,
		"package_map":    packageMap,
		"backend_schema": backendSchema,
		"mode":           mode,
		"action":         action,
		"compile_inputs": nonNil(compileInputs),
		"program_argv":   nonNil(programArgv),
		"recipe_flags":   nonNil(recipeFlags),
		"native_argv":    nonNil(nativeArgv),
		"compiler_argv":  nonNil(compilerArgv),
		"artifacts":      nonNil(artifacts),
		"maps":           nonNil(maps),
		"tool": map[string]any{
			"path":    os.Getenv("BASHPP_TESTDIR_TOOL"),
			"version": os.Getenv("BASHPP_TESTDIR_VERSION"),
		},
		"phase":       phase,
		"disposition": disposition,
		"deviations":  nonNil(deviations),
	})
}

// packageGroup is one directory package upstream has already planned for a
// test, in upstream order: the -p path it chose and the exact files.
type packageGroup struct {
	path  string
	files []string
}

// backendPackages remembers, per upstream test, the directory packages
// planned so far, so a later package's plan can hand every earlier one to
// Bash++ as an explicit --go-package entry — the in-memory equivalent of the
// importcfg upstream accumulates for the same test. Tests run in parallel;
// the key is the upstream test identity.
var backendPackages sync.Map

// backendProgram is what the phases of one upstream test have handed the
// seam so far as the program: the files (and package map) of the last
// compile phase and, in compiled mode, the artifact that phase built. A
// later `link` or input-less `execute` phase of the same test acts on it.
type backendProgram struct {
	files        []string
	mapArgs      []string
	artifact     string
	compilerArgv []string
}

// backendPrograms is keyed by the upstream test identity, like backendPackages.
var backendPrograms sync.Map

func (p backendProgram) record() map[string]any {
	return map[string]any{"files": nonNil(p.files), "map_args": nonNil(p.mapArgs), "artifact": p.artifact, "compiler_argv": nonNil(p.compilerArgv)}
}

// directCompileCommand is the upstream compiler invocation with the original
// Go inputs replaced by the one generated Go file.  In particular it retains
// upstream's -p and -importcfg resolution rather than asking cmd/go to invent
// a package build (and its implicit -complete).
func directCompileCommand(nativeArgv, compileInputs []string, generated string) ([]string, error) {
	if len(nativeArgv) < 4 || nativeArgv[1] != "tool" || nativeArgv[2] != "compile" {
		return nil, fmt.Errorf("upstream compile argv is not a go tool compile invocation: %v", nativeArgv)
	}
	inputs := make(map[string]bool, len(compileInputs))
	for _, input := range compileInputs {
		inputs[input] = true
	}
	args := make([]string, 0, len(nativeArgv)-len(compileInputs)+1)
	args = append(args, nativeArgv[0])
	for _, arg := range nativeArgv[1:] {
		if !inputs[arg] {
			args = append(args, arg)
		}
	}
	return append(args, generated), nil
}

func compilerOutput(argv []string, generated, dir string) string {
	for i, arg := range argv {
		if arg == "-o" && i+1 < len(argv) {
			if filepath.IsAbs(argv[i+1]) {
				return argv[i+1]
			}
			return filepath.Join(dir, argv[i+1])
		}
		if strings.HasPrefix(arg, "-o=") {
			name := strings.TrimPrefix(arg, "-o=")
			if filepath.IsAbs(name) {
				return name
			}
			return filepath.Join(dir, name)
		}
	}
	return strings.TrimSuffix(generated, ".go") + ".o"
}

// backendModule writes the temporary Go module that hosts transpiled source.
func backendModule(t test, shellrt string) (moduleDir string, err error) {
	moduleDir = t.TempDir()
	module := fmt.Sprintf("module bashpp_s1572\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.13.1\nreplace mvdan.cc/sh/v3 => %s\n", shellrt)
	if err := os.WriteFile(filepath.Join(moduleDir, "go.mod"), []byte(module), 0o600); err != nil {
		return "", fmt.Errorf("write Bash++ backend module: %w", err)
	}
	return moduleDir, nil
}

// backendLink gives upstream's link phase a meaning (S150.1). Upstream hands
// it the object name of the last package it compiled (its own .go -> .o
// rewrite) plus any -ldflags; the seam checks that object is the program its
// last directory compile phase handed it and adopts that program: nothing to
// link in interpreted mode (the sources run later), the artifact the pinned
// build already linked in compiled mode. Anything else is unsupported.
func (t test) backendLink(step *planStep, mode, action string, compileInputs, programArgv, recipeFlags, nativeArgv, deviations []string) {
	value, ok := backendPrograms.Load(t.eventName())
	program, _ := value.(backendProgram)
	object := ""
	if len(compileInputs) == 1 {
		object = strings.TrimSuffix(filepath.Base(compileInputs[0]), ".o") + ".go"
	}
	if !ok || len(program.files) == 0 || object != filepath.Base(program.files[0]) {
		step.backendErr = fmt.Errorf("Bash++ backend unsupported link phase: input %v is not the program this test's compile phases handed the seam", compileInputs)
		t.backendEvent(mode, action, "link", "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			append(deviations, "the link input is not the object of the last directory package upstream compiled through Bash++"))
		return
	}
	deviations = append(deviations,
		"the link input is upstream's object name for the last package it compiled; the seam adopts the program that compile phase handed it and never links objects",
		"upstream -ldflags are retained as evidence only")
	switch mode {
	case "interpreted":
		*step.cmd = *directSourceCommand(step.cmd, "/bin/sh", "-c", ":")
		t.backendEventProgram(mode, action, "link", "link-adopt-check", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			append(deviations, "an interpreter has nothing to link: the checked sources are the program and run at the execute phase"), nil, program.record())
	case "compiled":
		if program.artifact == "" {
			step.backendErr = fmt.Errorf("Bash++ backend unsupported link phase: no artifact was built for this program")
			t.backendEvent(mode, action, "link", "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
			return
		}
		linkArgv := append([]string(nil), nativeArgv...)
		for i, arg := range linkArgv {
			if strings.HasSuffix(arg, ".o") {
				linkArgv[i] = program.artifact
			}
		}
		linked := compilerOutput(linkArgv, "", step.cmd.Dir)
		program.artifact = linked
		backendPrograms.Store(t.eventName(), program)
		*step.cmd = *directSourceCommand(step.cmd, linkArgv[0], linkArgv[1:]...)
		t.backendEventProgram(mode, action, "link", "link-adopt-artifact", compileInputs, programArgv, recipeFlags, nativeArgv, []string{linked}, nil,
			append(deviations, "the pinned Go linker receives the object produced by the generated source; upstream link flags and importcfg are retained exactly"), nil, program.record())
	default:
		step.backendErr = fmt.Errorf("unsupported Bash++ backend mode %q", mode)
		t.backendEvent(mode, action, "link", "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
	}
}

// goListPackage is the subset of `go list -json` the seam reads.
type goListPackage struct {
	ImportPath string
	Name       string
	Dir        string
	GoFiles    []string
	SFiles     []string
	CgoFiles   []string
	Standard   bool
	Module     *struct {
		Path string
		Main bool
	}
}

// resolveModuleProgram asks the pinned go command what "." is in dir: the main
// package's Go files (absolute) and every in-module dependency as an ordered
// --go-package entry (go list -deps emits dependencies before dependents).
// A package with assembly or cgo files has no direct Go-source meaning.
func resolveModuleProgram(goTool, dir string, env []string) (files, mapArgs []string, record map[string]any, err error) {
	if goTool == "" {
		return nil, nil, nil, fmt.Errorf("resolving a module program requires BASHPP_TESTDIR_GO")
	}
	cmd := exec.Command(goTool, "list", "-json", "-deps", ".")
	cmd.Dir, cmd.Env = dir, env
	out, err := cmd.Output()
	record = map[string]any{"go_list": append([]string{goTool}, cmd.Args[1:]...), "dir": dir}
	if err != nil {
		return nil, nil, record, fmt.Errorf("go list -json -deps . failed in %s: %v", dir, err)
	}
	dec := json.NewDecoder(strings.NewReader(string(out)))
	var packages []map[string]any
	var main *goListPackage
	for {
		var pkg goListPackage
		if err := dec.Decode(&pkg); err != nil {
			break
		}
		if pkg.Standard || pkg.Module == nil || !pkg.Module.Main {
			continue
		}
		if len(pkg.SFiles) != 0 || len(pkg.CgoFiles) != 0 {
			return nil, nil, record, fmt.Errorf("module package %s has non-Go inputs %v", pkg.ImportPath, append(pkg.SFiles, pkg.CgoFiles...))
		}
		abs := make([]string, 0, len(pkg.GoFiles))
		for _, f := range pkg.GoFiles {
			abs = append(abs, filepath.Join(pkg.Dir, f))
		}
		if pkg.Name == "main" && pkg.Dir == dir {
			p := pkg
			main = &p
			files = abs
			continue
		}
		mapArgs = append(mapArgs, "--go-package", pkg.ImportPath+"="+strings.Join(abs, ","))
		packages = append(packages, map[string]any{"path": pkg.ImportPath, "files": abs})
	}
	if main == nil || len(files) == 0 {
		return nil, nil, record, fmt.Errorf("go list found no main package in %s", dir)
	}
	if len(packages) != 0 {
		mapArgs = append([]string{"--go-import-path", main.ImportPath}, mapArgs...)
	}
	record["base"] = ""
	record["path"] = main.ImportPath
	record["packages"] = packages
	return files, mapArgs, record, nil
}

// artifactUse states what happens to the cwd a.exe a build-only phase writes:
// nothing for `build`; for `buildrun` only this test's later execute phase
// runs it (S150.5).
func artifactUse(action string) string {
	if action == "buildrun" {
		return "the a.exe artifact is written to the upstream working directory and is executed only by this test's later execute phase"
	}
	return "the a.exe artifact is written to the upstream working directory and is never executed"
}

// optimizerDiagnosticFlags reports whether an errorcheck recipe asks the
// compiler for optimizer diagnostics: -m (any -m… form), -live, or a
// -d= debug flag. The check interface has no inlining, escape analysis or
// SSA, so interpreted mode declares such a recipe unsupported, the same shape
// as interpreted asmcheck.
func optimizerDiagnosticFlags(flags []string) bool {
	for _, flag := range flags {
		if strings.HasPrefix(flag, "-m") || strings.HasPrefix(flag, "-live") || debugDiagnosticFlag(flag) {
			return true
		}
	}
	return false
}

// debugDiagnosticFlag mirrors partition-emit.go: a -d= flag whose output the
// expectations depend on. -d=ssa/check/on (appended by upstream to every
// errorcheck compile) and -d=panic (gc panics on its first ordinary error)
// carry no expectation and never make a recipe an optimizer-diagnostic one.
func debugDiagnosticFlag(flag string) bool {
	if !strings.HasPrefix(flag, "-d=") {
		return false
	}
	for _, option := range strings.Split(strings.TrimPrefix(flag, "-d="), ",") {
		switch option {
		case "", "ssa/check/on", "panic":
			continue
		}
		return true
	}
	return false
}

// asmBuildArgs mirrors the upstream asmcheck flag merge: -gcflags values are
// folded into the single -S=2 argument; every other flag is a go build flag.
func asmBuildArgs(recipeFlags []string) (gcflags string, buildFlags []string) {
	gcflags = "-S=2"
	for i := 0; i < len(recipeFlags); i++ {
		flag := recipeFlags[i]
		switch {
		case strings.HasPrefix(flag, "-gcflags="):
			gcflags += " " + strings.TrimPrefix(flag, "-gcflags=")
		case strings.HasPrefix(flag, "--gcflags="):
			gcflags += " " + strings.TrimPrefix(flag, "--gcflags=")
		case flag == "-gcflags", flag == "--gcflags":
			i++
			if i < len(recipeFlags) {
				gcflags += " " + recipeFlags[i]
			}
		default:
			buildFlags = append(buildFlags, flag)
		}
	}
	return gcflags, buildFlags
}

func (t test) backendPlan(step *planStep, action, phase string, pkg *packageIdentity, compileInputs, programArgv, recipeFlags []string) {
	mode := os.Getenv("BASHPP_TESTDIR_BACKEND")
	tool := os.Getenv("BASHPP_TESTDIR_TOOL")
	nativeArgv := append([]string(nil), step.cmd.Args...)
	if mode == "" {
		return
	}
	// Upstream bounds a command only when the recipe says `-t N`; every other
	// phase is unbounded, which is right for the native compiler and wrong
	// for a product under test that can hang. The backend lane applies the
	// Sprint 148 60-second per-stage deadline (BASHPP_TESTDIR_DEADLINE
	// overrides) through upstream's own timer, so a timed-out root is
	// upstream's errTimeout — a product row, never a seam error.
	step.deadline = 60
	if v := os.Getenv("BASHPP_TESTDIR_DEADLINE"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			step.deadline = n
		}
	}
	if len(compileInputs) == 0 {
		// An execute phase with no inputs runs the program an earlier phase
		// of this same test built (buildrun's `./a.exe`, rundir's linked
		// a.exe): the seam remembers what upstream handed it, never looks.
		if value, ok := backendPrograms.Load(t.eventName()); ok && phase == "execute" && tool != "" {
			program := value.(backendProgram)
			deviations := []string{
				"upstream native command argv is preserved as evidence and never used to classify the action",
				"the execute phase carries no compile inputs; the program is the one this test's earlier compile phase handed the seam",
			}
			switch mode {
			case "interpreted":
				runArgs := append([]string{"--bashpp", "--source=go"}, program.mapArgs...)
				runArgs = append(runArgs, goFileArgs(program.files)...)
				if len(programArgv) != 0 {
					runArgs = append(runArgs, "--")
					runArgs = append(runArgs, programArgv...)
				}
				*step.cmd = *directSourceCommand(step.cmd, tool, runArgs...)
				t.backendEventProgram(mode, action, phase, "run-remembered-program", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
					append(deviations, "the remembered sources run directly through the Bash++ interpreter with only the upstream program argv; no artifact exists in interpreted mode"), nil, program.record())
				return
			case "compiled":
				if program.artifact == "" {
					break
				}
				*step.cmd = *directSourceCommand(step.cmd, program.artifact, programArgv...)
				t.backendEventProgram(mode, action, phase, "run-artifact", compileInputs, programArgv, recipeFlags, nativeArgv, []string{program.artifact}, nil,
					append(deviations, "the artifact the earlier compile phase built from the transpiled sources runs with only the upstream program argv"), nil, program.record())
				return
			}
		}
		step.backendErr = fmt.Errorf("Bash++ backend unsupported %s phase without Go source inputs", phase)
		t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			[]string{"upstream selected no language-source inputs and no earlier phase of this test handed the seam a program; native tested-source execution is disabled in backend mode"})
		return
	}

	deviations := []string{
		"upstream native command argv is preserved as evidence and never used to classify the action",
		"the upstream run fast path is replaced by its existing source-execution plan so planExec receives language sources",
	}
	if phase == "link" {
		t.backendLink(step, mode, action, compileInputs, programArgv, recipeFlags, nativeArgv, deviations)
		return
	}
	// runindir: upstream built a module (overlay copy + go.mod) and runs `go run
	// .` in it. "." means whatever the go command's own on-disk policy says in
	// that exact directory; the seam asks the pinned go once and hands the
	// answer to Bash++ as files plus an explicit package map. It never walks
	// the directory itself.
	// sourceFiles is what Bash++ is handed as --go-file inputs; it equals
	// upstream's compileInputs except for runindir's ".", which the go
	// command resolves. The backend event always records upstream's inputs.
	sourceFiles := compileInputs
	var moduleMapArgs []string
	var moduleMap map[string]any
	if len(compileInputs) == 1 && compileInputs[0] == "." && phase == "execute" {
		goTool := os.Getenv("BASHPP_TESTDIR_GO")
		resolved, mapArgs, record, err := resolveModuleProgram(goTool, step.cmd.Dir, step.cmd.Env)
		if err != nil {
			step.backendErr = fmt.Errorf("Bash++ backend unsupported execute phase: %v", err)
			t.backendEventMap(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
				append(deviations, "the module program upstream prepared has no direct Go-source meaning: "+err.Error()), record)
			return
		}
		deviations = append(deviations, "the \".\" input is resolved once by the pinned go command's own module policy (`go list -json -deps .` in the upstream-prepared module directory, with the upstream environment) into the main package's Go files and the in-module dependency packages, in dependency order; the seam walks no directory")
		sourceFiles, moduleMapArgs, moduleMap = resolved, mapArgs, record
		record["files"] = nonNil(resolved)
	}
	for _, input := range sourceFiles {
		if !strings.HasSuffix(input, ".go") {
			step.backendErr = fmt.Errorf("Bash++ backend unsupported %s phase: compile input %q is not a Go source file", phase, input)
			t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
				append(deviations, "non-Go compile input has no direct Go-source meaning"))
			return
		}
	}
	// An upstream "generate" phase is a `go run` of the selected source whose
	// output becomes the next phase's input (runoutput, errorcheckoutput);
	// it has exactly the execute phase's direct meaning.
	run := phase == "execute" || phase == "generate"
	compileOnly := action == "compile" && phase == "compile"
	buildOnly := (action == "build" || action == "buildrun") && phase == "compile"
	diagnostics := phase == "compile" && pkg == nil &&
		(action == "errorcheck" || action == "errorcheckoutput" || action == "errorcheckwithauto")
	directory := phase == "compile" && pkg != nil
	assembly := action == "asmcheck" && phase == "compile"
	if !run && !compileOnly && !buildOnly && !diagnostics && !directory && !assembly {
		step.backendErr = fmt.Errorf("Bash++ backend unsupported source phase %q", phase)
		t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			append(deviations, "only upstream execute/generate phases and the compile phases of compile, build, errorcheck, directory and asmcheck actions have a direct Bash++ meaning"))
		return
	}
	if tool == "" || os.Getenv("BASHPP_TESTDIR_VERSION") == "" {
		step.backendErr = fmt.Errorf("Bash++ backend requires an identified BASHPP_TESTDIR_TOOL")
		t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
		return
	}

	fileArgs := goFileArgs(sourceFiles)
	if moduleMap != nil {
		fileArgs = append(append([]string(nil), moduleMapArgs...), fileArgs...)
	}

	// Directory packages: every earlier package of this same upstream test is
	// an explicit --go-package entry; the current package carries upstream's
	// own -D base and -p path. Nothing is discovered on disk.
	var mapArgs []string
	var packageMap map[string]any
	if directory {
		key := t.eventName()
		var earlier []packageGroup
		if value, ok := backendPackages.Load(key); ok {
			earlier = value.([]packageGroup)
		}
		mapArgs = []string{"--go-import-base", pkg.Base, "--go-import-path", pkg.Path}
		for _, group := range earlier {
			mapArgs = append(mapArgs, "--go-package", group.path+"="+strings.Join(group.files, ","))
		}
		backendPackages.Store(key, append(append([]packageGroup(nil), earlier...), packageGroup{path: pkg.Path, files: append([]string(nil), compileInputs...)}))
		packages := make([]map[string]any, 0, len(earlier))
		for _, group := range earlier {
			packages = append(packages, map[string]any{"path": group.path, "files": nonNil(group.files)})
		}
		packageMap = map[string]any{"base": pkg.Base, "path": pkg.Path, "packages": packages}
		// The last directory package upstream compiles is the program a later
		// link/execute phase of this test acts on (rundir, errorcheckandrundir).
		// A single-package program needs no map; a multi-package one carries
		// upstream's identity and every earlier group.
		program := backendProgram{files: append([]string(nil), compileInputs...)}
		if len(earlier) != 0 {
			program.mapArgs = append([]string(nil), mapArgs...)
		}
		backendPrograms.Store(key, program)
		deviations = append(deviations,
			fmt.Sprintf("upstream package identity -D %s -p %s and the %d earlier package(s) of this test are handed to Bash++ as an explicit package map; relative imports are never resolved on disk", pkg.Base, pkg.Path, len(earlier)))
	}

	switch mode {
	case "interpreted":
		checkArgs := append([]string{"--bashpp", "--source=go", "--check"}, mapArgs...)
		checkArgs = append(checkArgs, fileArgs...)
		switch {
		case assembly:
			step.backendErr = fmt.Errorf("Bash++ backend unsupported: assembly is a compiler artifact; interpreted mode has no asmcheck meaning")
			t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
				append(deviations, "asmcheck compares generated assembly; only compiled mode produces one"))
			return
		case diagnostics:
			if optimizerDiagnosticFlags(recipeFlags) {
				step.backendErr = fmt.Errorf("Bash++ backend unsupported: optimizer diagnostics are a compiler artifact; the check interface has no inlining, escape-analysis or SSA meaning")
				t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
					append(deviations, "optimizer diagnostics are a compiler artifact; the check interface has no inlining, escape-analysis or SSA meaning"))
				return
			}
			*step.cmd = *directSourceCommand(step.cmd, tool, checkArgs...)
			t.backendEvent(mode, action, phase, "check-diagnostics", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
				append(deviations,
					"the Bash++ check interface reports every diagnostic as file:line:col: message on the exact upstream input path; upstream errorCheck applies its own expectations unchanged",
					"compiler recipe flags (-e, -d=panic, -C, -p) have no check-interface representation and remain explicit evidence; nothing is executed"))
			return
		case directory:
			*step.cmd = *directSourceCommand(step.cmd, tool, checkArgs...)
			t.backendEventMap(mode, action, phase, "check-package-map", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
				append(deviations, "directory package phase stops after Bash++ check against the explicit package map; no init or main is executed"), packageMap)
			return
		case compileOnly || buildOnly:
			*step.cmd = *directSourceCommand(step.cmd, tool, checkArgs...)
			checkDeviations := append(append([]string(nil), deviations...),
				"the Bash++ check interface does not accept compiler recipe flags; they remain explicit evidence",
				"compile-only phase stops after Bash++ check; no init or main is executed")
			if buildOnly {
				checkDeviations = append(append([]string(nil), deviations...),
					"the Bash++ check interface has no compiler or artifact semantics; upstream go-command recipe flags and the cwd a.exe artifact remain explicit evidence only",
					"build-only phase stops after Bash++ check; no artifact is produced and no init or main is executed")
				backendPrograms.Store(t.eventName(), backendProgram{files: append([]string(nil), compileInputs...)})
			}
			t.backendEvent(mode, action, phase, "check-only", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, checkDeviations)
			return
		}
		runArgs := append([]string{"--bashpp", "--source=go"}, fileArgs...)
		if len(programArgv) != 0 {
			runArgs = append(runArgs, "--")
			runArgs = append(runArgs, programArgv...)
		}
		runDeviations := deviations
		if len(recipeFlags) != 0 {
			runDeviations = append(append([]string(nil), deviations...),
				"upstream go-command recipe flags have no representation in the direct Go-source interpreter and remain explicit evidence only")
		}
		*step.cmd = *shellCommand(step.cmd,
			append([]string{tool}, checkArgs...),
			append([]string{tool}, runArgs...))
		t.backendEventMap(mode, action, phase, "check-then-run", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, runDeviations, moduleMap)

	case "compiled":
		goTool := os.Getenv("BASHPP_TESTDIR_GO")
		shellrt := os.Getenv("BASHPP_SHELLRT_ROOT")
		if goTool == "" || shellrt == "" {
			step.backendErr = fmt.Errorf("compiled Bash++ backend requires BASHPP_TESTDIR_GO and caller-supplied BASHPP_SHELLRT_ROOT")
			t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
			return
		}
		moduleDir, err := backendModule(t, shellrt)
		if err != nil {
			step.backendErr = err
			t.backendEvent(mode, action, phase, "module-failed", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
			return
		}
		generated := filepath.Join(moduleDir, "main.go")
		artifact := filepath.Join(moduleDir, "program")
		sourceMap := filepath.Join(moduleDir, "main.go.map")
		transpileArgs := append([]string{"transpile", "--bashpp", "--source=go"}, mapArgs...)
		transpileArgs = append(transpileArgs, fileArgs...)
		transpileArgs = append(transpileArgs, "-o", generated)
		if buildOnly {
			transpileArgs = append(transpileArgs, "--map", sourceMap)
			built := filepath.Join(step.cmd.Dir, "a.exe")
			buildArgs := []string{goTool, "build", "-C", moduleDir}
			buildArgs = append(buildArgs, recipeFlags...)
			buildArgs = append(buildArgs, "-o", built, ".")
			*step.cmd = *shellCommand(step.cmd,
				append([]string{tool}, transpileArgs...),
				buildArgs)
			step.artifacts = []string{generated, built}
			step.maps = []string{sourceMap}
			backendPrograms.Store(t.eventName(), backendProgram{files: append([]string(nil), compileInputs...), artifact: built})
			t.backendEvent(mode, action, phase, "transpile-build-only", compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps,
				append(deviations,
					"upstream go-command recipe flags are passed verbatim to the pinned Go build of the generated module; they are never rewrapped as compile-tool or all= flags",
					"the upstream-selected environment, including any runenv GOEXPERIMENT, is preserved unchanged",
					artifactUse(action)))
			return
		}
		if assembly {
			transpileArgs = append(transpileArgs, "--map", sourceMap)
			gcflags, buildFlags := asmBuildArgs(recipeFlags)
			buildArgs := []string{goTool, "build", "-C", moduleDir, "-gcflags=" + gcflags}
			buildArgs = append(buildArgs, buildFlags...)
			buildArgs = append(buildArgs, "-o", artifact, filepath.Base(generated))
			listing := filepath.Join(moduleDir, "asm-listing.txt")
			transpileCommand := append([]string{tool}, transpileArgs...)
			quotedTranspile := make([]string, len(transpileCommand))
			for i, word := range transpileCommand {
				quotedTranspile[i] = shellQuote(word)
			}
			quotedBuild := make([]string, len(buildArgs))
			for i, word := range buildArgs {
				quotedBuild[i] = shellQuote(word)
			}
			asmScript := strings.Join([]string{
				"set -e",
				strings.Join(quotedTranspile, " "),
				"set +e",
				strings.Join(quotedBuild, " ") + " > " + shellQuote(listing) + " 2>&1",
				"rc=$?",
				"sed -E 's/(\\.go:[0-9]+)\\[[^]]*\\]\\)/\\1)/' " + shellQuote(listing),
				"exit \"$rc\"",
			}, "\n")
			*step.cmd = *directSourceCommand(step.cmd, "/bin/sh", "-c", asmScript)
			step.artifacts = []string{generated, artifact, listing}
			step.maps = []string{sourceMap}
			t.backendEvent(mode, action, phase, "transpile-build-assembly", compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps,
				append(deviations,
					"the generated module is built with the upstream -S=2 listing request and the upstream asmcheck flag merge; its //line directives cite the exact upstream input path",
					"the generated file is compiled as a file argument, so its symbols are qualified as command-line-arguments like upstream's compilation of the original",
					"the -S listing's physical-position suffix (origin:line[generated:line]) is removed before upstream asmCheck indexes it, so the unchanged matcher keys generated code by origin file:line; the raw listing is retained as an artifact",
					"the upstream-selected GOOS/GOARCH environment is preserved unchanged; the program is never executed"))
			return
		}
		if compileOnly || diagnostics || directory {
			transpileArgs = append(transpileArgs, "--map", sourceMap)
			compilerArgv, err := directCompileCommand(nativeArgv, compileInputs, generated)
			if err != nil {
				step.backendErr = err
				t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
				return
			}
			artifact = compilerOutput(compilerArgv, generated, step.cmd.Dir)
			*step.cmd = *shellCommand(step.cmd,
				append([]string{tool}, transpileArgs...),
				compilerArgv)
			step.artifacts = []string{generated, artifact}
			step.maps = []string{sourceMap}
			compileDeviations := append(deviations,
				"the pinned compiler is invoked directly on the generated Go file with upstream's exact compile flags, -p resolution, and importcfg; cmd/go is not involved and cannot add -complete",
				"the backend event records compiler_argv, the exact executed compiler command with only the source input replaced by the generated file")
			disposition := "transpile-compile-only"
			switch {
			case diagnostics:
				disposition = "transpile-compile-diagnostics"
				compileDeviations = append(compileDeviations, "transpile and compiler diagnostics are emitted on the exact upstream input path via //line directives; upstream errorCheck applies its own expectations unchanged")
			case directory:
				disposition = "transpile-compile-package-map"
				compileDeviations = append(compileDeviations, "the direct compiler reuses upstream's directory importcfg, including the object paths produced by earlier generated package phases")
				if value, ok := backendPrograms.Load(t.eventName()); ok {
					program := value.(backendProgram)
					program.artifact = artifact
					program.compilerArgv = append([]string(nil), compilerArgv...)
					backendPrograms.Store(t.eventName(), program)
				}
			}
			t.backendEventCompiler(mode, action, phase, disposition, compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps, compileDeviations, packageMap, compilerArgv)
			return
		}
		// An ordinary run root with recipe flags reaches this path through
		// upstream's `go run <flags> <file>` branch; the flags are go-command
		// flags and are passed verbatim to the pinned build of the generated
		// module, exactly as the build action does (never rewrapped).
		buildArgs := []string{goTool, "build", "-C", moduleDir}
		buildArgs = append(buildArgs, recipeFlags...)
		buildArgs = append(buildArgs, "-o", artifact, ".")
		runDeviations := append(deviations, "generated source is built in a temporary module with a caller-supplied mvdan.cc/sh/v3 replacement")
		if len(recipeFlags) != 0 {
			runDeviations = append(runDeviations, "upstream go-command recipe flags are passed verbatim to the pinned Go build of the generated module; they are never rewrapped as compile-tool or all= flags")
		}
		*step.cmd = *shellCommand(step.cmd,
			append([]string{tool}, transpileArgs...),
			buildArgs,
			append([]string{artifact}, programArgv...))
		t.backendEventMap(mode, action, phase, "transpile-build-run", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, runDeviations, moduleMap)

	default:
		step.backendErr = fmt.Errorf("unsupported Bash++ backend mode %q", mode)
		t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
	}
}
