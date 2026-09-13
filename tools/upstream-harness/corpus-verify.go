// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #155; Story: S155.7; Story-ID: e6c82be4a112
//
// corpus-verify is a read-only observer of one corpus-gate.sh evidence tree.
// It assumes the gate's three evidence-{native,interpreted,compiled}
// directories contain go test -json streams named testdir.go-test.json,
// types2.go-test.json, types.go-test.json and package.go-test.json. Product
// lanes additionally contain testdir.events.jsonl, types2.events.jsonl,
// types.events.jsonl and one packages/*.events.jsonl plan stream per package.
// Testdir terminal records use upstream-testdir-event/v1; a phase is known to
// have used the backend only when it has a corresponding kind=backend record,
// whose native_argv is evidence of the displaced command, not an execution.
// Package plans distinguish the displaced native_argv from the executed argv.
// Types records name both fixture leaves and top-level checker-API tests. Only
// fixture leaves are corpus roots; calls belonging to a top-level terminal are
// therefore evidence, but not an extra or duplicate root. In Barrier B the six
// top-level IDs in each checker package are TestIndexRepresentability,
// TestIssue43124, TestIssue47243_TypedRHS, TestIssue59944, TestLongConstants and
// TestManual. TestIssue43124 makes three checker calls; all are covered by its
// one Go terminal and none is a duplicate corpus-root ID.
//
// The expected Barrier B violation is deliberately not waived here: 156
// checker-API unit-test leaves have a Go terminal but no types-backend record in
// either product lane. Each absent record means the tested source was executed
// natively, so the observer reports all 312 executions and the aggregate
// native-tested-source count until S155.11 reclassifies those roots.
//
// The observer never reads test source, directives, corpus matrices or
// partition manifests, and never makes a recipe or applicability decision. The
// read manifest includes the expected-SKIP input as @expect-skips; its own
// output is necessarily excluded to avoid a self-referential digest.
package main

