// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #149; Story: S149.4; Story-ID: 60134b3f734f
// Sprint: #154; Story: S154.0; Story-ID: 4877afd3a207
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifierRejectsStructuredMismatch(t *testing.T) {
	for _, field := range []string{"action", "recipe_flags", "native_argv"} {
		t.Run(field, func(t *testing.T) {
			phase, backend, result := compileEvidence("interpreted")
			switch field {
			case "action":
				backend.Action = "build"
			case "recipe_flags":
				backend.RecipeFlags = []string{"-l"}
			case "native_argv":
				backend.NativeArgv = []string{"bashy", "--check"}
			}
			_, err := verifyCompileEvidence(t, "interpreted", phase, backend, result)
			if err == nil || !strings.Contains(err.Error(), "action, flags, native argv") {
				t.Fatalf("verifyRow error = %v, want structured mismatch", err)
			}
		})
	}
}

func TestVerifierRejectsMissingCompileProof(t *testing.T) {
	phase, backend, result := compileEvidence("compiled")
	result.MapProof = nil
	_, err := verifyCompileEvidence(t, "compiled", phase, backend, result)
	if err == nil || !strings.Contains(err.Error(), "existence and hash proof") {
		t.Fatalf("verifyRow error = %v, want missing proof", err)
	}
}

func TestVerifierAcceptsCompileProof(t *testing.T) {
	phase, backend, result := compileEvidence("compiled")
	status, err := verifyCompileEvidence(t, "compiled", phase, backend, result)
	if err != nil || status != "COMPILE-ONLY-PASS" {
		t.Fatalf("verifyRow = %q, %v", status, err)
	}
}

func TestVerifierRetainsCompileProductFailure(t *testing.T) {
	for _, mode := range []string{"interpreted", "compiled"} {
		t.Run(mode, func(t *testing.T) {
			phase, backend, result := compileEvidence(mode)
			result.Exit = 2
			status, err := verifyCompileEvidenceAction(t, mode, "fail", phase, backend, result)
			if err != nil || status != "COMPILE-PRODUCT-FAIL" {
				t.Fatalf("verifyRow = %q, %v, want retained product failure", status, err)
			}
			result.Exit = 0
			if _, err := verifyCompileEvidenceAction(t, mode, "fail", phase, backend, result); err == nil || !strings.Contains(err.Error(), "nonzero compile phase exit") {
				t.Fatalf("verifyRow error = %v, want recorded nonzero exit", err)
			}
		})
	}
}

func TestVerifierRejectsCompileExecutePhase(t *testing.T) {
	phase, backend, result := compileEvidence("interpreted")
	phase.PhaseKind, backend.Phase = "execute", "execute"
	_, err := verifyCompileEvidenceAction(t, "interpreted", "pass", phase, backend, result)
	if err == nil || !strings.Contains(err.Error(), "compile-only phase") {
		t.Fatalf("verifyRow error = %v, want compile-only rejection", err)
	}
}

func TestVerifierAcceptsBuildOnly(t *testing.T) {
	for _, mode := range []string{"interpreted", "compiled"} {
		t.Run(mode, func(t *testing.T) {
			phase, backend, result := buildEvidence(mode, "fixedbugs/issue59404.go", []string{"-gcflags=-l=4"}, "")
			status, err := verifyBuildEvidence(t, mode, "fixedbugs/issue59404.go", "pass", phase, backend, result)
			if err != nil || status != "BUILD-ONLY-PASS" {
				t.Fatalf("verifyRow = %q, %v", status, err)
			}
		})
	}
}

func TestVerifierRequiresUpstreamRunenvGoexperiment(t *testing.T) {
	phase, backend, result := buildEvidence("interpreted", "arenas/smoke.go", []string{}, "arenas")
	if status, err := verifyBuildEvidence(t, "interpreted", "arenas/smoke.go", "pass", phase, backend, result); err != nil || status != "BUILD-ONLY-PASS" {
		t.Fatalf("verifyRow = %q, %v", status, err)
	}
	phase.EnvDelta = []string{}
	if _, err := verifyBuildEvidence(t, "interpreted", "arenas/smoke.go", "pass", phase, backend, result); err == nil || !strings.Contains(err.Error(), "GOEXPERIMENT") {
		t.Fatalf("verifyRow error = %v, want missing runenv GOEXPERIMENT", err)
	}
}

