// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #151; Story: #58; Story-ID: fd3a390ec1f2
package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestEmitPartitions(t *testing.T) {
	interpreted, compiled, out := t.TempDir(), t.TempDir(), t.TempDir()

	testdir := map[string]map[string]fixtureVerdict{
		"interpreted": {
			"pass.go":  {action: "pass"},
			"skip.go":  {action: "skip"},
			"s151.go":  {action: "fail", output: "../../work/goroot/test/s151.go:4: gosource: unsupported LabeledStmt"},
			"s152.go":  {action: "fail", output: "LOWER-ETYPE: cannot lower expression"},
			"mixed.go": {action: "fail", output: "panic: interpreted failure"},
		},
		"compiled": {
			"pass.go":  {action: "pass"},
			"skip.go":  {action: "skip"},
			"s151.go":  {action: "fail", output: "gosource: unsupported RangeStmt"},
			"s152.go":  {action: "fail", output: "# bashpp_fixture"},
			"mixed.go": {action: "fail", output: "BASHPP-EEXPR: compiled failure"},
		},
	}
	types := map[string]map[string]fixtureVerdict{
		"interpreted": {
			"TestCheck/runtime.go": {action: "fail", output: "panic: runtime error: boom"},
			"TestCheck/escape.go":  {action: "fail", output: "escape.go:8: missing error \"x does not escape\""},
		},
		"compiled": {
			"TestCheck/runtime.go": {action: "fail", output: "runtime error: boom"},
			"TestCheck/escape.go":  {action: "fail", output: "escape.go:8: wrong error"},
		},
	}
	packages := map[string]map[string]fixtureVerdict{
		"interpreted": {"example/unclassified": {action: "fail", output: "mystery product limitation"}},
		"compiled":    {"example/unclassified": {action: "pass"}},
	}

	for _, lane := range []struct{ mode, dir string }{{"interpreted", interpreted}, {"compiled", compiled}} {
		writeTestdirFixture(t, filepath.Join(lane.dir, "testdir.go-test.json"), testdir[lane.mode])
		writeTypesFixture(t, filepath.Join(lane.dir, "types.go-test.json"), types[lane.mode])
		// The two upstream checker implementations share conceptual root IDs;
		// an empty, valid stream proves it is still mandatory input.
		writeRecords(t, filepath.Join(lane.dir, "types2.go-test.json"))
		writePackageFixture(t, filepath.Join(lane.dir, "package.go-test.json"), packages[lane.mode])
		writeRecords(t, filepath.Join(lane.dir, "backend.events.jsonl"), partitionEventRecord{Kind: "terminal", Mode: lane.mode})
	}

	var stdout bytes.Buffer
	hasFailures, err := emitPartitions(interpreted, compiled, out, &stdout)
	if err != nil {
		t.Fatal(err)
	}
	if !hasFailures {
		t.Fatal("emitPartitions reported no failures")
	}

	wantFiles := map[string]string{
		"active-151-manifest.tsv": "root\tmode\tfirst_line\n" +
			"testdir:s151.go\tinterpreted\ttest/s151.go:4: gosource: unsupported LabeledStmt\n" +
			"testdir:s151.go\tcompiled\tgosource: unsupported RangeStmt\n",
		"active-152-manifest.tsv": "root\tmode\tfirst_line\n" +
			"testdir:mixed.go\tinterpreted\tpanic: interpreted failure\n" +
			"testdir:mixed.go\tcompiled\tBASHPP-EEXPR: compiled failure\n" +
			"testdir:s152.go\tinterpreted\tLOWER-ETYPE: cannot lower expression\n" +
			"testdir:s152.go\tcompiled\t# bashpp_fixture\n",
		"active-153-manifest.tsv": "root\tmode\tfirst_line\n" +
			"typechecker:TestCheck/runtime.go\tinterpreted\tpanic: runtime error: boom\n" +
			"typechecker:TestCheck/runtime.go\tcompiled\truntime error: boom\n",
		"active-154-manifest.tsv": "root\tmode\tfirst_line\n" +
			"typechecker:TestCheck/escape.go\tinterpreted\tescape.go:8: missing error \"x does not escape\"\n" +
			"typechecker:TestCheck/escape.go\tcompiled\tescape.go:8: wrong error\n",
		"active-unclassified.tsv": "root\tmode\tfirst_line\n" +
			"package:example/unclassified\tinterpreted\tmystery product limitation\n",
		"active-summary.tsv": "runner\tPASS\tFAIL\tSKIP\ttotal\n" +
			"testdir\t1\t3\t1\t5\n" +
			"typechecker\t0\t2\t0\t2\n" +
			"package\t0\t1\t0\t1\n" +
			"total\t1\t6\t1\t8\n\n" +
			"owner\tcount\n151\t1\n152\t2\n153\t1\n154\t1\nunclassified\t1\ntotal\t6\n",
	}
	for name, want := range wantFiles {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("%s:\n%s\nwant:\n%s", name, got, want)
		}
	}
	if lines := strings.Split(strings.TrimSpace(stdout.String()), "\n"); len(lines) != 5 {
		t.Fatalf("stdout has %d digest lines, want 5:\n%s", len(lines), stdout.String())
	}
}