import (
	"bufio"
	"bytes"
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

const (
	corpusTestdirEventSchema   = "bashpp-tests/upstream-testdir-event/v1"
	corpusTestdirBackendSchema = "bashpp-tests/upstream-testdir-backend/v1"
	corpusPackageSchema        = "bashpp-tests/upstream-gotest-backend/v1"
)

var corpusModes = []string{"native", "interpreted", "compiled"}
var corpusRunners = []string{"testdir", "typechecker", "package"}

type corpusConfig struct {
	evidence    string
	expectRoots int
	expectSkips string
	manifest    string
}

type corpusGoEvent struct {
	Action  string `json:"Action"`
	Package string `json:"Package"`
	Test    string `json:"Test"`
}

type corpusStreamRecord struct {
	Schema        string   `json:"schema"`
	Kind          string   `json:"kind"`
	Test          string   `json:"test"`
	Mode          string   `json:"mode"`
	BackendSchema string   `json:"backend_schema"`
	PhaseKind     string   `json:"phase_kind"`
	Phase         string   `json:"phase"`
	CompileInputs []string `json:"compile_inputs"`
	NativeArgv    []string `json:"native_argv"`
	Argv          []string `json:"argv"`
	Disposition   string   `json:"disposition"`
	Skipped       bool     `json:"skipped"`
	Failed        bool     `json:"failed"`
	// Package is a string in package-plan streams and an object containing
	// base/path in testdir phase streams. Keep the union raw and decode it in
	// the reader that owns the stream.
	Package     json.RawMessage   `json:"package"`
	PackageMap  *corpusPackageMap `json:"package_map"`
	Enumeration struct {
		Tests       int `json:"Tests"`
		Benchmarks  int `json:"Benchmarks"`
		Examples    int `json:"Examples"`
		FuzzTargets int `json:"fuzz_targets"`
	} `json:"enumeration"`
}

type corpusPackageMap struct {
	Base string `json:"base"`
	Path string `json:"path"`
}

type corpusManifestEntry struct {
	path string
	sum  string
}

type corpusObserver struct {
	cfg        corpusConfig
	root       string
	states     map[string]map[string]string
	violations []string
	manifest   []corpusManifestEntry
	nativeExec int
	// allTerminals includes top-level checker-API terminals. states contains
	// only fixture leaves, which are the corpus roots reported by this observer.
	allTerminals map[string]map[string]bool
}

func main() {
	evidence := flag.String("evidence", "", "one corpus-gate.sh evidence directory")
	expectRoots := flag.Int("expect-roots", 3651, "expected unique corpus root count")
	expectSkips := flag.String("expect-skips", "", "sorted expected root IDs, one per line")
	manifest := flag.String("manifest", "", "write or verify the sorted SHA-256 read manifest")
	flag.Parse()

	cfg := corpusConfig{*evidence, *expectRoots, *expectSkips, *manifest}
	if code := verifyCorpus(cfg, os.Stdout, os.Stderr); code != 0 {
		os.Exit(code)
	}
}

func verifyCorpus(cfg corpusConfig, stdout, stderr io.Writer) int {
	o := &corpusObserver{
		cfg: cfg, states: make(map[string]map[string]string),
		allTerminals: make(map[string]map[string]bool),
	}
	if cfg.evidence == "" {
		o.violate("--evidence is required")
	} else if resolved, err := filepath.EvalSymlinks(cfg.evidence); err != nil {
		o.violate("evidence directory: %v", err)
	} else {
		o.root = resolved
	}
	if cfg.expectRoots < 0 {
		o.violate("--expect-roots must be non-negative")
	}
	if cfg.expectSkips == "" {
		o.violate("--expect-skips is required")
	}
	if cfg.manifest == "" {
		o.violate("--manifest is required")
	}

	if o.root != "" {
		for _, mode := range corpusModes {
			o.readLane(mode)
		}
		o.checkRoots()
		o.checkSkips()
	}

	sort.Slice(o.manifest, func(i, j int) bool { return o.manifest[i].path < o.manifest[j].path })
	manifestBytes := o.manifestBytes()
	o.checkOrWriteManifest(manifestBytes)
	o.printReport(stdout)
	sort.Strings(o.violations)
	for _, violation := range o.violations {
		fmt.Fprintf(stderr, "VIOLATION\t%s\n", violation)
	}
	if len(o.violations) != 0 {
		return 1
	}
	return 0
}

func (o *corpusObserver) readLane(mode string) {
	dir := filepath.Join(o.root, "evidence-"+mode)
	o.readTerminalStream(mode, "testdir", filepath.Join(dir, "testdir.go-test.json"), "")
	o.readTerminalStream(mode, "typechecker", filepath.Join(dir, "types2.go-test.json"), "cmd/compile/internal/types2")
	o.readTerminalStream(mode, "typechecker", filepath.Join(dir, "types.go-test.json"), "go/types")
	o.readTerminalStream(mode, "package", filepath.Join(dir, "package.go-test.json"), "")
	if mode == "native" {
		return
	}
	o.readTestdirRecords(mode, filepath.Join(dir, "testdir.events.jsonl"))
	o.readTypesRecords(mode, filepath.Join(dir, "types2.events.jsonl"), "cmd/compile/internal/types2")
	o.readTypesRecords(mode, filepath.Join(dir, "types.events.jsonl"), "go/types")
	packagesDir := filepath.Join(dir, "packages")
	entries, err := os.ReadDir(packagesDir)
	if err != nil {
		o.violate("%s package event directory: %v", mode, err)
		return
	}
	seen := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".events.jsonl") {
			continue
		}
		seen++
		o.readPackageRecords(mode, filepath.Join(packagesDir, entry.Name()))
	}
	if seen == 0 {
		o.violate("%s package event directory has no *.events.jsonl streams", mode)
	}
}

func (o *corpusObserver) readTerminalStream(mode, runner, name, typePackage string) {
	data, ok := o.readEvidence(name)
	if !ok {
		return
	}
	terminals := make(map[string][]string)
	s := bufio.NewScanner(bytes.NewReader(data))
	s.Buffer(make([]byte, 1<<20), 1<<28)
	line := 0
	for s.Scan() {
		line++
		var ev corpusGoEvent
		if err := json.Unmarshal(s.Bytes(), &ev); err != nil {
			o.violate("%s:%d: invalid Go test JSON: %v", o.rel(name), line, err)
			continue
		}
		if ev.Action != "pass" && ev.Action != "fail" && ev.Action != "skip" {
			continue
		}
		var id string
		switch runner {
		case "testdir":
			if !strings.HasPrefix(ev.Test, "Test/") {
				continue
			}
			id = "testdir:" + strings.TrimPrefix(ev.Test, "Test/")
		case "typechecker":
			if ev.Test == "" {
				continue
			}
			if ev.Package != typePackage {
				o.violate("%s:%d: typechecker package is %q, want %q", o.rel(name), line, ev.Package, typePackage)
				continue
			}
			id = "typechecker:" + typePackage + "/" + ev.Test
			// Top-level tests are not corpus roots, but their terminals explain
			// checker calls made outside a fixture leaf.
			o.noteTerminal(id, mode)
			if !strings.Contains(ev.Test, "/") {
				continue
			}
		case "package":
			if ev.Test != "" || ev.Package == "" {
				continue
			}
			id = "package:" + ev.Package
		}
		terminals[id] = append(terminals[id], strings.ToUpper(ev.Action))
	}
	if err := s.Err(); err != nil {
		o.violate("%s: read: %v", o.rel(name), err)
	}

	// Testdir and typechecker streams contain grouping terminals. A leaf is a
	// terminal whose test name is not the slash-prefix of another terminal.
	for id, actions := range terminals {
		o.noteTerminal(id, mode)
		if runner != "package" {
			prefix := id + "/"
			parent := false
			for other := range terminals {
				if strings.HasPrefix(other, prefix) {
					parent = true
					break
				}
			}
			if parent {
				continue
			}
		}
		if len(actions) != 1 {
			o.violate("duplicate ID %s in %s %s terminal stream (%d terminals)", id, runner, mode, len(actions))
			continue
		}
		o.addState(id, mode, actions[0])
	}
}

