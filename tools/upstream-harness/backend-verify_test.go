// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #149; Story: S149.4; Story-ID: 60134b3f734f
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

func compileEvidence(mode string) (eventRecord, eventRecord, eventRecord) {
	native := []string{"go", "tool", "compile", "-N", "bug020.go"}
	phase := eventRecord{Kind: "phase", Test: "fixedbugs/bug020.go", Action: "compile", PhaseKind: "compile", CompileInputs: []string{"bug020.go"}, ProgramArgv: []string{}, RecipeFlags: []string{"-N"}, Argv: native}
	backend := eventRecord{Kind: "backend", Test: phase.Test, BackendSchema: backendSchema, Mode: mode, Tool: toolIdentity{Path: "/bin/bashy", Version: "test"}, Action: phase.Action, Phase: phase.PhaseKind, CompileInputs: phase.CompileInputs, ProgramArgv: phase.ProgramArgv, RecipeFlags: phase.RecipeFlags, NativeArgv: native, Disposition: "check-only", Deviations: []string{"structured evidence"}}
	result := eventRecord{Kind: "phase_result", Test: phase.Test, Exit: 0}
	if mode == "compiled" {
		backend.Disposition = "transpile-build-only"
		backend.Artifacts = []string{"/tmp/main.go", "/tmp/program"}
		backend.Maps = []string{"/tmp/main.go.map"}
		result.ArtifactProof = []fileProof{{Path: "/tmp/main.go", Exists: true, Bytes: 10, SHA256: strings.Repeat("a", 64)}, {Path: "/tmp/program", Exists: true, Bytes: 20, SHA256: strings.Repeat("b", 64)}}
		result.MapProof = []fileProof{{Path: "/tmp/main.go.map", Exists: true, Bytes: 5, SHA256: strings.Repeat("c", 64)}}
	}
	return phase, backend, result
}

func verifyCompileEvidence(t *testing.T, mode string, records ...eventRecord) (string, error) {
	t.Helper()
	dir := t.TempDir()
	base := filepath.Join(dir, "fixedbugs_bug020_go")
	writeJSONLines(t, base+".go-test.json", goRecord{Action: "pass", Test: "Test/fixedbugs/bug020.go"})
	items := make([]any, 0, len(records)+1)
	for _, record := range records {
		items = append(items, record)
	}
	items = append(items, eventRecord{Kind: "terminal", Test: "fixedbugs/bug020.go"})
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
