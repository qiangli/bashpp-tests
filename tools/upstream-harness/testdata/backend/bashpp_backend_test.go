// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #157; Story: S157.2; Story-ID: 31520c72b5e0
// Sprint: #149; Stories: S149.1 (3f416ade73ef), S149.2 (1e87cb008ec3), S149.3 (60d35d1ec914)
// Sprint: #150; Story: S150.6 (4228ed646074)
//
// Direct Go-source backend for the authenticated Go 1.27 testdir seam. The
// only program description accepted here is the compileInputs/programArgv
// boundary selected by upstream and handed to planExec, plus the package
// identity (-D base, -p path) upstream chose for a directory package.
package testdir_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
	events.emit(t.eventName(), "backend", map[string]any{
		"package_map":    packageMap,
		"backend_schema": backendSchema,
		"mode":           mode,
		"action":         action,
		"compile_inputs": nonNil(compileInputs),
		"program_argv":   nonNil(programArgv),
		"recipe_flags":   nonNil(recipeFlags),
		"native_argv":    nonNil(nativeArgv),
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

// backendModule writes the temporary Go module that hosts transpiled source.
func backendModule(t test, shellrt string) (moduleDir string, err error) {
	moduleDir = t.TempDir()
	module := fmt.Sprintf("module bashpp_s1572\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.13.1\nreplace mvdan.cc/sh/v3 => %s\n", shellrt)
	if err := os.WriteFile(filepath.Join(moduleDir, "go.mod"), []byte(module), 0o600); err != nil {
		return "", fmt.Errorf("write Bash++ backend module: %w", err)
	}
	return moduleDir, nil
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
	if len(compileInputs) == 0 {
		step.backendErr = fmt.Errorf("Bash++ backend unsupported %s phase without Go source inputs", phase)
		t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			[]string{"upstream selected no language-source inputs; native tested-source execution is disabled in backend mode"})
		return
	}

	deviations := []string{
		"upstream native command argv is preserved as evidence and never used to classify the action",
		"the upstream run fast path is replaced by its existing source-execution plan so planExec receives language sources",
	}
	for _, input := range compileInputs {
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
	buildOnly := action == "build" && phase == "compile"
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

	fileArgs := goFileArgs(compileInputs)

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
		t.backendEvent(mode, action, phase, "check-then-run", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, runDeviations)

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
			t.backendEvent(mode, action, phase, "transpile-build-only", compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps,
				append(deviations,
					"upstream go-command recipe flags are passed verbatim to the pinned Go build of the generated module; they are never rewrapped as compile-tool or all= flags",
					"the upstream-selected environment, including any runenv GOEXPERIMENT, is preserved unchanged",
					"the a.exe artifact is written to the upstream working directory and is never executed"))
			return
		}
		if assembly {
			transpileArgs = append(transpileArgs, "--map", sourceMap)
			gcflags, buildFlags := asmBuildArgs(recipeFlags)
			buildArgs := []string{goTool, "build", "-C", moduleDir, "-gcflags=" + gcflags}
			buildArgs = append(buildArgs, buildFlags...)
			buildArgs = append(buildArgs, "-o", artifact, ".")
			*step.cmd = *shellCommand(step.cmd,
				append([]string{tool}, transpileArgs...),
				buildArgs)
			step.artifacts = []string{generated, artifact}
			step.maps = []string{sourceMap}
			t.backendEvent(mode, action, phase, "transpile-build-assembly", compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps,
				append(deviations,
					"the generated module is built with the upstream -S=2 listing request and the upstream asmcheck flag merge; its //line directives cite the exact upstream input path so upstream asmCheck indexes the listing unchanged",
					"the upstream-selected GOOS/GOARCH environment is preserved unchanged; the program is never executed"))
			return
		}
		if compileOnly || diagnostics || directory {
			// Upstream hands -p=<importpath> straight to `go tool compile`;
			// the pinned `go build` of the generated module owns -p itself,
			// so forwarding it through -gcflags relinks main into that
			// package. Retain it as evidence only. Errorcheck's -e/-d/-C
			// are compile-tool diagnostics flags with the same problem.
			var gcflags []string
			for _, flag := range recipeFlags {
				if !strings.HasPrefix(flag, "-p=") && !(diagnostics && (flag == "-e" || flag == "-C" || strings.HasPrefix(flag, "-d="))) {
					gcflags = append(gcflags, flag)
				}
			}
			transpileArgs = append(transpileArgs, "--map", sourceMap)
			buildArgs := []string{goTool, "build", "-C", moduleDir}
			if len(gcflags) != 0 {
				buildArgs = append(buildArgs, "-gcflags="+strings.Join(gcflags, " "))
			}
			buildArgs = append(buildArgs, "-o", artifact, ".")
			*step.cmd = *shellCommand(step.cmd,
				append([]string{tool}, transpileArgs...),
				buildArgs)
			step.artifacts = []string{generated, artifact}
			step.maps = []string{sourceMap}
			compileDeviations := append(deviations, "non-empty compiler flags use one unpatterned -gcflags=<space-joined exact flags>; generated program is never executed")
			if len(gcflags) != len(recipeFlags) {
				compileDeviations = append(compileDeviations, "upstream compile-tool flags (-p=<importpath>, and for errorcheck -e/-C/-d=) are retained as evidence only; the pinned go build owns them for the generated module")
			}
			disposition := "transpile-build-only"
			switch {
			case diagnostics:
				disposition = "transpile-build-diagnostics"
				compileDeviations = append(compileDeviations, "transpile and build diagnostics are emitted on the exact upstream input path via //line directives; upstream errorCheck applies its own expectations unchanged")
			case directory:
				disposition = "transpile-build-package-map"
				compileDeviations = append(compileDeviations, "the generated module receives no dependency packages; a lowered relative import that does not build is a retained lowering product failure")
			}
			t.backendEventMap(mode, action, phase, disposition, compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps, compileDeviations, packageMap)
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
		t.backendEvent(mode, action, phase, "transpile-build-run", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, runDeviations)

	default:
		step.backendErr = fmt.Errorf("unsupported Bash++ backend mode %q", mode)
		t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
	}
}
