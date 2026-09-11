// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #157; Story: S157.2; Story-ID: 31520c72b5e0
//
// Verify the small direct-source seam. Go's testdir runner still owns recipe
// selection and terminal verdicts; this verifier names observed limitations.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

const backendSchema = "bashpp-tests/upstream-testdir-backend/v1"

type matrixRow struct {
	Capability string
	Test       string
	Action     string
}

type goRecord struct {
	Action string `json:"Action"`
	Test   string `json:"Test"`
	Output string `json:"Output"`
}

type toolIdentity struct {
	Path    string `json:"path"`
	Version string `json:"version"`
}

type eventRecord struct {
	Kind          string       `json:"kind"`
	Test          string       `json:"test"`
	Mode          string       `json:"mode"`
	BackendSchema string       `json:"backend_schema"`
	Action        string       `json:"action"`
	CompileInputs []string     `json:"compile_inputs"`
	ProgramArgv   []string     `json:"program_argv"`
	RecipeFlags   []string     `json:"recipe_flags"`
	NativeArgv    []string     `json:"native_argv"`
	Argv          []string     `json:"argv"`
	Artifacts     []string     `json:"artifacts"`
	Maps          []string     `json:"maps"`
	ArtifactProof []fileProof  `json:"artifact_proof"`
	MapProof      []fileProof  `json:"map_proof"`
	PhaseKind     string       `json:"phase_kind"`
	Phase         string       `json:"phase"`
	Cwd           string       `json:"cwd"`
	EnvDelta      []string     `json:"env_delta"`
	Disposition   string       `json:"disposition"`
	Deviations    []string     `json:"deviations"`
	Tool          toolIdentity `json:"tool"`
	ExpectedBytes int          `json:"expected_bytes"`
	ActualBytes   int          `json:"actual_bytes"`
	Matched       bool         `json:"matched"`
	Exit          int          `json:"exit"`
	Skipped       bool         `json:"skipped"`
	Failed        bool         `json:"failed"`
}

type fileProof struct {
	Path   string `json:"path"`
	Exists bool   `json:"exists"`
	Bytes  int    `json:"bytes"`
	SHA256 string `json:"sha256"`
}

type evidence struct {
	Phases      []eventRecord
	Backends    []eventRecord
	Comparisons []eventRecord
	Results     []eventRecord
	Terminal    *eventRecord
	Bypasses    int
}

func main() {
	matrix := flag.String("matrix", "", "authenticated matrix TSV")
	dir := flag.String("evidence", "", "per-mode evidence directory")
	mode := flag.String("mode", "", "interpreted or compiled")
	version := flag.String("version", "", "pinned Bash++ version")
	tool := flag.String("tool", "", "pinned Bash++ path")
	flag.Parse()

	rows, err := readMatrix(*matrix)
	if err != nil {
		fatal(err)
	}
	bad := false
	product := false
	for _, row := range rows {
		status, err := verifyRow(row, *dir, *mode, *version, *tool)
		if err != nil {
			bad = true
			fmt.Printf("FAIL %-34s %-30s %v\n", row.Capability, row.Test, err)
			continue
		}
		if strings.HasSuffix(status, "-PRODUCT-FAIL") {
			product = true
		}
		fmt.Printf("%-18s %-34s %s\n", status, row.Capability, row.Test)
	}
	if bad {
		os.Exit(1)
	}
	if product {
		fmt.Println("NON-GREEN: honest Bash++ product failures are retained in this packet")
		os.Exit(3)
	}
}

func readMatrix(name string) ([]matrixRow, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var rows []matrixRow
	s := bufio.NewScanner(f)
	for s.Scan() {
		if s.Text() == "" || strings.HasPrefix(s.Text(), "#") {
			continue
		}
		fields := strings.Split(s.Text(), "\t")
		if len(fields) != 5 {
			return nil, fmt.Errorf("invalid matrix row %q", s.Text())
		}
		rows = append(rows, matrixRow{fields[0], fields[1], fields[2]})
	}
	return rows, s.Err()
}

