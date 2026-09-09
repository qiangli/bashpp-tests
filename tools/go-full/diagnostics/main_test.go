package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T, diagnostics string) request {
	t.Helper()
	dir := t.TempDir()
	write := func(name, data string) fileInput {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		return fileInput{Path: p, Short: name, SHA256: fmt.Sprintf("%x", sha256.Sum256([]byte(data)))}
	}
	req := request{WantError: true, Sources: []fileInput{write("case.go", "package p\nvar _ = missing // ERROR \"undefined: missing\"\n")}, Stdout: write("stdout", ""), Stderr: write("stderr", diagnostics)}
	req.Process.Spawned, req.Process.State = true, "exited"
	exit := 1
	req.Process.Exit = &exit
	return req
}
func TestExactAnnotationAndUnknownOutput(t *testing.T) {
	req := fixture(t, "case.go:2:9: undefined: missing\n")
	if res, err := check(req); err != nil || res.Verdict != "PASS" || res.WantedErrors != 1 {
		t.Fatalf("matching diagnostic rejected: %+v %v", res, err)
	}
	for _, text := range []string{"", "case.go:3:9: undefined: missing\n", "case.go:2:9: undefined: missing\npanic: unrelated failure\n", "case.go:2:9: undefined: missing\nother.go:9: unknown failure\n", "case.go:2:9: undefined: missing\ngo tool compile: signal: killed\n"} {
		if _, err := check(fixture(t, text)); err == nil {
			t.Fatalf("accepted invalid diagnostics: %q", text)
		}
	}
}
func TestProcessFailuresCannotMatch(t *testing.T) {
	for _, state := range []string{"deadline", "process_leak", "launch_failure"} {
		req := fixture(t, "case.go:2:9: undefined: missing\n")
		req.Process.State = state
		if _, err := check(req); err == nil {
			t.Fatalf("accepted %s", state)
		}
	}
	req := fixture(t, "case.go:2:9: undefined: missing\n")
	signal := 9
	req.Process.Signal = &signal
	if _, err := check(req); err == nil {
		t.Fatal("accepted signal")
	}
}
func TestTamperedSourceAndOutput(t *testing.T) {
	for _, target := range []string{"source", "output"} {
		req := fixture(t, "case.go:2:9: undefined: missing\n")
		path := req.Sources[0].Path
		if target == "output" {
			path = req.Stderr.Path
		}
		if err := os.WriteFile(path, []byte("tampered"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := check(req); err == nil || !strings.Contains(err.Error(), "checksum") {
			t.Fatalf("accepted %s tamper: %v", target, err)
		}
	}
}
