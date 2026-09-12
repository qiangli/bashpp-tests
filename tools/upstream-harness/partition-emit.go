// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #151; Story: #58; Story-ID: fd3a390ec1f2
// Sprint: #154; Story: S154.0; Story-ID: 4877afd3a207
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
	"regexp"
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
	Kind        string   `json:"kind"`
	Test        string   `json:"test"`
	Mode        string   `json:"mode"`
	Action      string   `json:"action"`
	Phase       string   `json:"phase"`
	Disposition string   `json:"disposition"`
	RecipeFlags []string `json:"recipe_flags"`
	Exit        int      `json:"exit"`
	Failed      bool     `json:"failed"`
	Skipped     bool     `json:"skipped"`
}

// recipeEvidence is what the backend events carry for one root and mode: the
// upstream recipe action and its recipe flags. Partition rules key on these
// and on the verdict shape only, never on expected strings.
type recipeEvidence struct {
	action string
	flags  []string
}

func (r recipeEvidence) errorcheckFamily() bool {
	switch r.action {
	case "errorcheck", "errorcheckdir", "errorcheckandrundir", "errorcheckwithauto":
		return true
	}
	return false
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
	root, mode, firstLine, verdict string
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
var owners = []string{"151", "152", "153", "154", "unclassified", "retained"}

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
	recipes := map[string]map[string]recipeEvidence{}
	for _, lane := range []struct{ mode, dir string }{{"interpreted", interpreted}, {"compiled", compiled}} {
		for _, stream := range evidenceStreams {
			if err := readGoStream(filepath.Join(lane.dir, stream.name), stream.runner, lane.mode, roots); err != nil {
				return false, err
			}
		}
		if err := readEventStream(lane.dir, lane.mode, recipes); err != nil {
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

		owner := "" // no candidate yet; ranks below every owner, retained included
		var failing []manifestRow
		for _, mode := range modes {
			me := ev.modes[mode]
			if me.action != "fail" {
				continue
			}
			line, diagnostic := firstLine(me.lines)
			column := errorCheckVerdictOf(me.lines)
			candidate := classify(line, mode, diagnostic, ev.runner, recipes[root][mode], column.class)
			if ownerRank(candidate) < ownerRank(owner) {
				owner = candidate
			}
			failing = append(failing, manifestRow{root, mode, line, column.column()})
		}
		// PASS/SKIP is still a FAIL verdict by definition. Keep the observed
		// modes without fabricating a diagnostic so the root remains visible.
		if len(failing) == 0 {
			for _, mode := range modes {
				failing = append(failing, manifestRow{root, mode, "", errorCheckVerdictOf(ev.modes[mode].lines).column()})
			}
		}
		if owner == "" {
			owner = "unclassified"
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

// readEventStream reads the backend event lane. It collects, per root and
// mode, the upstream recipe action and recipe flags the backend retained
// (JSON key recipe_flags, as backend-verify.go already declares); events are
// evidence only and never manufacture a terminal or diagnostic.
func readEventStream(dir, mode string, recipes map[string]map[string]recipeEvidence) error {
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
		if rec.Test == "" || rec.Action == "" || (rec.Kind != "phase" && rec.Kind != "backend") {
			continue
		}
		eventMode := rec.Mode
		if eventMode == "" {
			eventMode = mode
		}
		root := "testdir:" + rec.Test
		byMode := recipes[root]
		if byMode == nil {
			byMode = map[string]recipeEvidence{}
			recipes[root] = byMode
		}
		re := byMode[eventMode]
		re.action = rec.Action
		for _, flag := range rec.RecipeFlags {
			seen := false
			for _, have := range re.flags {
				if have == flag {
					seen = true
					break
				}
			}
			if !seen {
				re.flags = append(re.flags, flag)
			}
		}
		byMode[eventMode] = re
	}
	if err := s.Err(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

// The three verdict shapes upstream errorCheck emits into the go-test Output
// stream (testdir_test.go:1226): `<file>:<line>: missing error "<regex>"`,
// "<file>:<line>: no match for `<regex>` in:" followed by tab-indented
// got-lines, and `Unmatched Errors:` followed by the extra diagnostic lines.
// A tab-prefixed line continues the previous error (testdir_test.go:1169).
var (
	missingVerdictRe = regexp.MustCompile(`^([^\s:]+):[0-9]+: missing error "`)
	wordingVerdictRe = regexp.MustCompile(`^[^\s:]+:[0-9]+: no match for `)
	diagnosticPosRe  = regexp.MustCompile(`^([^\s:]+):([0-9]+)(:[0-9]+)?: `)
)

// errorCheckVerdict is one mode's upstream errorCheck verdict, counted from
// the go-test Output lines already collected in modeEvidence.lines. It never
// reads test source or corpus files and never decides a recipe.
type errorCheckVerdict struct {
	missing, wording, extra int
	class                   string
}

func (v errorCheckVerdict) column() string {
	return fmt.Sprintf("missing=%d;wording=%d;extra=%d;class=%s", v.missing, v.wording, v.extra, v.class)
}

// errorCheckVerdictOf classifies one mode's errorCheck verdict shape:
// position (a missing error whose diagnostic surfaced elsewhere in the same
// file), wording (the diagnostic is there, spelled differently),
// multiplicity (only extra diagnostics, every one on a line that also
// matched — the matched sibling is visible in the verbose "gc output:"
// block), missing, extra, or "-" when the row carries no errorCheck verdict
// at all (a runtime or build failure).
func errorCheckVerdictOf(lines []string) errorCheckVerdict {
	v := errorCheckVerdict{}
	missingFiles := map[string]bool{}
	// gcSeen counts diagnostics per base-name:line in the "gc output:" block
	// (the raw compiler output carries full paths; the verdict lines carry
	// upstream's directory-cut short names).
	gcSeen := map[string]int{}
	type entry struct{ file, key string }
	var unmatched []entry
	inUnmatched, inGcOutput := false, false
	for _, raw := range lines {
		content := strings.TrimLeft(raw, " ")
		if strings.HasPrefix(content, "\t") {
			// A tab-prefixed line continues the previous error: wording
			// got-lines and multi-line diagnostics never count as entries.
			continue
		}
		line := strings.TrimSpace(content)
		if strings.HasPrefix(line, "testdir_test.go:") {
			// A new log message: upstream's attribution prefix, with the text
			// after it (or on the following lines).
			inUnmatched, inGcOutput = false, false
			if i := strings.Index(line, ": "); i >= 0 {
				line = strings.TrimSpace(line[i+2:])
			} else {
				continue
			}
		}
		if line == "" {
			continue
		}
		if strings.HasSuffix(line, "gc output:") {
			inUnmatched, inGcOutput = false, true
			continue
		}
		if framingLine(line) {
			inUnmatched, inGcOutput = false, false
			continue
		}
		if inGcOutput {
			if m := diagnosticPosRe.FindStringSubmatch(line); m != nil {
				gcSeen[baseName(m[1])+":"+m[2]]++
			}
			continue
		}
		switch {
		case missingVerdictRe.MatchString(line):
			v.missing++
			missingFiles[missingVerdictRe.FindStringSubmatch(line)[1]] = true
			inUnmatched = false
		case wordingVerdictRe.MatchString(line):
			v.wording++
			inUnmatched = false
		case line == "Unmatched Errors:":
			inUnmatched = true
		case inUnmatched:
			m := diagnosticPosRe.FindStringSubmatch(line)
			if m == nil {
				inUnmatched = false
				continue
			}
			v.extra++
			unmatched = append(unmatched, entry{file: m[1], key: baseName(m[1]) + ":" + m[2]})
		}
	}

	positionHit := false
	allSiblings := len(unmatched) > 0
	for _, e := range unmatched {
		if missingFiles[e.file] {
			positionHit = true
		}
		// The unmatched diagnostic is itself part of the gc output, so a line
		// that also matched shows at least two diagnostics at the position.
		if gcSeen[e.key] < 2 {
			allSiblings = false
		}
	}
	switch {
	case v.missing == 0 && v.wording == 0 && v.extra == 0:
		v.class = "-"
	case v.missing > 0 && positionHit:
		v.class = "position"
	case v.wording > 0:
		v.class = "wording"
	case v.missing > 0 && v.extra == 0:
		v.class = "missing"
	case v.missing == 0 && allSiblings:
		v.class = "multiplicity"
	default:
		v.class = "extra"
	}
	return v
}

func baseName(file string) string {
	return file[strings.LastIndexByte(file, '/')+1:]
}

func exitStatus(line string) bool {
	return strings.HasPrefix(line, "exit status ") && len(line) < 20
}

// framingLine is go test's own narration of a test, never a diagnostic.
func framingLine(line string) bool {
	return strings.HasPrefix(line, "=== ") || strings.HasPrefix(line, "--- ") ||
		strings.HasSuffix(line, "gc output:") ||
		line == "PASS" || line == "FAIL" || strings.HasPrefix(line, "ok  ") ||
		strings.HasPrefix(line, "FAIL\t")
}

func asmListingLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	if strings.HasPrefix(trimmed, "testdir_test.go:") {
		if i := strings.Index(trimmed, ": "); i >= 0 {
			trimmed = strings.TrimSpace(trimmed[i+2:])
		}
	}
	return strings.Contains(line, " STEXT ") || strings.HasPrefix(trimmed, "0x") ||
		strings.HasPrefix(trimmed, "rel ") || strings.Contains(trimmed, " SRODATA ") ||
		strings.Contains(trimmed, " SDWARF") || strings.HasPrefix(trimmed, "gclocals·") ||
		strings.HasPrefix(trimmed, "type:") || asmPositionTail.MatchString(trimmed)
}

// asmPositionTail is what remains of a listing line once normalizeLine has
// cut everything up to the corpus path: "test/codegen/x.go:11)".
var asmPositionTail = regexp.MustCompile(`^[^ ]*\.go:[0-9]+\)`)

func buildPackageHeader(line string) bool {
	fields := strings.Fields(line)
	return len(fields) == 2 && fields[0] == "#"
}

func firstLine(lines []string) (string, bool) {
	diagnostic := false
	for _, raw := range lines {
		diagnostic = diagnostic || diagnosticLine(normalizeLine(raw))
	}
	fallback := ""
	firstText := ""
	afterFail := false
	for _, raw := range lines {
		line := normalizeLine(raw)
		if line == "" || framingLine(line) {
			if strings.Contains(line, "--- FAIL:") {
				afterFail = true
			}
			continue
		}
		// upstream's own attribution prefix ("testdir_test.go:153: ") is not
		// the diagnostic; the text after it is.
		if strings.HasPrefix(line, "testdir_test.go:") {
			if i := strings.Index(line, ": "); i >= 0 {
				line = strings.TrimSpace(line[i+2:])
			} else {
				// a bare "testdir_test.go:153:" attribution with the text on
				// the following lines
				continue
			}
			if line == "" {
				continue
			}
		}
		// The go command prefixes compiler output with "# <package>". It is
		// build framing, not the first diagnostic used to partition the root.
		if buildPackageHeader(line) {
			continue
		}
		// Upstream asmCheck logs the whole -S listing before its verdicts;
		// a listing line is never the diagnostic that partitions the root.
		if asmListingLine(line) || asmListingLine(raw) {
			continue
		}
		// "exit status N" is upstream's summary of the command; the
		// command's own diagnostic follows it, indented. Prefer that.
		if exitStatus(line) {
			if fallback == "" {
				fallback = line
			}
			continue
		}
		if firstText == "" {
			firstText = line
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
	if firstText != "" {
		return firstText, diagnostic
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
	// Strip the run's GOROOT prefix from a LEADING path only. A goroot path
	// quoted inside a message ("could not import C (go list failed using
	// … /goroot/bin/go …)") is not the diagnostic's position, and cutting
	// there would discard the diagnostic itself.
	if i := strings.Index(line, "/goroot/"); i >= 0 && !strings.Contains(line[:i], " ") {
		line = line[i+len("/goroot/"):]
	}
	return strings.TrimSpace(line)
}

func diagnosticLine(line string) bool {
	return strings.HasPrefix(line, "bashy:") || strings.HasPrefix(line, "gosource:") ||
		strings.HasPrefix(line, "LOWER-") || strings.HasPrefix(line, "BASHPP-") ||
		strings.Contains(line, ": gosource: ") || strings.Contains(line, ": BASHPP-") ||
		strings.Contains(line, ": LOWER-")
}

// optimizerDiagnosticFlags reports whether the recipe asks the compiler for
// optimizer diagnostics: -m (any -m… form), -live, or a -d= debug
// flag — compiler artifacts the check interface cannot produce.
func optimizerDiagnosticFlags(flags []string) bool {
	for _, flag := range flags {
		if strings.HasPrefix(flag, "-m") || strings.HasPrefix(flag, "-live") || debugDiagnosticFlag(flag) {
			return true
		}
	}
	return false
}

func debugDiagnosticFlags(flags []string) bool {
	for _, flag := range flags {
		if debugDiagnosticFlag(flag) {
			return true
		}
	}
	return false
}

// debugDiagnosticFlag reports a -d= flag that produces diagnostics the
// expectations depend on (-d=wb, -d=nil, -d=ssa/…/debug=N, -d=escapedebug=1,
// …). Two -d= flags carry no expectation and never retain a row:
// -d=ssa/check/on, which upstream testdir_test.go appends to EVERY
// errorcheck compile, and -d=panic, which only makes gc panic on its first
// error (the diagnostic itself is the ordinary one).
func debugDiagnosticFlag(flag string) bool {
	if !strings.HasPrefix(flag, "-d=") {
		return false
	}
	for _, option := range strings.Split(strings.TrimPrefix(flag, "-d="), ",") {
		switch option {
		case "", "ssa/check/on", "panic":
			continue
		}
		return true
	}
	return false
}

var expectedArgumentsRe = regexp.MustCompile(`expected [0-9]+ argument`)

// runtimeShape recognizes the run-family failure shapes that carry no
// errorCheck verdict: an output mismatch or a crash of the program itself.
func runtimeShape(line string) bool {
	lower := strings.ToLower(line)
	return strings.Contains(lower, "output does not match") || strings.Contains(lower, "panic:") ||
		strings.Contains(lower, "unexpected fault") || expectedArgumentsRe.MatchString(lower)
}

// classify names the owner of one failing manifest row. The S154.0 rules key
// on the recipe flags and verdict shape only, never on expected strings; the
// remaining rules are the first-line substring partition (classifyLine).
func classify(line, mode string, hasDiagnostic bool, runner string, recipe recipeEvidence, verdictClass string) string {
	// D1: optimizer diagnostics are a compiler artifact; the check interface
	// has no inliner, escape analysis, or SSA — the same shape as interpreted
	// asmcheck. A compiled -d= row is retained too (the seam drops -d= as
	// evidence only, see the backend's compileDeviations); a compiled
	// -m/-live row with a verdict is a lowering row (152, below). As with
	// retained generally, a real failure in the other mode still wins
	// (ownerRank).
	if recipe.errorcheckFamily() {
		if mode == "interpreted" && optimizerDiagnosticFlags(recipe.flags) {
			return "retained"
		}
		if mode == "compiled" && debugDiagnosticFlags(recipe.flags) {
			return "retained"
		}
		// A compiled -m/-live row that carries an errorCheck verdict is the
		// generated module's optimizer notes compared against the original's.
		// Sprint 154 measured every such row (mclass-r0, 13 roots): no diff is
		// a diagnostic-policy defect — the notes differ by //line POSITION
		// (the source map is statement-granular; gc attributes escape notes to
		// the expression's own line inside a multi-line statement) or by the
		// emitted SYMBOL NAME (__gosource_pkg_N_F, __bppN_…), and a row whose
		// transpile failed is already retained above. Both mechanisms are the
		// lowering's (152.4 source map / 152.1 fidelity), so the row moves
		// there by this rule rather than in place.
		if mode == "compiled" && optimizerDiagnosticFlags(recipe.flags) && verdictClass != "-" {
			return "152"
		}
	}
	// D2: diagnostic multiplicity (a tab-continuation of a multi-part
	// types.Error, %q-escaped as \t) and the missing assert/trace test
	// builtins are 154 fidelity rows, before the generic
	// "no error expected" -> 151 rule in classifyLine. Other
	// "no error expected" rows stay 151; "could not import C" still falls to
	// retained.
	if runner == "typechecker" {
		for _, pattern := range []string{`no error expected: "\t`, `no error expected: "undefined: assert"`, `no error expected: "undefined: trace"`} {
			if strings.Contains(line, pattern) {
				return "154"
			}
		}
	}
	// A run/errorcheckoutput row with no errorCheck verdict and a runtime
	// shape is a 153 row; the 154 substring rules in classifyLine
	// ("expected ", "errorcheck", "wrong error") must not catch program
	// output.
	if (recipe.action == "run" || recipe.action == "errorcheckoutput") && verdictClass == "-" && runtimeShape(line) {
		return "153"
	}
	owner := classifyLine(line, mode, hasDiagnostic)
	// An unclassified row that still carries an errorCheck verdict of any
	// class is a diagnostic-fidelity row.
	if owner == "unclassified" && verdictClass != "-" {
		return "154"
	}
	return owner
}

func classifyLine(line, mode string, hasDiagnostic bool) string {
	lower := strings.ToLower(line)
	contains := func(s string) bool { return strings.Contains(lower, strings.ToLower(s)) }
	// BASHPP-E* codes are the interpreter's evaluator diagnostics in
	// interpreted mode (151); in compiled mode the same prefix is the lowering
	// (152), handled below.
	if mode == "interpreted" && contains("BASHPP-E") {
		return "151"
	}
	for _, pattern := range []string{"declared by both", "redeclared in this block", "computed call runtime"} {
		if contains(pattern) {
			return "151"
		}
	}
	if contains("dependency transport") {
		return "153"
	}
	// Measured on the Barrier A evidence (frozen Sprint 150 candidate).
	for _, pattern := range []string{
		"no error expected", "compilation succeeded unexpectedly", "invalid select case",
		"requires one result", "redeclared in this session", "unknown imported symbol or method",
		"has no method", "called using nil", "is not a structured value",
	} {
		if contains(pattern) {
			return "151"
		}
	}
	// Parser/wording diagnostics on errorcheck roots: the expected error is
	// there, spelled differently — diagnostic fidelity.
	for _, pattern := range []string{
		"expected ", "found '", "missing ',' ", "duplicate case", "not allowed in",
		"unknown escape", "missing return", "unexpected ", "syntax error",
	} {
		if contains(pattern) {
			return "154"
		}
	}
	if mode == "interpreted" &&
		((asmcheckTarget(lower) && !contains("opcode not found") && !contains("wrong number of opcodes")) ||
			contains("assembly is a compiler artifact") || contains("interpreted mode has no asmcheck meaning")) {
		return "retained"
	}
	for _, pattern := range []string{"opcode not found", "linux/amd64/v", "linux/386", "linux/arm64"} {
		if contains(pattern) {
			return "152"
		}
	}
	// cgo roots: the product declares no cgo support. These patterns appear
	// when a test imports "C" or requires cgo. Placed before the 153 block
	// (which contains the shorter "requires cgo") so the specific cgo-root
	// messages are classified as retained; ownerRank ensures a real failure
	// in the other mode always wins.
	//
	// NOTE: three both-mode `bin/go (GOROOT=…): exit status 1` rows
	// (fixedbugs/issue34968.go, issue36705.go, issue47227.go — `//go:build cgo`
	// go-run recipes) are NOT covered by this rule until their compiled stderr
	// is read; do not classify them by name.
	for _, pattern := range []string{
		"package requires cgo, which this pure-Go shell does not provide",
		`unknown import path "C"`,
		// The typechecker lanes carry the go-list stderr JSON-escaped, so
		// the same message arrives as \"C\".
		`unknown import path \"C\"`,
		// The checker's own refusal of import "C" (both modes).
		"could not import C",
	} {
		if contains(pattern) {
			return "retained"
		}
	}
	for _, pattern := range []string{
		"unregistered bridge type", "unregistered nil bridge type", "build dependency bridge",
		// Sprint 153 bridge value-transport refusals (writeback and mutation
		// policy): runtime rows of the dependency bridge, never a checker verdict.
		"invalid native slice writeback", "dependency mutation of interpreter-owned references",
		// The interpreter's own recursion bottoming out on the Go stack: a
		// runtime outcome of the tree walker (S153 PERF.md), never a checker verdict.
		"goroutine stack exceeds",
		"output should be empty", "output does not match", "instead saw",
		"scalar call interrupted", "original callback signature", "retained original function callbacks",
	} {
		if contains(pattern) {
			return "153"
		}
	}
	for _, pattern := range []string{
		"require --check or --go-list", "gosource: unsupported", "could not import internal/",
		"invalid recursive type", "initialization cycle",
		"already declared through", "not an expression", "requires go1.",
		"imported and not used", "cannot use ", "invalid implicit pointer",
		"outside a type constraint", "unknown field ",
	} {
		if contains(pattern) {
			return "151"
		}
	}
	for _, pattern := range []string{"non-Go inputs", "is not a Go source file", "function declaration without body"} {
		if contains(pattern) {
			return "retained"
		}
	}
	// Source-map rows (152.4): the emitter's own //line directive is invalid
	// (column 0 when the input carries user line directives) or a user
	// //line did not pass through to the reported position.
	for _, pattern := range []string{"invalid column number", "invalid line number", "(or suffix /"} {
		if contains(pattern) {
			return "152"
		}
	}
	for _, pattern := range []string{"LOWER-", "BASHPP-EEXPR", "# bashpp_", "not in std", "relative import paths", "no required module", "non-Go inputs"} {
		if contains(pattern) {
			return "152"
		}
	}
	if mode == "compiled" && contains("unsupported type *ast") {
		return "152"
	}
	for _, pattern := range []string{
		"native slice retention", "dependency-owned writer", "callbacks are unsupported",
		"timed out", "timeout", "exceeded time limit", "incorrect output", "got:", "want:",
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

func asmcheckTarget(line string) bool {
	return strings.HasPrefix(line, "linux/amd64/v") ||
		line == "linux/386" || strings.HasPrefix(line, "linux/386/v") ||
		line == "linux/arm64" || strings.HasPrefix(line, "linux/arm64/v")
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
	// retained ranks last: a root is retained only when NO mode has a real
	// failure. An unclassified failure is still a failure, so it outranks
	// retained even though retained is appended after it in the stable
	// manifest/summary output order.
	if owner == "retained" {
		return len(owners)
	}
	for i, candidate := range owners {
		if owner == candidate {
			return i
		}
	}
	return len(owners) + 1
}

func manifestName(owner string) string {
	if owner == "unclassified" {
		return "active-unclassified.tsv"
	}
	return "active-" + owner + "-manifest.tsv"
}

func writeManifest(name string, rows []manifestRow) error {
	var b strings.Builder
	b.WriteString("root\tmode\tfirst_line\tverdict\n")
	for _, row := range rows {
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\n", row.root, row.mode, row.firstLine, row.verdict)
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