func verifyRow(row matrixRow, dir, mode, version, tool string) (string, error) {
	base := strings.NewReplacer("/", "_", ".", "_").Replace(row.Test)
	goAction, goOutput, err := terminalAction(filepath.Join(dir, base+".go-test.json"), "Test/"+row.Test)
	if err != nil {
		return "", err
	}
	ev, err := readEvents(filepath.Join(dir, base+".events.jsonl"), row.Test)
	if err != nil {
		return "", err
	}
	if ev.Terminal == nil || ev.Terminal.Skipped != (goAction == "skip") || ev.Terminal.Failed != (goAction == "fail") {
		return "", fmt.Errorf("terminal event disagrees with go test action %q", goAction)
	}
	if len(ev.Phases) != len(ev.Backends) {
		return "", fmt.Errorf("phase/backend count differs: %d/%d", len(ev.Phases), len(ev.Backends))
	}
	for i := range ev.Backends {
		phase, backend := ev.Phases[i], ev.Backends[i]
		if backend.BackendSchema != backendSchema || backend.Mode != mode || backend.Tool.Path != tool || backend.Tool.Version != version {
			return "", fmt.Errorf("backend identity is incomplete")
		}
		if backend.Action != phase.Action || backend.Phase != phase.PhaseKind ||
			!reflect.DeepEqual(backend.CompileInputs, phase.CompileInputs) ||
			!reflect.DeepEqual(backend.ProgramArgv, phase.ProgramArgv) ||
			!reflect.DeepEqual(backend.RecipeFlags, phase.RecipeFlags) ||
			!reflect.DeepEqual(backend.NativeArgv, phase.Argv) {
			return "", fmt.Errorf("backend did not retain upstream action, flags, native argv, and source/argument boundary")
		}
		if len(backend.Deviations) == 0 {
			return "", fmt.Errorf("backend deviations are not explicit")
		}
	}

	if row.Action == "build" {
		return verifyBuildRow(row, ev, mode, goAction)
	}
	if row.Action == "compile" {
		return verifyCompileRow(row, ev, mode, goAction)
	}

	switch row.Test {
	case "fixedbugs/issue21808.go":
		if goAction != "pass" || len(ev.Backends) != 1 || !directDisposition(mode, ev.Backends[0].Disposition) {
			return "", fmt.Errorf("wanted direct-source ordered-output pass, got action=%s disposition=%v", goAction, dispositions(ev.Backends))
		}
		for _, comparison := range ev.Comparisons {
			if comparison.ExpectedBytes == 5 && comparison.ActualBytes == 5 && comparison.Matched {
				return "ORDERED-OUTPUT-PASS", nil
			}
		}
		return "", fmt.Errorf("missing exact five-byte combined-output comparison")

	case "cmplxdivide.go":
		if len(ev.Backends) != 1 || !reflect.DeepEqual(ev.Backends[0].CompileInputs, []string{"cmplxdivide.go", "cmplxdivide1.go"}) || len(ev.Backends[0].ProgramArgv) != 0 {
			return "", fmt.Errorf("multi-file source boundary is wrong")
		}
		if mode == "interpreted" {
			if goAction != "fail" || ev.Backends[0].Disposition != "check-then-run" || !hasExit(ev.Results, 2) || !strings.Contains(goOutput, "complex128") {
				return "", fmt.Errorf("wanted current direct interpreter complex128 exit-2 diagnostic: action=%s disposition=%v results=%v output=%q", goAction, dispositions(ev.Backends), resultExits(ev.Results), goOutput)
			}
			return "EXPECTED-DIAGNOSTIC", nil
		}
		if goAction != "pass" || ev.Backends[0].Disposition != "transpile-build-run" || !hasExit(ev.Results, 0) {
			return "", fmt.Errorf("wanted successful compiled multi-file path: action=%s disposition=%v results=%v", goAction, dispositions(ev.Backends), resultExits(ev.Results))
		}
		return "OBSERVED-PASS", nil
	}

	if row.Action == "skip" || row.Test == "fixedbugs/issue38093.go" {
		if goAction != "skip" || len(ev.Phases) != 0 {
			return "", fmt.Errorf("upstream skip changed: action=%s phases=%d", goAction, len(ev.Phases))
		}
		return "UPSTREAM-SKIP", nil
	}
	if row.Action == "asmcheck" && len(ev.Phases) == 0 {
		if goAction != "pass" || ev.Bypasses == 0 {
			return "", fmt.Errorf("upstream assembly bypass changed")
		}
		return "UPSTREAM-BYPASS", nil
	}
	if len(ev.Backends) == 0 || ev.Backends[0].Disposition != "unsupported" || goAction != "fail" {
		return "", fmt.Errorf("non-run recipe was not an explicit honest failure: action=%s dispositions=%v", goAction, dispositions(ev.Backends))
	}
	return "UNSUPPORTED", nil
}

// buildRoots is the authenticated Sprint 149.6 packet: the exact upstream
// go-command recipe flags each build root must carry verbatim, and the
// GOEXPERIMENT value owned by the upstream-selected runenv.
var buildRoots = map[string]struct {
	RecipeFlags  []string
	GoExperiment string
}{
	"abi/bad_select_crash.go": {RecipeFlags: []string{}, GoExperiment: "regabi,regabiargs"},
	"arenas/smoke.go":         {RecipeFlags: []string{}, GoExperiment: "arenas"},
	"fixedbugs/issue59404.go": {RecipeFlags: []string{"-gcflags=-l=4"}},
	"fixedbugs/issue59638.go": {RecipeFlags: []string{"-gcflags=-l=4"}},
}