func TestVerifierRejectsRewrappedBuildFlags(t *testing.T) {
	for _, wrapped := range [][]string{{"-gcflags=all=-l=4"}, {"-gcflags=-l=4 -N"}, {}} {
		phase, backend, result := buildEvidence("compiled", "fixedbugs/issue59638.go", wrapped, "")
		_, err := verifyBuildEvidence(t, "compiled", "fixedbugs/issue59638.go", "pass", phase, backend, result)
		if err == nil || !strings.Contains(err.Error(), "exact upstream go-command flags") {
			t.Fatalf("verifyRow(%v) error = %v, want verbatim flag mismatch", wrapped, err)
		}
	}
}

func TestVerifierRejectsBuildExecutePhaseOrArtifactRun(t *testing.T) {
	phase, backend, result := buildEvidence("compiled", "fixedbugs/issue59404.go", []string{"-gcflags=-l=4"}, "")
	execPhase := phase
	execPhase.PhaseKind = "execute"
	execPhase.Action = "build"
	execBackend := backend
	execBackend.Phase = "execute"
	execResult := result
	_, err := verifyBuildEvidence(t, "compiled", "fixedbugs/issue59404.go", "pass",
		phase, backend, result, execPhase, execBackend, execResult)
	if err == nil || !strings.Contains(err.Error(), "exactly one build phase") {
		t.Fatalf("verifyRow error = %v, want single build-only phase", err)
	}
}

func TestVerifierRejectsBuildArtifactOutsideUpstreamCwd(t *testing.T) {
	phase, backend, result := buildEvidence("compiled", "fixedbugs/issue59404.go", []string{"-gcflags=-l=4"}, "")
	backend.Artifacts = []string{backend.Artifacts[0], "/elsewhere/a.exe"}
	_, err := verifyBuildEvidence(t, "compiled", "fixedbugs/issue59404.go", "pass", phase, backend, result)
	if err == nil || !strings.Contains(err.Error(), "upstream working directory") {
		t.Fatalf("verifyRow error = %v, want cwd artifact mismatch", err)
	}
}

func TestVerifierRetainsBuildProductFailure(t *testing.T) {
	phase, backend, result := buildEvidence("compiled", "arenas/smoke.go", []string{}, "arenas")
	result.Exit = 1
	result.ArtifactProof = []fileProof{{Path: backend.Artifacts[0], Exists: true, Bytes: 10, SHA256: strings.Repeat("a", 64)}, {Path: backend.Artifacts[1]}}
	result.MapProof = []fileProof{{Path: backend.Maps[0], Exists: true, Bytes: 5, SHA256: strings.Repeat("c", 64)}}
	status, err := verifyBuildEvidence(t, "compiled", "arenas/smoke.go", "fail", phase, backend, result)
	if err != nil || status != "BUILD-PRODUCT-FAIL" {
		t.Fatalf("verifyRow = %q, %v, want retained product failure", status, err)
	}
	result.Exit = 0
	if _, err := verifyBuildEvidence(t, "compiled", "arenas/smoke.go", "fail", phase, backend, result); err == nil || !strings.Contains(err.Error(), "nonzero build phase exit") {
		t.Fatalf("verifyRow error = %v, want recorded nonzero exit", err)
	}
}

func buildEvidence(mode, test string, recipeFlags []string, goexperiment string) (eventRecord, eventRecord, eventRecord) {
	cwd := "/tmp/testdir"
	long := "/goroot/test/" + test
	native := []string{"go", "build", "", "-o", "a.exe", long}
	envDelta := []string{}
	if goexperiment != "" {
		envDelta = []string{"GOEXPERIMENT=" + goexperiment}
	}
	phase := eventRecord{Kind: "phase", Test: test, Action: "build", PhaseKind: "compile", CompileInputs: []string{long}, ProgramArgv: []string{}, RecipeFlags: recipeFlags, Argv: native, Cwd: cwd, EnvDelta: envDelta}
	backend := eventRecord{Kind: "backend", Test: test, BackendSchema: backendSchema, Mode: mode, Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: phase.Action, Phase: phase.PhaseKind, CompileInputs: phase.CompileInputs, ProgramArgv: phase.ProgramArgv, RecipeFlags: phase.RecipeFlags, NativeArgv: native, Disposition: "check-only", Deviations: []string{"structured evidence"}}
	result := eventRecord{Kind: "phase_result", Test: test, Exit: 0}
	if mode == "compiled" {
		backend.Disposition = "transpile-build-only"
		backend.Artifacts = []string{"/tmp/module/main.go", cwd + "/a.exe"}
		backend.Maps = []string{"/tmp/module/main.go.map"}
		result.ArtifactProof = []fileProof{{Path: backend.Artifacts[0], Exists: true, Bytes: 10, SHA256: strings.Repeat("a", 64)}, {Path: backend.Artifacts[1], Exists: true, Bytes: 20, SHA256: strings.Repeat("b", 64)}}
		result.MapProof = []fileProof{{Path: backend.Maps[0], Exists: true, Bytes: 5, SHA256: strings.Repeat("c", 64)}}
	}
	return phase, backend, result
}