func (o *corpusObserver) readTestdirRecords(mode, name string) {
	data, ok := o.readEvidence(name)
	if !ok {
		return
	}
	type accounting struct {
		phases, backends, results map[string]int
		pending                   []string
	}
	byTest := make(map[string]*accounting)
	terminals := make(map[string]string)
	o.scanRecords(name, data, func(rec corpusStreamRecord, line int) {
		if rec.Schema != corpusTestdirEventSchema {
			o.violate("%s:%d: testdir event schema %q", o.rel(name), line, rec.Schema)
		}
		id := "testdir:" + rec.Test
		counts := byTest[rec.Test]
		if counts == nil {
			counts = &accounting{
				phases: make(map[string]int), backends: make(map[string]int),
				results: make(map[string]int),
			}
			byTest[rec.Test] = counts
		}
		switch rec.Kind {
		case "phase":
			key := o.testdirAccountingKey(name, line, rec, false)
			counts.phases[key]++
			counts.pending = append(counts.pending, key)
		case "backend":
			key := o.testdirAccountingKey(name, line, rec, true)
			counts.backends[key]++
			if rec.BackendSchema != corpusTestdirBackendSchema || rec.Mode != mode || rec.Disposition == "" || len(rec.NativeArgv) == 0 {
				o.violate("%s:%d: incomplete %s backend record for %s", o.rel(name), line, mode, id)
			}
			if len(rec.Argv) != 0 && len(rec.NativeArgv) != 0 && rec.Argv[0] == rec.NativeArgv[0] {
				o.nativeExec++
				o.violate("%s %s backend record executed native argv[0] %q", mode, id, rec.Argv[0])
			}
		case "phase_result":
			if len(counts.pending) == 0 {
				o.violate("%s:%d: %s has a phase result without a preceding phase", o.rel(name), line, id)
				break
			}
			key := counts.pending[0]
			counts.pending = counts.pending[1:]
			counts.results[key]++
		case "terminal":
			state := "PASS"
			if rec.Skipped && rec.Failed {
				o.violate("%s:%d: terminal %s is both skipped and failed", o.rel(name), line, id)
			} else if rec.Skipped {
				state = "SKIP"
			} else if rec.Failed {
				state = "FAIL"
			}
			if _, dup := terminals[id]; dup {
				o.violate("duplicate ID %s in testdir %s event terminals", id, mode)
			}
			terminals[id] = state
		}
	})
	for test, counts := range byTest {
		id := "testdir:" + test
		keys := accountingKeys(counts.phases, counts.backends, counts.results)
		for _, key := range keys {
			phases, backends, results := counts.phases[key], counts.backends[key], counts.results[key]
			shape := displayAccountingKey(key)
			if phases != results {
				o.violate("%s %s %s has %d phase records and %d phase results", mode, id, shape, phases, results)
			}
			if phases > backends {
				n := phases - backends
				o.nativeExec += n
				o.violate("%s %s %s has %d executed phase(s) without a backend disposition", mode, id, shape, n)
			} else if backends > phases {
				o.violate("%s %s %s has %d backend dispositions for %d phases", mode, id, shape, backends, phases)
			}
		}
	}
	for id, want := range o.states {
		state, exists := want[mode]
		if !strings.HasPrefix(id, "testdir:") || !exists {
			continue
		}
		got, exists := terminals[id]
		if !exists {
			o.violate("%s lacks a testdir terminal event for %s", mode, id)
		} else if got != state {
			o.violate("%s testdir terminal event for %s is %s, Go stream is %s", mode, id, got, state)
		}
	}
	for id := range terminals {
		if o.states[id] == nil || o.states[id][mode] == "" {
			o.violate("%s testdir terminal event %s has no Go terminal", mode, id)
		}
	}
}

