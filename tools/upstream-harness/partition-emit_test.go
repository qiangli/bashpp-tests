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
			"kept.go":  {action: "fail", output: "Bash++ backend unsupported execute phase: module package kept.dir has non-Go inputs [a.s]"},
			"pass.go":  {action: "pass"},
			"skip.go":  {action: "skip"},
			"s151.go":  {action: "fail", output: "../../work/goroot/test/s151.go:4: gosource: unsupported LabeledStmt"},
			"s152.go":  {action: "fail", output: "LOWER-ETYPE: cannot lower expression"},
			"mixed.go": {action: "fail", output: "panic: interpreted failure"},
		},
		"compiled": {
			"kept.go":  {action: "pass"},
			"pass.go":  {action: "pass"},
			"skip.go":  {action: "skip"},
			"s151.go":  {action: "fail", output: "gosource: unsupported RangeStmt"},
			"s152.go":  {action: "fail", output: "# bashpp_fixture\nLOWER-ETYPE: compiled failure"},
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
			"testdir:s152.go\tcompiled\tLOWER-ETYPE: compiled failure\n",
		"active-153-manifest.tsv": "root\tmode\tfirst_line\n" +
			"typechecker:go/types/TestCheck/runtime.go\tinterpreted\tpanic: runtime error: boom\n" +
			"typechecker:go/types/TestCheck/runtime.go\tcompiled\truntime error: boom\n",
		"active-154-manifest.tsv": "root\tmode\tfirst_line\n" +
			"typechecker:go/types/TestCheck/escape.go\tinterpreted\tescape.go:8: missing error \"x does not escape\"\n" +
			"typechecker:go/types/TestCheck/escape.go\tcompiled\tescape.go:8: wrong error\n",
		"active-unclassified.tsv": "root\tmode\tfirst_line\n" +
			"package:example/unclassified\tinterpreted\tmystery product limitation\n",
		"active-retained-manifest.tsv": "root\tmode\tfirst_line\n" +
			"testdir:kept.go\tinterpreted\tBash++ backend unsupported execute phase: module package kept.dir has non-Go inputs [a.s]\n",
		"active-summary.tsv": "runner\tPASS\tFAIL\tSKIP\ttotal\n" +
			"testdir\t1\t4\t1\t6\n" +
			"typechecker\t0\t2\t0\t2\n" +
			"package\t0\t1\t0\t1\n" +
			"total\t1\t7\t1\t9\n\n" +
			"owner\tcount\n151\t1\n152\t2\n153\t1\n154\t1\nunclassified\t1\nretained\t1\ntotal\t7\n",
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
	if lines := strings.Split(strings.TrimSpace(stdout.String()), "\n"); len(lines) != 6 {
		t.Fatalf("stdout has %d digest lines, want 6:\n%s", len(lines), stdout.String())
	}
}

