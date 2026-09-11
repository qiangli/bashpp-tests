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

func (t test) backendEvent(mode, phase, disposition string, compileInputs, programArgv, deviations []string) {
	events.emit(t.eventName(), "backend", map[string]any{
		"backend_schema": backendSchema,
		"mode":           mode,
		"compile_inputs": nonNil(compileInputs),
		"program_argv":   nonNil(programArgv),
		"tool": map[string]any{
			"path":    os.Getenv("BASHPP_TESTDIR_TOOL"),
			"version": os.Getenv("BASHPP_TESTDIR_VERSION"),
		},
		"phase":       phase,
		"disposition": disposition,
		"deviations":  nonNil(deviations),
	})
}

func (t test) backendPlan(step *planStep, phase string, compileInputs, programArgv []string) {
	mode := os.Getenv("BASHPP_TESTDIR_BACKEND")
	tool := os.Getenv("BASHPP_TESTDIR_TOOL")
	if mode == "" {
		return
	}
	if len(compileInputs) == 0 {
		step.backendErr = fmt.Errorf("Bash++ backend unsupported %s phase without Go source inputs", phase)
		t.backendEvent(mode, phase, "unsupported", compileInputs, programArgv,
			[]string{"upstream selected no language-source inputs; native tested-source execution is disabled in backend mode"})
		return
	}

	deviations := []string{
		"native Go tool flags are intentionally not represented by the direct Go-source interface",
		"the upstream run fast path is replaced by its existing source-execution plan so planExec receives language sources",
	}
	for _, input := range compileInputs {
		if !strings.HasSuffix(input, ".go") {
			step.backendErr = fmt.Errorf("Bash++ backend unsupported %s phase: compile input %q is not a Go source file", phase, input)
			t.backendEvent(mode, phase, "unsupported", compileInputs, programArgv,
				append(deviations, "non-Go compile input has no direct Go-source meaning"))
			return
		}
	}
	if phase != "execute" {
		step.backendErr = fmt.Errorf("Bash++ backend unsupported source phase %q", phase)
		t.backendEvent(mode, phase, "unsupported", compileInputs, programArgv,
			append(deviations, "only upstream execute phases have a direct run-program meaning in S157.2"))
		return
	}
	if tool == "" || os.Getenv("BASHPP_TESTDIR_VERSION") == "" {
		step.backendErr = fmt.Errorf("Bash++ backend requires an identified BASHPP_TESTDIR_TOOL")
		t.backendEvent(mode, phase, "configuration-error", compileInputs, programArgv, deviations)
		return
	}

	fileArgs := goFileArgs(compileInputs)
	switch mode {
	case "interpreted":
		checkArgs := append([]string{"--bashpp", "--source=go", "--check"}, fileArgs...)
		runArgs := append([]string{"--bashpp", "--source=go"}, fileArgs...)
		if len(programArgv) != 0 {
			runArgs = append(runArgs, "--")
			runArgs = append(runArgs, programArgv...)
		}
		*step.cmd = *shellCommand(step.cmd,
			append([]string{tool}, checkArgs...),
			append([]string{tool}, runArgs...))
		t.backendEvent(mode, phase, "check-then-run", compileInputs, programArgv, deviations)

	case "compiled":
		goTool := os.Getenv("BASHPP_TESTDIR_GO")
		shellrt := os.Getenv("BASHPP_SHELLRT_ROOT")
		if goTool == "" || shellrt == "" {
			step.backendErr = fmt.Errorf("compiled Bash++ backend requires BASHPP_TESTDIR_GO and caller-supplied BASHPP_SHELLRT_ROOT")
			t.backendEvent(mode, phase, "configuration-error", compileInputs, programArgv, deviations)
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
			t.backendEvent(mode, phase, "module-failed", compileInputs, programArgv, deviations)
			return
		}
		*step.cmd = *shellCommand(step.cmd,
			append([]string{tool}, transpileArgs...),
			[]string{goTool, "build", "-C", moduleDir, "-o", artifact, "."},
			append([]string{artifact}, programArgv...))
		t.backendEvent(mode, phase, "transpile-build-run", compileInputs, programArgv,
			append(deviations, "generated source is built in a temporary module with a caller-supplied mvdan.cc/sh/v3 replacement"))

	default:
		step.backendErr = fmt.Errorf("unsupported Bash++ backend mode %q", mode)
		t.backendEvent(mode, phase, "configuration-error", compileInputs, programArgv, deviations)
	}
}
