// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #155; Story: S155.7; Story-ID: e6c82be4a112
package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type corpusFixture struct {
	t        *testing.T
	base     string
	evidence string
	skips    string
	manifest string
}

func TestCorpusVerifyAcceptsCompleteEvidence(t *testing.T) {
	f := newCorpusFixture(t)
	code, stdout, stderr := f.verify(3)
	if code != 0 {
		t.Fatalf("verify = %d, stderr:\n%s", code, stderr)
	}
	for _, want := range []string{
		"ROOTS\t3\n",
		"RUNNER\ttestdir\tnative\tPASS=1\tFAIL=0\tSKIP=0\n",
		"ROOT\tpackage:example/p\tnative=PASS\tinterpreted=PASS\tcompiled=PASS\n",
		"NATIVE_TESTED_SOURCE_EXECUTIONS\t0\n",
		"MANIFEST\t",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout lacks %q:\n%s", want, stdout)
		}
	}
	if data, err := os.ReadFile(f.manifest); err != nil || len(data) == 0 {
		t.Fatalf("manifest was not written: bytes=%d err=%v", len(data), err)
	}
}

func TestCorpusVerifyDefectFixtures(t *testing.T) {
	tests := []struct {
		name string
		edit func(*corpusFixture)
		want string
	}{
		{
			name: "duplicate ID",
			edit: func(f *corpusFixture) {
				f.writeGo("native", "testdir.go-test.json",
					corpusGoEvent{Action: "pass", Test: "Test/a.go"},
					corpusGoEvent{Action: "pass", Test: "Test/a.go"})
			},
			want: "duplicate ID testdir:a.go",
		},
		{
			name: "missing ID",
			edit: func(f *corpusFixture) {
				for _, mode := range corpusModes {
					f.writeGo(mode, "package.go-test.json")
					if mode != "native" {
						f.writeRecords(filepath.Join("evidence-"+mode, "packages", "example_p.events.jsonl"))
					}
				}
			},
			want: "unique root count is 2, want 3",
		},
		{
			name: "extra SKIP",
			edit: func(f *corpusFixture) {
				for _, mode := range corpusModes {
					f.writeGo(mode, "testdir.go-test.json", corpusGoEvent{Action: "skip", Test: "Test/a.go"})
					if mode != "native" {
						f.writeTestdir(mode, "skip")
					}
				}
			},
			want: "SKIP set differs",
		},
		{
			name: "native exec record in backend lane",
			edit: func(f *corpusFixture) {
				f.writeRecords(filepath.Join("evidence-interpreted", "packages", "example_p.events.jsonl"), map[string]any{
					"schema": corpusPackageSchema, "kind": "plan", "package": "example/p", "mode": "interpreted",
					"disposition": "run-package-map",
					"native_argv": []string{"p.test", "-test.v"}, "argv": []string{"p.test", "-test.v"},
					"enumeration": map[string]int{"tests": 1, "benchmarks": 0, "examples": 0, "fuzz_targets": 0},
				})
			},
			want: "native tested-source executions in backend lanes = 1, want 0",
		},
		{
			name: "root missing one mode terminal",
			edit: func(f *corpusFixture) {
				f.writeGo("compiled", "types2.go-test.json")
				f.writeRecords(filepath.Join("evidence-compiled", "types2.events.jsonl"))
			},
			want: "root typechecker:cmd/compile/internal/types2/TestCheck/x.go is missing compiled terminal",
		},
		{
			name: "manifest hash mismatch",
			edit: func(f *corpusFixture) {
				f.writeFile(f.manifest, "not-the-stream-manifest\n")
			},
			want: "manifest hash mismatch",
		},
		{
			name: "zero-test package inversion",
			edit: func(f *corpusFixture) {
				f.writePackage("interpreted", 0)
			},
			want: "package:example/p has zero enumerated test bodies",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f := newCorpusFixture(t)
			tc.edit(f)
			code, _, stderr := f.verify(3)
			if code != 1 {
				t.Fatalf("verify = %d, want 1; stderr:\n%s", code, stderr)
			}
			if !strings.Contains(stderr, tc.want) {
				t.Fatalf("stderr lacks %q:\n%s", tc.want, stderr)
			}
		})
	}
}