func TestPartitionRuleChanges(t *testing.T) {
	tests := []struct {
		name      string
		lines     []string
		mode      string
		wantLine  string
		wantOwner string
	}{
		{
			name:      "build package header",
			lines:     []string{"# bashpp_s1572", `escape.go:8: missing error "x does not escape"`},
			mode:      "compiled",
			wantLine:  `escape.go:8: missing error "x does not escape"`,
			wantOwner: "154",
		},
		{
			name:      "interpreted bare asmcheck target",
			lines:     []string{"linux/amd64/v1"},
			mode:      "interpreted",
			wantLine:  "linux/amd64/v1",
			wantOwner: "retained",
		},
		{
			name:      "compiled missing opcode",
			lines:     []string{"codegen/x.go:15: linux/amd64/v1: opcode not found: `^ADDQ`"},
			mode:      "compiled",
			wantLine:  "codegen/x.go:15: linux/amd64/v1: opcode not found: `^ADDQ`",
			wantOwner: "152",
		},
		{
			name:      "non-Go inputs",
			lines:     []string{"Bash++ gotest backend: non-Go inputs [a.s]"},
			mode:      "compiled",
			wantLine:  "Bash++ gotest backend: non-Go inputs [a.s]",
			wantOwner: "retained",
		},
		{
			name:      "emitter line directive with column 0",
			lines:     []string{"# bashpp_s1572", "./fixedbugs/issue18149.go:39:36: invalid column number: 0"},
			mode:      "compiled",
			wantLine:  "./fixedbugs/issue18149.go:39:36: invalid column number: 0",
			wantOwner: "152",
		},
		{
			name:      "user line directive not passed through",
			lines:     []string{"src/reflect/value.go:369; want /foo/bar.go:123 (or suffix /foo/bar.go)"},
			mode:      "interpreted",
			wantLine:  "src/reflect/value.go:369; want /foo/bar.go:123 (or suffix /foo/bar.go)",
			wantOwner: "152",
		},
		{
			name:      "asm listing logged before the verdict",
			lines:     []string{"    testdir_test.go:1857: main.Append1<1> STEXT size=117 align=0x0 args=0x8 locals=0x50 funcid=0x0", "    testdir_test.go:1857: \t0x0000 00000 (codegen/append.go:12)\tTEXT\tmain.Append1(SB), ABIInternal, $80-8", "        codegen/append.go:18: linux/amd64/v1: opcode not found: `^.*moveSliceNoCapNoScan\\b`"},
			mode:      "compiled",
			wantLine:  "codegen/append.go:18: linux/amd64/v1: opcode not found: `^.*moveSliceNoCapNoScan\\b`",
			wantOwner: "152",
		},
		{
			name:      "bodyless assembly declaration",
			lines:     []string{"LOWER-EUNSUPPORTED: function declaration without body"},
			mode:      "compiled",
			wantLine:  "LOWER-EUNSUPPORTED: function declaration without body",
			wantOwner: "retained",
		},
		{
			name:      "cgo requires interpreted",
			lines:     []string{"package requires cgo, which this pure-Go shell does not provide"},
			mode:      "interpreted",
			wantLine:  "package requires cgo, which this pure-Go shell does not provide",
			wantOwner: "retained",
		},
		{
			name:      "cgo requires compiled",
			lines:     []string{"package requires cgo, which this pure-Go shell does not provide"},
			mode:      "compiled",
			wantLine:  "package requires cgo, which this pure-Go shell does not provide",
			wantOwner: "retained",
		},
		{
			name:      "unknown import C interpreted",
			lines:     []string{`unknown import path "C"`},
			mode:      "interpreted",
			wantLine:  `unknown import path "C"`,
			wantOwner: "retained",
		},
		{
			name:      "unknown import C compiled",
			lines:     []string{`unknown import path "C"`},
			mode:      "compiled",
			wantLine:  `unknown import path "C"`,
			wantOwner: "retained",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			line, diagnostic := firstLine(tt.lines)
			if line != tt.wantLine {
				t.Fatalf("firstLine = %q, want %q", line, tt.wantLine)
			}
			if owner := classify(line, tt.mode, diagnostic); owner != tt.wantOwner {
				t.Fatalf("classify(%q, %q) = %q, want %q", line, tt.mode, owner, tt.wantOwner)
			}
		})
	}
}

// TestCgoRootWithCrossModeRuntimeFailure verifies that a root with a cgo
// diagnostic (retained) in one mode and a real runtime failure in the other
// mode is assigned to the runtime owner, not retained. ownerRank ensures
// retained never absorbs a real failure in the other mode.
func TestCgoRootWithCrossModeRuntimeFailure(t *testing.T) {
	interpreted, compiled, out := t.TempDir(), t.TempDir(), t.TempDir()

	testdir := map[string]map[string]fixtureVerdict{
		"interpreted": {
			"cgo_cross.go": {action: "fail", output: `unknown import path "C"`},
		},
		"compiled": {
			"cgo_cross.go": {action: "fail", output: "panic: runtime error: nil pointer dereference"},
		},
	}
	for _, lane := range []struct{ mode, dir string }{{"interpreted", interpreted}, {"compiled", compiled}} {
		writeTestdirFixture(t, filepath.Join(lane.dir, "testdir.go-test.json"), testdir[lane.mode])
		writeRecords(t, filepath.Join(lane.dir, "types.go-test.json"))
		writeRecords(t, filepath.Join(lane.dir, "types2.go-test.json"))
		writeRecords(t, filepath.Join(lane.dir, "package.go-test.json"))
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

	// The root must land in 153 (runtime), not retained.
	got, err := os.ReadFile(filepath.Join(out, "active-153-manifest.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "testdir:cgo_cross.go") {
		t.Fatalf("cgo_cross.go not in 153 manifest:\n%s", got)
	}
	retained, err := os.ReadFile(filepath.Join(out, "active-retained-manifest.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(retained), "testdir:cgo_cross.go") {
		t.Fatalf("cgo_cross.go should not be in retained manifest:\n%s", retained)
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
			records = append(records, partitionGoRecord{Action: "output", Test: root, Package: "go/types", Output: v.output + "\n"})
		}
		records = append(records, partitionGoRecord{Action: v.action, Test: root, Package: "go/types"})
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