// verifyCompileRow checks one upstream `compile` root (the S157 bug020 canary
// and every Sprint 149.4 packet root alike): exactly one compile-only phase
// carrying one Go source input and no program argv, never an execute phase.
// The recipe flags are whatever upstream selected; the generic identity check
// above already proves the backend retained them. A Bash++ product failure is
// retained as a recorded nonzero phase exit, never reclassified.
func verifyCompileRow(row matrixRow, ev evidence, mode, goAction string) (string, error) {
	if goAction == "skip" {
		if len(ev.Phases) != 0 {
			return "", fmt.Errorf("upstream skip with %d recorded phases", len(ev.Phases))
		}
		return "UPSTREAM-SKIP", nil
	}
	if len(ev.Phases) != 1 || len(ev.Backends) != 1 || len(ev.Results) != 1 {
		return "", fmt.Errorf("wanted exactly one compile phase/backend/result, got %d/%d/%d", len(ev.Phases), len(ev.Backends), len(ev.Results))
	}
	phase, backend, result := ev.Phases[0], ev.Backends[0], ev.Results[0]
	if backend.Action != "compile" || backend.Phase != "compile" || phase.PhaseKind == "execute" {
		return "", fmt.Errorf("compile root did not stay a compile-only phase: action=%s phase=%s", backend.Action, backend.Phase)
	}
	if len(backend.CompileInputs) != 1 || !strings.HasSuffix(backend.CompileInputs[0], filepath.Base(row.Test)) {
		return "", fmt.Errorf("compile phase must select exactly the one upstream root, got %v", backend.CompileInputs)
	}
	if len(backend.ProgramArgv) != 0 {
		return "", fmt.Errorf("compile phase must carry an empty program argv, got %v", backend.ProgramArgv)
	}
	switch mode {
	case "interpreted":
		if backend.Disposition != "check-only" || len(backend.Artifacts) != 0 || len(backend.Maps) != 0 ||
			len(result.ArtifactProof) != 0 || len(result.MapProof) != 0 {
			return "", fmt.Errorf("interpreted compile phase was not check-only")
		}
	case "compiled":
		if backend.Disposition != "transpile-build-only" || len(backend.Artifacts) != 2 || len(backend.Maps) != 1 {
			return "", fmt.Errorf("compiled compile phase must transpile with a map and build only")
		}
	default:
		return "", fmt.Errorf("unknown backend mode %q", mode)
	}
	if goAction == "pass" {
		if result.Exit != 0 {
			return "", fmt.Errorf("upstream pass with nonzero compile phase exit %d", result.Exit)
		}
		if mode == "compiled" && (!validProofs(backend.Artifacts, result.ArtifactProof) || !validProofs(backend.Maps, result.MapProof)) {
			return "", fmt.Errorf("compiled compile phase lacks generated/map/artifact existence and hash proof")
		}
		return "COMPILE-ONLY-PASS", nil
	}
	if result.Exit == 0 {
		return "", fmt.Errorf("upstream failure without a recorded nonzero compile phase exit")
	}
	return "COMPILE-PRODUCT-FAIL", nil
}