func verifyBuildEvidence(t *testing.T, mode, test, goAction string, records ...eventRecord) (string, error) {
	t.Helper()
	dir := t.TempDir()
	base := filepath.Join(dir, strings.NewReplacer("/", "_", ".", "_").Replace(test))
	writeJSONLines(t, base+".go-test.json", goRecord{Action: goAction, Test: "Test/" + test})
	items := make([]any, 0, len(records)+1)
	for _, record := range records {
		items = append(items, record)
	}
	items = append(items, eventRecord{Kind: "terminal", Test: test, Failed: goAction == "fail"})
	writeJSONLines(t, base+".events.jsonl", items...)
	return verifyRow(matrixRow{Test: test, Action: "build"}, dir, mode, "test", "/bin/bashy")
}

func compileEvidence(mode string) (eventRecord, eventRecord, eventRecord) {
	native := []string{"go", "tool", "compile", "-N", "bug020.go"}
	phase := eventRecord{Kind: "phase", Test: "fixedbugs/bug020.go", Action: "compile", PhaseKind: "compile", CompileInputs: []string{"bug020.go"}, ProgramArgv: []string{}, RecipeFlags: []string{"-N"}, Argv: native}
	backend := eventRecord{Kind: "backend", Test: phase.Test, BackendSchema: backendSchema, Mode: mode, Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: phase.Action, Phase: phase.PhaseKind, CompileInputs: phase.CompileInputs, ProgramArgv: phase.ProgramArgv, RecipeFlags: phase.RecipeFlags, NativeArgv: native, Disposition: "check-only", Deviations: []string{"structured evidence"}}
	result := eventRecord{Kind: "phase_result", Test: phase.Test, Exit: 0}
	if mode == "compiled" {
		backend.Disposition = "transpile-compile-only"
		backend.Artifacts = []string{"/tmp/main.go", "/tmp/program"}
		backend.Maps = []string{"/tmp/main.go.map"}
		backend.CompilerArgv = []string{"go", "tool", "compile", "-importcfg=/tmp/importcfg", "-N", "/tmp/main.go"}
		result.ArtifactProof = []fileProof{{Path: "/tmp/main.go", Exists: true, Bytes: 10, SHA256: strings.Repeat("a", 64)}, {Path: "/tmp/program", Exists: true, Bytes: 20, SHA256: strings.Repeat("b", 64)}}
		result.MapProof = []fileProof{{Path: "/tmp/main.go.map", Exists: true, Bytes: 5, SHA256: strings.Repeat("c", 64)}}
	}
	return phase, backend, result
}

// Sprint: #162; Story: S162.4b; Story-ID: 41dd6897a116
func TestVerifierRequiresDirectCompilerEvidence(t *testing.T) {
	phase, backend, result := compileEvidence("compiled")
	status, err := verifyCompileEvidence(t, "compiled", phase, backend, result)
	if err != nil || status != "COMPILE-ONLY-PASS" {
		t.Fatalf("verifyRow = %q, %v", status, err)
	}
	backend.CompilerArgv = []string{"go", "build", "-gcflags=-complete", "/tmp/main.go"}
	if _, err := verifyCompileEvidence(t, "compiled", phase, backend, result); err == nil || !strings.Contains(err.Error(), "direct upstream-shaped compiler argv") {
		t.Fatalf("verifyRow error = %v, want direct compiler argv rejection", err)
	}
}

func verifyCompileEvidence(t *testing.T, mode string, records ...eventRecord) (string, error) {
	t.Helper()
	return verifyCompileEvidenceAction(t, mode, "pass", records...)
}