func newCorpusFixture(t *testing.T) *corpusFixture {
	t.Helper()
	base := t.TempDir()
	f := &corpusFixture{
		t: t, base: base, evidence: filepath.Join(base, "evidence"),
		skips: filepath.Join(base, "skips.txt"), manifest: filepath.Join(base, "manifest.sha256"),
	}
	f.writeFile(f.skips, "")
	for _, mode := range corpusModes {
		if err := os.MkdirAll(filepath.Join(f.evidence, "evidence-"+mode, "packages"), 0o755); err != nil {
			t.Fatal(err)
		}
		f.writeGo(mode, "testdir.go-test.json", corpusGoEvent{Action: "pass", Test: "Test/a.go"})
		f.writeGo(mode, "types2.go-test.json", corpusGoEvent{Action: "pass", Package: "cmd/compile/internal/types2", Test: "TestCheck/x.go"})
		f.writeGo(mode, "types.go-test.json")
		f.writeGo(mode, "package.go-test.json", corpusGoEvent{Action: "pass", Package: "example/p"})
		if mode != "native" {
			f.writeTestdir(mode, "pass")
			f.writeRecords(filepath.Join("evidence-"+mode, "types2.events.jsonl"), map[string]any{
				"kind": "types-backend", "test": "TestCheck/x.go", "argv": []string{"bashy", "--check"},
			})
			f.writeRecords(filepath.Join("evidence-"+mode, "types.events.jsonl"))
			f.writePackage(mode, 1)
		}
	}
	return f
}

func (f *corpusFixture) verify(expect int) (int, string, string) {
	f.t.Helper()
	var stdout, stderr bytes.Buffer
	code := verifyCorpus(corpusConfig{
		evidence: f.evidence, expectRoots: expect, expectSkips: f.skips, manifest: f.manifest,
	}, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func (f *corpusFixture) writeGo(mode, name string, events ...corpusGoEvent) {
	f.t.Helper()
	values := make([]any, len(events))
	for i := range events {
		values[i] = events[i]
	}
	f.writeRecords(filepath.Join("evidence-"+mode, name), values...)
}

func (f *corpusFixture) writeTestdir(mode, action string) {
	f.t.Helper()
	terminal := map[string]any{
		"schema": corpusTestdirEventSchema, "kind": "terminal", "test": "a.go",
		"skipped": action == "skip", "failed": action == "fail",
	}
	records := []any{
		map[string]any{"schema": corpusTestdirEventSchema, "kind": "phase", "test": "a.go", "phase_kind": "execute", "argv": []string{"go", "run", "a.go"}},
	}
	records = append(records, map[string]any{
		"schema": corpusTestdirEventSchema, "kind": "backend", "test": "a.go", "mode": mode,
		"backend_schema": corpusTestdirBackendSchema, "native_argv": []string{"go", "run", "a.go"},
		"disposition": "check-then-run",
	})
	records = append(records,
		map[string]any{"schema": corpusTestdirEventSchema, "kind": "phase_result", "test": "a.go"},
		terminal)
	f.writeRecords(filepath.Join("evidence-"+mode, "testdir.events.jsonl"), records...)
}

func (f *corpusFixture) writePackage(mode string, tests int) {
	f.t.Helper()
	f.writeRecords(filepath.Join("evidence-"+mode, "packages", "example_p.events.jsonl"), map[string]any{
		"schema": corpusPackageSchema, "kind": "plan", "package": "example/p", "mode": mode,
		"disposition": "run-package-map",
		"native_argv": []string{"p.test", "-test.v"}, "argv": []string{"bashy", "--go-file", "_testmain.go"},
		"enumeration": map[string]int{"tests": tests, "benchmarks": 0, "examples": 0, "fuzz_targets": 0},
	})
}

func (f *corpusFixture) writeRecords(rel string, records ...any) {
	f.t.Helper()
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	for _, record := range records {
		if err := enc.Encode(record); err != nil {
			f.t.Fatal(err)
		}
	}
	f.writeFile(filepath.Join(f.evidence, rel), b.String())
}

func (f *corpusFixture) writeFile(name, contents string) {
	f.t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte(contents), 0o644); err != nil {
		f.t.Fatal(err)
	}
}
