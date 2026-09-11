// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #157; Story: S157.1; Story-ID: b7560ec00ec1
//
// Observation-only seam for Go 1.27's cmd/internal/testdir harness. Hooks in
// the authenticated patch pass values only after upstream selected them.
package testdir_test

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"path"
	"strings"
	"sync"
)

const eventSchema = "bashpp-tests/upstream-testdir-event/v1"

type eventWriter struct {
	mu    sync.Mutex
	f     *os.File
	order map[string]int
}

var events = newEventWriter()

func newEventWriter() *eventWriter {
	name := os.Getenv("BASHPP_TESTDIR_EVENTS")
	if name == "" {
		return nil
	}
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		log.Fatalf("testdir events: %v", err)
	}
	return &eventWriter{f: f, order: make(map[string]int)}
}

func (w *eventWriter) emit(test, kind string, fields map[string]any) {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	rec := map[string]any{
		"schema":  eventSchema,
		"kind":    kind,
		"test":    test,
		"subtest": "Test/" + test,
		"order":   w.order[test],
	}
	w.order[test]++
	for k, v := range fields {
		rec[k] = v
	}
	b, err := json.Marshal(rec)
	if err == nil {
		_, err = w.f.Write(append(b, '\n'))
	}
	if err != nil {
		log.Fatalf("testdir events: %v", err)
	}
}

func nonNil(ss []string) []string {
	if ss == nil {
		return []string{}
	}
	return ss
}

// goRunOperands reflects the operand boundary of the exact `go run` command
// assembled by testdir: leading .go operands extend the source file set, and
// the first other operand begins the executed program's argv. It never probes
// the corpus or selects an additional file.
func goRunOperands(primary string, operands []string) (inputs, argv []string) {
	inputs = []string{primary}
	i := 0
	for i < len(operands) && strings.HasSuffix(operands[i], ".go") {
		inputs = append(inputs, operands[i])
		i++
	}
	return inputs, nonNil(operands[i:])
}

func (t test) eventName() string { return path.Join(t.dir, t.goFile) }

func (t test) planCase(_ []byte) {
	events.emit(t.eventName(), "case", map[string]any{
		"corpus_path": "test/" + t.eventName(),
		"expect_fail": t.expectFail(),
	})
}

func (t test) planSkip(action, origin, reason string) {
	events.emit(t.eventName(), "selection", map[string]any{
		"action":      action,
		"applicable":  false,
		"skip_origin": origin,
		"skip_reason": reason,
	})
}

func (t test) eventAsmComparison(env string, err error) {
	events.emit(t.eventName(), "comparison", map[string]any{
		"comparison_mode": "assembly-opcode-regexp",
		"environment":     env,
		"matched":         err == nil,
	})
}

func (t test) planRecipe(words []string, action string, args, flags, runenv []string, tim int, wantError, wantAuto, singlefilepkgs bool, gomodvers, goexp, godebug, tempDir string) {
	events.emit(t.eventName(), "selection", map[string]any{
		"applicable":           true,
		"action":               action,
		"recipe_words":         nonNil(words),
		"recipe_arguments":     nonNil(args),
		"flags":                nonNil(flags),
		"cwd":                  tempDir,
		"env_delta":            nonNil(runenv),
		"timeout_seconds":      tim,
		"want_error":           wantError,
		"want_auto":            wantAuto,
		"single_file_packages": singlefilepkgs,
		"go_mod_version":       gomodvers,
		"goexperiment":         goexp,
		"godebug":              godebug,
	})
}

type planStep struct {
	test      string
	phase     int
	cmd       *exec.Cmd
	artifacts []string
	maps      []string
}

func (t test) planExec(cmd *exec.Cmd, timeoutSeconds int, action, phase string, compileInputs, programArgv, recipeFlags []string) *planStep {
	// Every value here is passed by the exact action-switch/helper call site.
	// This hook never parses argv or probes the filesystem.
	fields := map[string]any{
		"action":          action,
		"phase_kind":      phase,
		"argv":            nonNil(cmd.Args),
		"compile_inputs":  nonNil(compileInputs),
		"program_argv":    nonNil(programArgv),
		"recipe_flags":    nonNil(recipeFlags),
		"cwd":             cmd.Dir,
		"env_delta":       commandEnvDelta(cmd.Env),
		"timeout_seconds": timeoutSeconds,
	}
	events.emit(t.eventName(), "phase", fields)
	return &planStep{test: t.eventName(), cmd: cmd}
}