func verifyCompileEvidenceAction(t *testing.T, mode, goAction string, records ...eventRecord) (string, error) {
	t.Helper()
	dir := t.TempDir()
	base := filepath.Join(dir, "fixedbugs_bug020_go")
	writeJSONLines(t, base+".go-test.json", goRecord{Action: goAction, Test: "Test/fixedbugs/bug020.go"})
	items := make([]any, 0, len(records)+1)
	for _, record := range records {
		items = append(items, record)
	}
	items = append(items, eventRecord{Kind: "terminal", Test: "fixedbugs/bug020.go", Failed: goAction == "fail"})
	writeJSONLines(t, base+".events.jsonl", items...)
	return verifyRow(matrixRow{Test: "fixedbugs/bug020.go", Action: "compile"}, dir, mode, "test", "/bin/bashy")
}

func writeJSONLines(t *testing.T, name string, records ...any) {
	t.Helper()
	var data []byte
	for _, record := range records {
		line, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		data = append(data, line...)
		data = append(data, '\n')
	}
	if err := os.WriteFile(name, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// Sprint: #154; Story: S154.0; Story-ID: 4877afd3a207
// TestVerifierAcceptsDeclaredOptimizerDiagnostics: an interpreted errorcheck
// root whose recipe wants optimizer diagnostics (-m/-live/-race/-d=) is
// declared unsupported by the seam with the compiler-artifact reason, and the
// verifier accepts the declaration the way it accepts interpreted asmcheck.
// Without the declared reason, or on a non-failing terminal, it still rejects.
func TestVerifierAcceptsDeclaredOptimizerDiagnostics(t *testing.T) {
	optimizerEvidence := func(deviation string) []eventRecord {
		test := "escape/escape.go"
		native := []string{"go", "tool", "compile", "-m", "-l", "escape.go"}
		flags := []string{"-0", "-m", "-l"}
		phase := eventRecord{Kind: "phase", Test: test, Action: "errorcheck", PhaseKind: "compile", CompileInputs: []string{"/goroot/test/" + test}, ProgramArgv: []string{}, RecipeFlags: flags, Argv: native}
		backend := eventRecord{Kind: "backend", Test: test, BackendSchema: backendSchema, Mode: "interpreted", Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: phase.Action, Phase: phase.PhaseKind, CompileInputs: phase.CompileInputs, ProgramArgv: phase.ProgramArgv, RecipeFlags: phase.RecipeFlags, NativeArgv: native, Disposition: "unsupported", Deviations: []string{deviation}}
		// A backendErr step never starts the command; done() records exit -1.
		result := eventRecord{Kind: "phase_result", Test: test, Exit: -1}
		return []eventRecord{phase, backend, result}
	}
	declared := "optimizer diagnostics are a compiler artifact; the check interface has no inlining, escape-analysis or SSA meaning"

	verify := func(goAction string, records []eventRecord) (string, error) {
		dir := t.TempDir()
		base := filepath.Join(dir, "escape_escape_go")
		writeJSONLines(t, base+".go-test.json", goRecord{Action: goAction, Test: "Test/escape/escape.go"})
		items := make([]any, 0, len(records)+1)
		for _, record := range records {
			items = append(items, record)
		}
		items = append(items, eventRecord{Kind: "terminal", Test: "escape/escape.go", Failed: goAction == "fail"})
		writeJSONLines(t, base+".events.jsonl", items...)
		return verifyRow(matrixRow{Test: "escape/escape.go", Action: "errorcheck"}, dir, "interpreted", "test", "/bin/bashy")
	}

	status, err := verify("fail", optimizerEvidence(declared))
	if err != nil || status != "UNSUPPORTED" {
		t.Fatalf("verifyRow = %q, %v, want accepted UNSUPPORTED declaration", status, err)
	}
	if _, err := verify("fail", optimizerEvidence("structured evidence")); err == nil || !strings.Contains(err.Error(), "disposition") {
		t.Fatalf("verifyRow error = %v, want undeclared unsupported rejection", err)
	}
	if _, err := verify("pass", optimizerEvidence(declared)); err == nil || !strings.Contains(err.Error(), "upstream action") {
		t.Fatalf("verifyRow error = %v, want rejection of a passing unsupported declaration", err)
	}
}

// Sprint: #150; Story: S150.6; Story-ID: 4228ed646074
func runEvidence(mode string, recipeFlags, programArgv []string) (eventRecord, eventRecord, eventRecord) {
	test := "fixedbugs/issue32680.go"
	native := append([]string{"go", "run", ""}, recipeFlags...)
	native = append(native, test)
	native = append(native, programArgv...)
	phase := eventRecord{Kind: "phase", Test: test, Action: "run", PhaseKind: "execute", CompileInputs: []string{test}, ProgramArgv: programArgv, RecipeFlags: recipeFlags, Argv: native, Cwd: "/tmp/testdir"}
	backend := eventRecord{Kind: "backend", Test: test, BackendSchema: backendSchema, Mode: mode, Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: phase.Action, Phase: phase.PhaseKind, CompileInputs: phase.CompileInputs, ProgramArgv: phase.ProgramArgv, RecipeFlags: phase.RecipeFlags, NativeArgv: native, Disposition: "check-then-run", Deviations: []string{"structured evidence"}}
	if mode == "compiled" {
		backend.Disposition = "transpile-build-run"
	}
	if len(recipeFlags) != 0 {
		backend.Deviations = append(backend.Deviations, "upstream go-command recipe flags are passed verbatim")
	}
	result := eventRecord{Kind: "phase_result", Test: test, Exit: 0}
	return phase, backend, result
}

func verifyRunEvidence(t *testing.T, mode, goAction string, records ...eventRecord) (string, error) {
	t.Helper()
	dir := t.TempDir()
	base := filepath.Join(dir, "fixedbugs_issue32680_go")
	writeJSONLines(t, base+".go-test.json", goRecord{Action: goAction, Test: "Test/fixedbugs/issue32680.go"})
	items := make([]any, 0, len(records)+1)
	for _, record := range records {
		items = append(items, record)
	}
	items = append(items, eventRecord{Kind: "terminal", Test: "fixedbugs/issue32680.go", Failed: goAction == "fail"})
	writeJSONLines(t, base+".events.jsonl", items...)
	return verifyRow(matrixRow{Test: "fixedbugs/issue32680.go", Action: "run"}, dir, mode, "test", "/bin/bashy")
}

func TestVerifierAcceptsDirectRun(t *testing.T) {
	for _, mode := range []string{"interpreted", "compiled"} {
		t.Run(mode, func(t *testing.T) {
			phase, backend, result := runEvidence(mode, []string{"-gcflags=-d=ssa/check/on"}, []string{})
			status, err := verifyRunEvidence(t, mode, "pass", phase, backend, result)
			if err != nil || status != "RUN-PASS" {
				t.Fatalf("verifyRow = %q, %v", status, err)
			}
			// Upstream checkExpectedOutput can fail after a clean exit; that is
			// a retained product failure, not a seam defect.
			status, err = verifyRunEvidence(t, mode, "fail", phase, backend, result)
			if err != nil || status != "RUN-PRODUCT-FAIL" {
				t.Fatalf("verifyRow = %q, %v, want retained product failure", status, err)
			}
		})
	}
}

func TestVerifierRejectsRunBoundaryAndUndeclaredFlags(t *testing.T) {
	phase, backend, result := runEvidence("compiled", []string{"-race"}, []string{"extra.go"})
	phase.ProgramArgv, backend.ProgramArgv = []string{"extra.go"}, []string{"extra.go"}
	if _, err := verifyRunEvidence(t, "compiled", "pass", phase, backend, result); err == nil || !strings.Contains(err.Error(), "boundary") {
		t.Fatalf("verifyRow error = %v, want source/argument boundary rejection", err)
	}
	phase, backend, result = runEvidence("compiled", []string{"-race"}, []string{})
	backend.Deviations = []string{"structured evidence"}
	if _, err := verifyRunEvidence(t, "compiled", "pass", phase, backend, result); err == nil || !strings.Contains(err.Error(), "declared") {
		t.Fatalf("verifyRow error = %v, want undeclared recipe-flag rejection", err)
	}
	phase, backend, result = runEvidence("interpreted", nil, []string{})
	backend.Disposition = "transpile-build-run"
	if _, err := verifyRunEvidence(t, "interpreted", "pass", phase, backend, result); err == nil || !strings.Contains(err.Error(), "direct") {
		t.Fatalf("verifyRow error = %v, want wrong-mode rejection", err)
	}
}

// Sprint: #150; Story: S150.5; Story-ID: e87e1cbcbb20
func buildRunEvidence(mode string) []eventRecord {
	test := "fixedbugs/issue46234.go"
	cwd, long := "/tmp/testdir", "/goroot/test/"+test
	build := eventRecord{Kind: "phase", Test: test, Action: "buildrun", PhaseKind: "compile", CompileInputs: []string{long}, ProgramArgv: []string{}, RecipeFlags: []string{}, Argv: []string{"go", "build", "", "-o", "a.exe", long}, Cwd: cwd}
	buildBackend := eventRecord{Kind: "backend", Test: test, BackendSchema: backendSchema, Mode: mode, Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: "buildrun", Phase: "compile", CompileInputs: build.CompileInputs, ProgramArgv: build.ProgramArgv, RecipeFlags: build.RecipeFlags, NativeArgv: build.Argv, Disposition: "check-only", Deviations: []string{"structured evidence"}}
	run := eventRecord{Kind: "phase", Test: test, Action: "buildrun", PhaseKind: "execute", CompileInputs: []string{}, ProgramArgv: []string{}, RecipeFlags: []string{}, Argv: []string{"./a.exe"}, Cwd: cwd}
	runBackend := eventRecord{Kind: "backend", Test: test, BackendSchema: backendSchema, Mode: mode, Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: "buildrun", Phase: "execute", CompileInputs: run.CompileInputs, ProgramArgv: run.ProgramArgv, RecipeFlags: run.RecipeFlags, NativeArgv: run.Argv, Disposition: "run-remembered-program", Deviations: []string{"structured evidence"}, Program: &programRec{Files: build.CompileInputs}}
	if mode == "compiled" {
		buildBackend.Disposition = "transpile-build-only"
		buildBackend.Artifacts = []string{"/tmp/module/main.go", cwd + "/a.exe"}
		buildBackend.Maps = []string{"/tmp/module/main.go.map"}
		runBackend.Disposition = "run-artifact"
		runBackend.Program.Artifact = cwd + "/a.exe"
		runBackend.Artifacts = []string{cwd + "/a.exe"}
	}
	return []eventRecord{build, buildBackend, {Kind: "phase_result", Test: test, Exit: 0}, run, runBackend, {Kind: "phase_result", Test: test, Exit: 0}}
}

func verifyBuildRunEvidence(t *testing.T, mode, goAction string, records []eventRecord) (string, error) {
	t.Helper()
	dir := t.TempDir()
	base := filepath.Join(dir, "fixedbugs_issue46234_go")
	writeJSONLines(t, base+".go-test.json", goRecord{Action: goAction, Test: "Test/fixedbugs/issue46234.go"})
	items := make([]any, 0, len(records)+1)
	for _, record := range records {
		items = append(items, record)
	}
	items = append(items, eventRecord{Kind: "terminal", Test: "fixedbugs/issue46234.go", Failed: goAction == "fail"})
	writeJSONLines(t, base+".events.jsonl", items...)
	return verifyRow(matrixRow{Test: "fixedbugs/issue46234.go", Action: "buildrun"}, dir, mode, "test", "/bin/bashy")
}

func TestVerifierBuildRunProgramContinuity(t *testing.T) {
	for _, mode := range []string{"interpreted", "compiled"} {
		t.Run(mode, func(t *testing.T) {
			records := buildRunEvidence(mode)
			status, err := verifyBuildRunEvidence(t, mode, "pass", records)
			if err != nil || status != "BUILDRUN-PASS" {
				t.Fatalf("verifyRow = %q, %v", status, err)
			}
			// The execute phase must act on exactly what the build phase compiled.
			records = buildRunEvidence(mode)
			records[4].Program.Files = []string{"/goroot/test/other.go"}
			if _, err := verifyBuildRunEvidence(t, mode, "pass", records); err == nil || !strings.Contains(err.Error(), "not what the build phase compiled") {
				t.Fatalf("verifyRow error = %v, want program continuity rejection", err)
			}
			// A failed build stops upstream: one phase, recorded nonzero exit.
			records = buildRunEvidence(mode)[:3]
			records[2].Exit = 1
			status, err = verifyBuildRunEvidence(t, mode, "fail", records)
			if err != nil || status != "BUILDRUN-PRODUCT-FAIL" {
				t.Fatalf("verifyRow = %q, %v, want retained build failure", status, err)
			}
		})
	}
}
