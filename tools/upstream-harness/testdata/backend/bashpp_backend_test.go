// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #157; Story: S157.2; Story-ID: 31520c72b5e0
//
// Direct Go-source backend for the authenticated Go 1.27 testdir seam. The
// only program description accepted here is the compileInputs/programArgv
// boundary selected by upstream and handed to planExec.
package testdir_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	events.emit(t.eventName(), "backend", map[string]any{
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

func (t test) backendPlan(step *planStep, action, phase string, compileInputs, programArgv, recipeFlags []string) {
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
	compileOnly := action == "compile" && phase == "compile"
	buildOnly := action == "build" && phase == "compile"
	if phase != "execute" && !compileOnly && !buildOnly {
		step.backendErr = fmt.Errorf("Bash++ backend unsupported source phase %q", phase)
		t.backendEvent(mode, action, phase, "unsupported", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			append(deviations, "only upstream execute phases and action=compile phase=compile have a direct Bash++ meaning"))
		return
	}
	if tool == "" || os.Getenv("BASHPP_TESTDIR_VERSION") == "" {
		step.backendErr = fmt.Errorf("Bash++ backend requires an identified BASHPP_TESTDIR_TOOL")
		t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
		return
	}

	fileArgs := goFileArgs(compileInputs)
	switch mode {
	case "interpreted":
		checkArgs := append([]string{"--bashpp", "--source=go", "--check"}, fileArgs...)
		if compileOnly || buildOnly {
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
		*step.cmd = *shellCommand(step.cmd,
			append([]string{tool}, checkArgs...),
			append([]string{tool}, runArgs...))
		t.backendEvent(mode, action, phase, "check-then-run", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)

	case "compiled":
		goTool := os.Getenv("BASHPP_TESTDIR_GO")
		shellrt := os.Getenv("BASHPP_SHELLRT_ROOT")
		if goTool == "" || shellrt == "" {
			step.backendErr = fmt.Errorf("compiled Bash++ backend requires BASHPP_TESTDIR_GO and caller-supplied BASHPP_SHELLRT_ROOT")
			t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
			return
		}
		moduleDir := t.TempDir()
		generated := filepath.Join(moduleDir, "main.go")
		artifact := filepath.Join(moduleDir, "program")
		transpileArgs := append([]string{"transpile", "--bashpp", "--source=go"}, fileArgs...)
		transpileArgs = append(transpileArgs, "-o", generated)
		module := fmt.Sprintf("module bashpp_s1572\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.13.1\nreplace mvdan.cc/sh/v3 => %s\n", shellrt)
		if err := os.WriteFile(filepath.Join(moduleDir, "go.mod"), []byte(module), 0o600); err != nil {
			step.backendErr = fmt.Errorf("write Bash++ backend module: %w", err)
			t.backendEvent(mode, action, phase, "module-failed", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
			return
		}
		if buildOnly {
			sourceMap := filepath.Join(moduleDir, "main.go.map")
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
		if compileOnly {
			sourceMap := filepath.Join(moduleDir, "main.go.map")
			transpileArgs = append(transpileArgs, "--map", sourceMap)
			buildArgs := []string{goTool, "build", "-C", moduleDir}
			if len(recipeFlags) != 0 {
				buildArgs = append(buildArgs, "-gcflags="+strings.Join(recipeFlags, " "))
			}
			buildArgs = append(buildArgs, "-o", artifact, ".")
			*step.cmd = *shellCommand(step.cmd,
				append([]string{tool}, transpileArgs...),
				buildArgs)
			step.artifacts = []string{generated, artifact}
			step.maps = []string{sourceMap}
			t.backendEvent(mode, action, phase, "transpile-build-only", compileInputs, programArgv, recipeFlags, nativeArgv,
				step.artifacts, step.maps,
				append(deviations, "non-empty compiler flags use one unpatterned -gcflags=<space-joined exact flags>; generated program is never executed"))
			return
		}
		*step.cmd = *shellCommand(step.cmd,
			append([]string{tool}, transpileArgs...),
			[]string{goTool, "build", "-C", moduleDir, "-o", artifact, "."},
			append([]string{artifact}, programArgv...))
		t.backendEvent(mode, action, phase, "transpile-build-run", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil,
			append(deviations, "generated source is built in a temporary module with a caller-supplied mvdan.cc/sh/v3 replacement"))

	default:
		step.backendErr = fmt.Errorf("unsupported Bash++ backend mode %q", mode)
		t.backendEvent(mode, action, phase, "configuration-error", compileInputs, programArgv, recipeFlags, nativeArgv, nil, nil, deviations)
	}
}
