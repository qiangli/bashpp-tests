// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #151; Story: #58; Story-ID: fd3a390ec1f2
//
// partition-emit turns the two corpus evidence lanes into the active product
// manifests. The go test streams remain the authority for root identity,
// output, and terminal verdict; backend events are read only as evidence and
// are never used to manufacture a missing terminal or diagnostic.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type partitionGoRecord struct {
	Action  string `json:"Action"`
	Test    string `json:"Test"`
	Output  string `json:"Output"`
	Package string `json:"Package"`
}

// Keep this local to make partition-emit.go independently buildable, like
// backend-verify.go. Fields not needed by the partition are deliberately
// omitted; encoding/json ignores the rest of the event schema.
type partitionEventRecord struct {
	Kind        string `json:"kind"`
	Test        string `json:"test"`
	Mode        string `json:"mode"`
	Action      string `json:"action"`
	Phase       string `json:"phase"`
	Disposition string `json:"disposition"`
	Exit        int    `json:"exit"`
	Failed      bool   `json:"failed"`
	Skipped     bool   `json:"skipped"`
}

type rootEvidence struct {
	runner string
	modes  map[string]*modeEvidence
}

type modeEvidence struct {
	action string
	lines  []string
}

type manifestRow struct {
	root, mode, firstLine string
}

var evidenceStreams = []struct {
	name, runner string
}{
	{"testdir.go-test.json", "testdir"},
	{"types.go-test.json", "typechecker"},
	{"types2.go-test.json", "typechecker"},
	{"package.go-test.json", "package"},
}

var modes = []string{"interpreted", "compiled"}
var owners = []string{"151", "152", "153", "154", "unclassified"}

func main() {
	interpreted := flag.String("evidence-interpreted", "", "interpreted evidence directory")
	compiled := flag.String("evidence-compiled", "", "compiled evidence directory")
	out := flag.String("out", "docs/upstream-harness", "manifest output directory")
	flag.Parse()

	if *interpreted == "" || *compiled == "" {
		fmt.Fprintln(os.Stderr, "partition-emit: -evidence-interpreted and -evidence-compiled are required")
		os.Exit(1)
	}
	hasFailures, err := emitPartitions(*interpreted, *compiled, *out, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "partition-emit:", err)
		os.Exit(1)
	}
	if hasFailures {
		os.Exit(3)
	}
}

func emitPartitions(interpreted, compiled, out string, stdout io.Writer) (bool, error) {
	roots := map[string]*rootEvidence{}
	for _, lane := range []struct{ mode, dir string }{{"interpreted", interpreted}, {"compiled", compiled}} {
		for _, stream := range evidenceStreams {
			if err := readGoStream(filepath.Join(lane.dir, stream.name), stream.runner, lane.mode, roots); err != nil {
				return false, err
			}
		}
		if err := readEventStream(lane.dir); err != nil {
			return false, err
		}
	}

	rootNames := make([]string, 0, len(roots))
	for root, ev := range roots {
		for _, mode := range modes {
			me := ev.modes[mode]
			if me == nil || me.action == "" {
				return false, fmt.Errorf("root %s has no terminal action in %s mode", root, mode)
			}
		}
		rootNames = append(rootNames, root)
	}
	sort.Strings(rootNames)

	rows := make(map[string][]manifestRow, len(owners))
	runnerCounts := map[string]map[string]int{}
	ownerCounts := map[string]int{}
	for _, root := range rootNames {
		ev := roots[root]
		verdict := rootVerdict(ev)
		if runnerCounts[ev.runner] == nil {
			runnerCounts[ev.runner] = map[string]int{}
		}
		runnerCounts[ev.runner][verdict]++
		if verdict != "FAIL" {
			continue
		}

		owner := "unclassified"
		var failing []manifestRow
		for _, mode := range modes {
			me := ev.modes[mode]
			if me.action != "fail" {
				continue
			}
			line, diagnostic := firstLine(me.lines)
			candidate := classify(line, mode, diagnostic)
			if ownerRank(candidate) < ownerRank(owner) {
				owner = candidate
			}
			failing = append(failing, manifestRow{root, mode, line})
		}
		// PASS/SKIP is still a FAIL verdict by definition. Keep the observed
		// modes without fabricating a diagnostic so the root remains visible.
		if len(failing) == 0 {
			for _, mode := range modes {
				failing = append(failing, manifestRow{root, mode, ""})
			}
		}
		rows[owner] = append(rows[owner], failing...)
		ownerCounts[owner]++
	}

	if err := os.MkdirAll(out, 0o755); err != nil {
		return false, err
	}
	for _, owner := range owners {
		name := manifestName(owner)
		if err := writeManifest(filepath.Join(out, name), rows[owner]); err != nil {
			return false, err
		}
	}
	if err := writeSummary(filepath.Join(out, "active-summary.tsv"), runnerCounts, ownerCounts); err != nil {
		return false, err
	}
	for _, owner := range owners {
		rootsForOwner := uniqueRoots(rows[owner])
		h := sha256.New()
		for _, root := range rootsForOwner {
			fmt.Fprintln(h, root)
		}
		fmt.Fprintf(stdout, "active_%s_rootlist\t%s\n", owner, hex.EncodeToString(h.Sum(nil)))
	}
	return sumVerdict(runnerCounts, "FAIL") != 0, nil
}