func (o *corpusObserver) readTypesRecords(mode, name, pkg string) {
	data, ok := o.readEvidence(name)
	if !ok {
		return
	}
	seen := make(map[string]int)
	o.scanRecords(name, data, func(rec corpusStreamRecord, line int) {
		id := "typechecker:" + pkg + "/" + rec.Test
		if rec.Kind != "types-backend" || rec.Test == "" || len(rec.Argv) == 0 {
			o.violate("%s:%d: incomplete types-backend record", o.rel(name), line)
			return
		}
		seen[id]++
	})
	for id, modes := range o.states {
		if !strings.HasPrefix(id, "typechecker:"+pkg+"/") || modes[mode] == "" {
			continue
		}
		if modes[mode] == "SKIP" {
			if seen[id] != 0 {
				o.violate("%s skipped root %s has a types-backend execution", mode, id)
			}
			continue
		}
		if seen[id] == 0 {
			o.nativeExec++
			o.violate("%s %s has a terminal but no types-backend execution", mode, id)
		} else if seen[id] > 1 {
			o.violate("duplicate ID %s in typechecker %s events", id, mode)
		}
	}
	for id := range seen {
		// Go's JSON stream has terminals for top-level checker API tests as well
		// as fixture leaves. A top-level test may call the checker zero, one or
		// several times, but is not a corpus root and must not be folded into
		// leaf accounting.
		if !o.allTerminals[id][mode] {
			o.violate("%s types-backend execution %s has no Go terminal", mode, id)
		}
	}
}

func (o *corpusObserver) readPackageRecords(mode, name string) {
	data, ok := o.readEvidence(name)
	if !ok {
		return
	}
	o.scanRecords(name, data, func(rec corpusStreamRecord, line int) {
		pkg, err := decodeString(rec.Package)
		id := "package:" + pkg
		if err != nil || rec.Schema != corpusPackageSchema || rec.Kind != "plan" || pkg == "" || rec.Mode != mode || rec.Disposition == "" {
			o.violate("%s:%d: incomplete %s package plan", o.rel(name), line, mode)
			return
		}
		if rec.Enumeration.Tests+rec.Enumeration.Benchmarks+rec.Enumeration.Examples+rec.Enumeration.FuzzTargets == 0 {
			o.violate("%s %s has zero enumerated test bodies", mode, id)
		}
		if len(rec.NativeArgv) == 0 {
			o.violate("%s %s lacks the displaced native_argv", mode, id)
		} else if len(rec.Argv) != 0 && rec.NativeArgv[0] == rec.Argv[0] {
			o.nativeExec++
			o.violate("%s %s executed the native test binary %q", mode, id, rec.Argv[0])
		} else if len(rec.Argv) == 0 && rec.Disposition != "unsupported" && rec.Disposition != "configuration-error" {
			o.violate("%s %s lacks the executed backend argv", mode, id)
		}
		modes := o.states[id]
		if modes == nil || modes[mode] == "" {
			o.violate("%s package plan %s has no package terminal", mode, id)
			return
		}
		key := "@package-plan:" + mode
		if modes[key] != "" {
			o.violate("duplicate ID %s in package %s events", id, mode)
		}
		modes[key] = o.rel(name)
	})
}

// testdirAccountingKey identifies one concrete command planned by an upstream
// root. Directory recipes reuse phase names (for example, "compile") for each
// package, so a phase-name counter aliases distinct executions. Phase records
// carry package; backend records carry the same identity in package_map. Both
// also carry the exact compile inputs. A phase_result has no identity fields,
// and is assigned to the preceding still-pending phase of the same root, which
// is the ordering contract of planStep.done in the instrumented runner.
func (o *corpusObserver) testdirAccountingKey(name string, line int, rec corpusStreamRecord, backend bool) string {
	phase := rec.PhaseKind
	pkg := ""
	if backend {
		phase = rec.Phase
		// A runindir execute backend carries go-list package resolution in
		// package_map even though the upstream execute phase has no package
		// identity. Package identity distinguishes only the repeated compile
		// phases of directory recipes.
		if phase == "compile" && rec.PackageMap != nil {
			pkg = rec.PackageMap.Base + "\x1f" + rec.PackageMap.Path
		}
	} else if phase == "compile" && len(rec.Package) != 0 && string(rec.Package) != "null" {
		var identity corpusPackageMap
		if err := json.Unmarshal(rec.Package, &identity); err != nil {
			o.violate("%s:%d: testdir phase package is not an object: %v", o.rel(name), line, err)
		} else {
			pkg = identity.Base + "\x1f" + identity.Path
		}
	}
	return phase + "\x00" + pkg + "\x00" + strings.Join(rec.CompileInputs, "\x1f")
}