func commandEnvDelta(env []string) []string {
	base := make(map[string]string)
	for _, entry := range os.Environ() {
		key, value, _ := strings.Cut(entry, "=")
		base[key] = value
	}
	var delta []string
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		if old, ok := base[key]; !ok || old != value {
			delta = append(delta, entry)
		}
	}
	return nonNil(delta)
}

func (s *planStep) run(buf interface{ String() string }) error {
	err := s.cmd.Run()
	s.done([]byte(buf.String()), err)
	return err
}

func (s *planStep) done(out []byte, err error) {
	if events == nil || s.test == "" {
		return
	}
	exit := 0
	if s.cmd.ProcessState != nil {
		exit = s.cmd.ProcessState.ExitCode()
	} else if err != nil {
		exit = -1
	}
	proof := func(paths []string) []map[string]any {
		result := make([]map[string]any, 0, len(paths))
		for _, path := range paths {
			item := map[string]any{"path": path, "exists": false, "bytes": 0, "sha256": ""}
			data, readErr := os.ReadFile(path)
			if readErr == nil {
				digest := sha256.Sum256(data)
				item["exists"] = true
				item["bytes"] = len(data)
				item["sha256"] = hex.EncodeToString(digest[:])
			}
			result = append(result, item)
		}
		return result
	}
	events.emit(s.test, "phase_result", map[string]any{
		"exit":           exit,
		"output_bytes":   len(out),
		"timed_out":      errors.Is(err, errTimeout),
		"artifact_proof": proof(s.artifacts),
		"map_proof":      proof(s.maps),
	})
}

func (t test) planErrorCheck(outStr string, wantAuto bool, fullshort []string, err error) {
	files := make([]string, 0, len(fullshort)/2)
	for i := 1; i < len(fullshort); i += 2 {
		files = append(files, fullshort[i])
	}
	events.emit(t.eventName(), "comparison", map[string]any{
		"comparison_mode": "diagnostic-regexp",
		"inputs":          nonNil(files),
		"want_auto":       wantAuto,
		"actual_bytes":    len(outStr),
		"matched":         err == nil,
	})
}

func (t test) eventExpectedDiagnostics(want []wantedError) {
	type diagnostic struct {
		File    string `json:"file"`
		Line    int    `json:"line"`
		Pattern string `json:"pattern"`
		Auto    bool   `json:"auto"`
	}
	diagnostics := make([]diagnostic, 0, len(want))
	for _, item := range want {
		diagnostics = append(diagnostics, diagnostic{item.file, item.lineNum, item.reStr, item.auto})
	}
	events.emit(t.eventName(), "expected_diagnostics", map[string]any{
		"comparison_mode": "diagnostic-regexp",
		"diagnostics":     diagnostics,
	})
}

func (t test) eventExpectedOutput(filename string, present bool, expected, actual []byte, err error) {
	events.emit(t.eventName(), "comparison", map[string]any{
		"comparison_mode":   "exact-output-crlf-normalized",
		"companion":         filename,
		"companion_present": present,
		"expected_bytes":    len(expected),
		"actual_bytes":      len(actual),
		"expected":          string(expected),
		"actual":            string(actual),
		"matched":           err == nil,
	})
}

func (t test) eventCompanions(role string, names []string) {
	events.emit(t.eventName(), "companions", map[string]any{
		"role":  role,
		"paths": nonNil(names),
	})
}

func (t test) eventGenerated(role, name string, bytes int) {
	events.emit(t.eventName(), "generated", map[string]any{
		"role":  role,
		"path":  name,
		"bytes": bytes,
	})
}

func (t test) eventBypass(phase, reason string) {
	events.emit(t.eventName(), "bypass", map[string]any{
		"phase_kind": phase,
		"reason":     reason,
	})
}

func (t test) planVerdict(testError error, wantError bool) {
	outcome := "pass"
	if testError != nil && wantError {
		outcome = "expected-fail"
	} else if testError != nil {
		outcome = "fail"
	} else if wantError {
		outcome = "unexpected-success"
	}
	events.emit(t.eventName(), "verdict", map[string]any{
		"outcome":     outcome,
		"expect_fail": wantError,
	})
}

func (t test) planTerminal() {
	events.emit(t.eventName(), "terminal", map[string]any{
		"skipped": t.Skipped(),
		"failed":  t.Failed(),
	})
}