func readGoStream(name, runner, mode string, roots map[string]*rootEvidence) error {
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 1<<28)
	lineNo := 0
	for s.Scan() {
		lineNo++
		var rec partitionGoRecord
		if err := json.Unmarshal(s.Bytes(), &rec); err != nil {
			return fmt.Errorf("%s:%d: %w", name, lineNo, err)
		}
		root, leaf := recordRoot(runner, rec)
		if !leaf {
			continue
		}
		re := roots[root]
		if re == nil {
			re = &rootEvidence{runner: runner, modes: map[string]*modeEvidence{}}
			roots[root] = re
		} else if re.runner != runner {
			return fmt.Errorf("root %s appears in both %s and %s streams", root, re.runner, runner)
		}
		me := re.modes[mode]
		if me == nil {
			me = &modeEvidence{}
			re.modes[mode] = me
		}
		if rec.Output != "" {
			me.lines = append(me.lines, splitOutput(rec.Output)...)
		}
		if runner == "package" && rec.Test != "" {
			// Output from an enumerated test body still belongs to the package
			// root, but its terminal is not the package terminal.
			continue
		}
		switch rec.Action {
		case "pass", "fail", "skip":
			if me.action != "" && me.action != rec.Action {
				return fmt.Errorf("%s:%d: conflicting terminal actions for %s: %s and %s", name, lineNo, root, me.action, rec.Action)
			}
			me.action = rec.Action
		}
	}
	if err := s.Err(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

func recordRoot(runner string, rec partitionGoRecord) (string, bool) {
	switch runner {
	case "testdir":
		if !strings.HasPrefix(rec.Test, "Test/") || len(rec.Test) == len("Test/") {
			return "", false
		}
		return "testdir:" + strings.TrimPrefix(rec.Test, "Test/"), true
	case "typechecker":
		// go/types and types2 run the same testdata, so the leaf name alone
		// names two roots; the package keeps them distinct (743 = both).
		if !strings.Contains(rec.Test, "/") || rec.Package == "" {
			return "", false
		}
		return "typechecker:" + rec.Package + "/" + rec.Test, true
	case "package":
		// All output in this stream belongs to its package root. readGoStream
		// separately excludes per-test actions from the package terminal.
		if rec.Package == "" {
			return "", false
		}
		return "package:" + rec.Package, true
	}
	return "", false
}

func splitOutput(output string) []string {
	output = strings.ReplaceAll(output, "\r\n", "\n")
	output = strings.TrimSuffix(output, "\n")
	if output == "" {
		return nil
	}
	return strings.Split(output, "\n")
}

func readEventStream(dir string) error {
	var name string
	for _, base := range []string{"backend.events.jsonl", "backend-events.jsonl", "events.jsonl"} {
		candidate := filepath.Join(dir, base)
		if _, err := os.Stat(candidate); err == nil {
			name = candidate
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if name == "" {
		name = filepath.Join(dir, "backend.events.jsonl")
		return &os.PathError{Op: "open", Path: name, Err: os.ErrNotExist}
	}
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 1<<28)
	lineNo := 0
	for s.Scan() {
		lineNo++
		var rec partitionEventRecord
		if err := json.Unmarshal(s.Bytes(), &rec); err != nil {
			return fmt.Errorf("%s:%d: %w", name, lineNo, err)
		}
	}
	if err := s.Err(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

func firstLine(lines []string) (string, bool) {
	diagnostic := false
	for _, raw := range lines {
		diagnostic = diagnostic || diagnosticLine(normalizeLine(raw))
	}
	fallback := ""
	afterFail := false
	for _, raw := range lines {
		line := normalizeLine(raw)
		if line == "" {
			continue
		}
		if fallback == "" {
			fallback = line
		}
		isDiagnostic := diagnosticLine(line)
		if afterFail || isDiagnostic {
			return line, diagnostic
		}
		if strings.Contains(line, "--- FAIL:") {
			afterFail = true
		}
	}
	return fallback, diagnostic
}

func normalizeLine(line string) string {
	line = strings.TrimSpace(line)
	if strings.HasPrefix(line, "[") {
		if end := strings.Index(line, "] "); end >= 0 && strings.Contains(line[:end], " tests,") {
			line = line[end+2:]
		}
	}
	if i := strings.Index(line, "/goroot/"); i >= 0 {
		line = line[i+len("/goroot/"):]
	}
	return strings.TrimSpace(line)
}

func diagnosticLine(line string) bool {
	return strings.HasPrefix(line, "bashy:") || strings.HasPrefix(line, "gosource:") ||
		strings.HasPrefix(line, "LOWER-") || strings.HasPrefix(line, "BASHPP-") ||
		strings.Contains(line, ": gosource: ")
}

func classify(line, mode string, hasDiagnostic bool) string {
	lower := strings.ToLower(line)
	contains := func(s string) bool { return strings.Contains(lower, strings.ToLower(s)) }
	for _, pattern := range []string{
		"require --check or --go-list", "gosource: unsupported", "could not import internal/",
		"could not import C", "invalid recursive type", "initialization cycle",
		"already declared through", "not an expression", "requires go1.",
		"imported and not used", "cannot use ", "invalid implicit pointer",
		"outside a type constraint",
	} {
		if contains(pattern) {
			return "151"
		}
	}
	for _, pattern := range []string{"LOWER-", "BASHPP-EEXPR", "# bashpp_", "not in std", "relative import paths", "no required module"} {
		if contains(pattern) {
			return "152"
		}
	}
	if mode == "compiled" && contains("unsupported type *ast") {
		return "152"
	}
	for _, pattern := range []string{
		"native slice retention", "dependency-owned writer", "callbacks are unsupported",
		"timed out", "timeout", "incorrect output", "got:", "want:",
		"runtime error", "panic:",
	} {
		if contains(pattern) {
			return "153"
		}
	}
	if contains("exit status") && !hasDiagnostic {
		return "153"
	}
	for _, pattern := range []string{
		"missing error", "unmatched error", "errors: ", "errorcheck", " does not escape",
		"leaking param", "can inline", "live at entry", "devirtualizing", "wrong error",
	} {
		if contains(pattern) {
			return "154"
		}
	}
	return "unclassified"
}

func rootVerdict(ev *rootEvidence) string {
	a, b := ev.modes["interpreted"].action, ev.modes["compiled"].action
	if a == "pass" && b == "pass" {
		return "PASS"
	}
	if a == "skip" && b == "skip" {
		return "SKIP"
	}
	return "FAIL"
}

func ownerRank(owner string) int {
	for i, candidate := range owners {
		if owner == candidate {
			return i
		}
	}
	return len(owners)
}

func manifestName(owner string) string {
	if owner == "unclassified" {
		return "active-unclassified.tsv"
	}
	return "active-" + owner + "-manifest.tsv"
}

func writeManifest(name string, rows []manifestRow) error {
	var b strings.Builder
	b.WriteString("root\tmode\tfirst_line\n")
	for _, row := range rows {
		fmt.Fprintf(&b, "%s\t%s\t%s\n", row.root, row.mode, row.firstLine)
	}
	return os.WriteFile(name, []byte(b.String()), 0o644)
}

func uniqueRoots(rows []manifestRow) []string {
	var out []string
	last := ""
	for _, row := range rows {
		if row.root != last {
			out = append(out, row.root)
			last = row.root
		}
	}
	return out
}

func sumVerdict(counts map[string]map[string]int, verdict string) int {
	total := 0
	for _, c := range counts {
		total += c[verdict]
	}
	return total
}

func writeSummary(name string, runnerCounts map[string]map[string]int, ownerCounts map[string]int) error {
	var b strings.Builder
	b.WriteString("runner\tPASS\tFAIL\tSKIP\ttotal\n")
	for _, runner := range []string{"testdir", "typechecker", "package"} {
		c := runnerCounts[runner]
		fmt.Fprintf(&b, "%s\t%d\t%d\t%d\t%d\n", runner, c["PASS"], c["FAIL"], c["SKIP"], c["PASS"]+c["FAIL"]+c["SKIP"])
	}
	pass, fail, skip := sumVerdict(runnerCounts, "PASS"), sumVerdict(runnerCounts, "FAIL"), sumVerdict(runnerCounts, "SKIP")
	fmt.Fprintf(&b, "total\t%d\t%d\t%d\t%d\n\n", pass, fail, skip, pass+fail+skip)
	b.WriteString("owner\tcount\n")
	for _, owner := range owners {
		fmt.Fprintf(&b, "%s\t%d\n", owner, ownerCounts[owner])
	}
	fmt.Fprintf(&b, "total\t%d\n", fail)
	return os.WriteFile(name, []byte(b.String()), 0o644)
}