func accountingKeys(groups ...map[string]int) []string {
	set := make(map[string]bool)
	for _, group := range groups {
		for key := range group {
			set[key] = true
		}
	}
	keys := make([]string, 0, len(set))
	for key := range set {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func displayAccountingKey(key string) string {
	parts := strings.SplitN(key, "\x00", 3)
	if len(parts) != 3 {
		return fmt.Sprintf("record=%q", key)
	}
	pkg := strings.ReplaceAll(parts[1], "\x1f", "/")
	inputs := strings.ReplaceAll(parts[2], "\x1f", ",")
	return fmt.Sprintf("phase=%q package=%q inputs=[%s]", parts[0], pkg, inputs)
}

func decodeString(raw json.RawMessage) (string, error) {
	if len(raw) == 0 {
		return "", nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", err
	}
	return value, nil
}

func (o *corpusObserver) scanRecords(name string, data []byte, visit func(corpusStreamRecord, int)) {
	s := bufio.NewScanner(bytes.NewReader(data))
	s.Buffer(make([]byte, 1<<20), 1<<28)
	line := 0
	for s.Scan() {
		line++
		var rec corpusStreamRecord
		if err := json.Unmarshal(s.Bytes(), &rec); err != nil {
			o.violate("%s:%d: invalid event JSON: %v", o.rel(name), line, err)
			continue
		}
		visit(rec, line)
	}
	if err := s.Err(); err != nil {
		o.violate("%s: read: %v", o.rel(name), err)
	}
}

func (o *corpusObserver) checkRoots() {
	ids := o.rootIDs()
	if len(ids) != o.cfg.expectRoots {
		o.violate("unique root count is %d, want %d", len(ids), o.cfg.expectRoots)
	}
	if o.cfg.expectRoots == 3651 {
		want := map[string]int{"testdir": 2726, "typechecker": 899, "package": 26}
		for _, runner := range corpusRunners {
			got := 0
			for _, id := range ids {
				if strings.HasPrefix(id, runner+":") {
					got++
				}
			}
			if got != want[runner] {
				o.violate("unique %s root count is %d, want %d", runner, got, want[runner])
			}
		}
	}
	for _, id := range ids {
		for _, mode := range corpusModes {
			if o.states[id][mode] == "" {
				o.violate("root %s is missing %s terminal", id, mode)
			}
		}
		if strings.HasPrefix(id, "package:") {
			for _, mode := range corpusModes[1:] {
				if o.states[id][mode] != "" && o.states[id]["@package-plan:"+mode] == "" {
					o.nativeExec++
					o.violate("%s %s has a terminal but no package backend plan", mode, id)
				}
			}
		}
	}
	if o.nativeExec != 0 {
		o.violate("native tested-source executions in backend lanes = %d, want 0", o.nativeExec)
	}
}

func (o *corpusObserver) checkSkips() {
	data, err := os.ReadFile(o.cfg.expectSkips)
	if err != nil {
		o.violate("expected SKIP set: %v", err)
		return
	}
	digest := sha256.Sum256(data)
	o.manifest = append(o.manifest, corpusManifestEntry{"@expect-skips", hex.EncodeToString(digest[:])})
	var expected []string
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if line == "" {
			if len(data) != 0 {
				o.violate("expected SKIP set line %d is empty", i+1)
			}
			continue
		}
		expected = append(expected, line)
	}
	if !sort.StringsAreSorted(expected) {
		o.violate("expected SKIP set is not sorted")
	}
	for i := 1; i < len(expected); i++ {
		if expected[i] == expected[i-1] {
			o.violate("expected SKIP set contains duplicate ID %s", expected[i])
		}
	}
	for _, mode := range corpusModes {
		var actual []string
		for id, states := range o.states {
			if states[mode] == "SKIP" {
				actual = append(actual, id)
			}
		}
		sort.Strings(actual)
		if !equalStrings(actual, expected) {
			o.violate("%s SKIP set differs: got [%s], want [%s]", mode, strings.Join(actual, ","), strings.Join(expected, ","))
		}
	}
}

func (o *corpusObserver) readEvidence(name string) ([]byte, bool) {
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		o.violate("read %s: %v", o.rel(name), err)
		return nil, false
	}
	rel, err := filepath.Rel(o.root, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		o.violate("evidence stream escapes --evidence: %s", name)
		return nil, false
	}
	data, err := os.ReadFile(resolved)
	if err != nil {
		o.violate("read %s: %v", filepath.ToSlash(rel), err)
		return nil, false
	}
	digest := sha256.Sum256(data)
	o.manifest = append(o.manifest, corpusManifestEntry{filepath.ToSlash(rel), hex.EncodeToString(digest[:])})
	return data, true
}