func TestFirstLineAfterFailAndFallback(t *testing.T) {
	line, diagnostic := firstLine([]string{"=== RUN   Test/example", "--- FAIL: Test/example", "[2 tests, 0 benchmarks] ../../x/goroot/test/example.go: surprising"})
	if line != "test/example.go: surprising" || diagnostic {
		t.Fatalf("firstLine = %q, %v", line, diagnostic)
	}
	line, diagnostic = firstLine([]string{"", "plain fallback"})
	if line != "plain fallback" || diagnostic {
		t.Fatalf("fallback = %q, %v", line, diagnostic)
	}
}

func TestMissingNamedStreamIsInputError(t *testing.T) {
	interpreted, compiled := t.TempDir(), t.TempDir()
	for _, dir := range []string{interpreted, compiled} {
		for _, stream := range evidenceStreams {
			if dir == interpreted && stream.name == "types2.go-test.json" {
				continue
			}
			writeRecords(t, filepath.Join(dir, stream.name))
		}
		writeRecords(t, filepath.Join(dir, "backend.events.jsonl"))
	}
	_, err := emitPartitions(interpreted, compiled, t.TempDir(), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "types2.go-test.json") {
		t.Fatalf("error = %v, want missing stream name", err)
	}
}

type fixtureVerdict struct {
	action, output string
}

func writeTestdirFixture(t *testing.T, name string, roots map[string]fixtureVerdict) {
	t.Helper()
	var records []any
	for _, root := range sortedFixtureRoots(roots) {
		v := roots[root]
		if v.output != "" {
			records = append(records, partitionGoRecord{Action: "output", Test: "Test/" + root, Output: v.output + "\n"})
		}
		records = append(records, partitionGoRecord{Action: v.action, Test: "Test/" + root})
	}
	writeRecords(t, name, records...)
}

func writeTypesFixture(t *testing.T, name string, roots map[string]fixtureVerdict) {
	t.Helper()
	var records []any
	for _, root := range sortedFixtureRoots(roots) {
		v := roots[root]
		if v.output != "" {
			records = append(records, partitionGoRecord{Action: "output", Test: root, Output: v.output + "\n"})
		}
		records = append(records, partitionGoRecord{Action: v.action, Test: root})
	}
	writeRecords(t, name, records...)
}

func writePackageFixture(t *testing.T, name string, roots map[string]fixtureVerdict) {
	t.Helper()
	var records []any
	for _, root := range sortedFixtureRoots(roots) {
		v := roots[root]
		if v.output != "" {
			records = append(records, partitionGoRecord{Action: "output", Package: root, Output: v.output + "\n"})
		}
		records = append(records, partitionGoRecord{Action: v.action, Package: root})
	}
	writeRecords(t, name, records...)
}

func sortedFixtureRoots(roots map[string]fixtureVerdict) []string {
	out := make([]string, 0, len(roots))
	for root := range roots {
		out = append(out, root)
	}
	sort.Strings(out)
	return out
}

func writeRecords(t *testing.T, name string, records ...any) {
	t.Helper()
	f, err := os.Create(name)
	if err != nil {
		t.Fatal(err)
	}
	enc := json.NewEncoder(f)
	for _, record := range records {
		if err := enc.Encode(record); err != nil {
			f.Close()
			t.Fatal(err)
		}
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}