func verifyBuildRow(row matrixRow, ev evidence, mode, goAction string) (string, error) {
	want, ok := buildRoots[row.Test]
	if !ok {
		return "", fmt.Errorf("build root %q is not in the authenticated 149.6 packet", row.Test)
	}
	if goAction == "skip" {
		return "", fmt.Errorf("upstream unexpectedly skipped an authenticated build root")
	}
	if len(ev.Phases) != 1 || len(ev.Backends) != 1 || len(ev.Results) != 1 {
		return "", fmt.Errorf("wanted exactly one build phase/backend/result, got %d/%d/%d", len(ev.Phases), len(ev.Backends), len(ev.Results))
	}
	phase, backend, result := ev.Phases[0], ev.Backends[0], ev.Results[0]
	if backend.Action != "build" || backend.Phase != "compile" || phase.PhaseKind == "execute" {
		return "", fmt.Errorf("build root did not stay a compile/build-only phase: action=%s phase=%s", backend.Action, backend.Phase)
	}
	if len(backend.CompileInputs) != 1 || !strings.HasSuffix(backend.CompileInputs[0], "/"+row.Test) {
		return "", fmt.Errorf("build phase must select exactly the one upstream root, got %v", backend.CompileInputs)
	}
	if len(backend.ProgramArgv) != 0 {
		return "", fmt.Errorf("build phase must carry an empty program argv, got %v", backend.ProgramArgv)
	}
	if !reflect.DeepEqual(backend.RecipeFlags, want.RecipeFlags) {
		return "", fmt.Errorf("recipe flags are not the exact upstream go-command flags: got %v, want %v", backend.RecipeFlags, want.RecipeFlags)
	}
	goexp := ""
	for _, entry := range phase.EnvDelta {
		if value, found := strings.CutPrefix(entry, "GOEXPERIMENT="); found {
			goexp = value
		}
	}
	if goexp != want.GoExperiment {
		return "", fmt.Errorf("upstream runenv GOEXPERIMENT = %q, want %q", goexp, want.GoExperiment)
	}
	switch mode {
	case "interpreted":
		if backend.Disposition != "check-only" || len(backend.Artifacts) != 0 || len(backend.Maps) != 0 ||
			len(result.ArtifactProof) != 0 || len(result.MapProof) != 0 {
			return "", fmt.Errorf("interpreted build phase must be check-only with no artifact or compiler semantics")
		}
	case "compiled":
		if backend.Disposition != "transpile-build-only" || len(backend.Artifacts) != 2 || len(backend.Maps) != 1 {
			return "", fmt.Errorf("compiled build phase must transpile with a map and build only")
		}
		built := backend.Artifacts[1]
		if filepath.Base(built) != "a.exe" || phase.Cwd == "" || filepath.Dir(built) != phase.Cwd {
			return "", fmt.Errorf("build artifact %q is not a.exe in the upstream working directory %q", built, phase.Cwd)
		}
	default:
		return "", fmt.Errorf("unknown backend mode %q", mode)
	}
	if goAction == "pass" {
		if result.Exit != 0 {
			return "", fmt.Errorf("upstream pass with nonzero build phase exit %d", result.Exit)
		}
		if mode == "compiled" && (!validProofs(backend.Artifacts, result.ArtifactProof) || !validProofs(backend.Maps, result.MapProof)) {
			return "", fmt.Errorf("compiled build pass lacks generated/map/artifact existence and hash proof")
		}
		return "BUILD-ONLY-PASS", nil
	}
	if result.Exit == 0 {
		return "", fmt.Errorf("upstream failure without a recorded nonzero build phase exit")
	}
	return "BUILD-PRODUCT-FAIL", nil
}

func validProofs(paths []string, proofs []fileProof) bool {
	if len(paths) == 0 || len(paths) != len(proofs) {
		return false
	}
	for i, proof := range proofs {
		if proof.Path != paths[i] || !proof.Exists || proof.Bytes <= 0 || len(proof.SHA256) != 64 {
			return false
		}
		for _, r := range proof.SHA256 {
			if !strings.ContainsRune("0123456789abcdef", r) {
				return false
			}
		}
	}
	return true
}

func directDisposition(mode, got string) bool {
	if mode == "interpreted" {
		return got == "check-then-run"
	}
	return got == "transpile-build-run"
}

func hasExit(records []eventRecord, exit int) bool {
	for _, record := range records {
		if record.Exit == exit {
			return true
		}
	}
	return false
}

func dispositions(records []eventRecord) []string {
	out := make([]string, 0, len(records))
	for _, record := range records {
		out = append(out, record.Disposition)
	}
	return out
}

func resultExits(records []eventRecord) []int {
	out := make([]int, 0, len(records))
	for _, record := range records {
		out = append(out, record.Exit)
	}
	return out
}

func terminalAction(name, want string) (string, string, error) {
	f, err := os.Open(name)
	if err != nil {
		return "", "", err
	}
	defer f.Close()
	action, output := "", ""
	s := bufio.NewScanner(f)
	for s.Scan() {
		var rec goRecord
		if json.Unmarshal(s.Bytes(), &rec) == nil && strings.HasPrefix(rec.Test, want) {
			output += rec.Output
			if rec.Test == want && (rec.Action == "pass" || rec.Action == "fail" || rec.Action == "skip") {
				action = rec.Action
			}
		}
	}
	if err := s.Err(); err != nil {
		return "", "", err
	}
	if action == "" {
		return "", "", fmt.Errorf("missing go test terminal action for %s", want)
	}
	return action, output, nil
}

func readEvents(name, test string) (evidence, error) {
	f, err := os.Open(name)
	if err != nil {
		return evidence{}, err
	}
	defer f.Close()
	var out evidence
	s := bufio.NewScanner(f)
	for s.Scan() {
		var rec eventRecord
		if err := json.Unmarshal(s.Bytes(), &rec); err != nil {
			return evidence{}, err
		}
		if rec.Test != test {
			continue
		}
		switch rec.Kind {
		case "phase":
			out.Phases = append(out.Phases, rec)
		case "backend":
			out.Backends = append(out.Backends, rec)
		case "comparison":
			out.Comparisons = append(out.Comparisons, rec)
		case "phase_result":
			out.Results = append(out.Results, rec)
		case "bypass":
			out.Bypasses++
		case "terminal":
			copy := rec
			out.Terminal = &copy
		}
	}
	return out, s.Err()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