func (o *corpusObserver) manifestBytes() []byte {
	var b strings.Builder
	for _, entry := range o.manifest {
		fmt.Fprintf(&b, "%s  %s\n", entry.sum, entry.path)
	}
	return []byte(b.String())
}

func (o *corpusObserver) checkOrWriteManifest(got []byte) {
	if o.cfg.manifest == "" {
		return
	}
	want, err := os.ReadFile(o.cfg.manifest)
	switch {
	case err == nil:
		if !bytes.Equal(want, got) {
			o.violate("manifest hash mismatch: %s does not match the streams read", o.cfg.manifest)
		}
	case errors.Is(err, os.ErrNotExist):
		if err := os.WriteFile(o.cfg.manifest, got, 0o644); err != nil {
			o.violate("write manifest: %v", err)
		}
	default:
		o.violate("read manifest: %v", err)
	}
}

func (o *corpusObserver) printReport(w io.Writer) {
	ids := o.rootIDs()
	fmt.Fprintf(w, "ROOTS\t%d\n", len(ids))
	for _, mode := range corpusModes {
		for _, runner := range corpusRunners {
			counts := map[string]int{"PASS": 0, "FAIL": 0, "SKIP": 0}
			for id, states := range o.states {
				if strings.HasPrefix(id, runner+":") {
					counts[states[mode]]++
				}
			}
			fmt.Fprintf(w, "RUNNER\t%s\t%s\tPASS=%d\tFAIL=%d\tSKIP=%d\n", runner, mode, counts["PASS"], counts["FAIL"], counts["SKIP"])
		}
	}
	var skips []string
	for id, states := range o.states {
		if states["native"] == "SKIP" {
			skips = append(skips, id)
		}
	}
	sort.Strings(skips)
	fmt.Fprintf(w, "SKIPS\t%d\n", len(skips))
	for _, id := range skips {
		fmt.Fprintf(w, "SKIP\t%s\n", id)
	}
	for _, id := range ids {
		fmt.Fprintf(w, "ROOT\t%s\tnative=%s\tinterpreted=%s\tcompiled=%s\n", id, valueOrMissing(o.states[id]["native"]), valueOrMissing(o.states[id]["interpreted"]), valueOrMissing(o.states[id]["compiled"]))
	}
	fmt.Fprintf(w, "NATIVE_TESTED_SOURCE_EXECUTIONS\t%d\n", o.nativeExec)
	for _, entry := range o.manifest {
		fmt.Fprintf(w, "MANIFEST\t%s\t%s\n", entry.sum, entry.path)
	}
}

func (o *corpusObserver) addState(id, mode, state string) {
	if o.states[id] == nil {
		o.states[id] = make(map[string]string)
	}
	if old := o.states[id][mode]; old != "" {
		o.violate("duplicate ID %s in %s terminal streams (%s and %s)", id, mode, old, state)
		return
	}
	o.states[id][mode] = state
}

func (o *corpusObserver) noteTerminal(id, mode string) {
	if o.allTerminals[id] == nil {
		o.allTerminals[id] = make(map[string]bool)
	}
	o.allTerminals[id][mode] = true
}

func (o *corpusObserver) rootIDs() []string {
	ids := make([]string, 0, len(o.states))
	for id := range o.states {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func (o *corpusObserver) rel(name string) string {
	if o.root == "" {
		return name
	}
	rel, err := filepath.Rel(o.root, name)
	if err != nil {
		return name
	}
	return filepath.ToSlash(rel)
}

func (o *corpusObserver) violate(format string, args ...any) {
	o.violations = append(o.violations, fmt.Sprintf(format, args...))
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func valueOrMissing(value string) string {
	if value == "" {
		return "MISSING"
	}
	return value
}
