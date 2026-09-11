// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #157; Story: S157.3; Story-ID: 04e86c3f7fc0
//
// Minimal independent observer for two representative upstream-owned phases.
// It reads emitted records only; it never reads source directives or chooses a
// recipe, action, companion, or applicability result.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const observerSchema = "bashpp-tests/upstream-testdir-observer/v1"

type observerTool struct {
	Path    string `json:"path"`
	Version string `json:"version"`
}

type observerRecord struct {
	Kind          string       `json:"kind"`
	Test          string       `json:"test"`
	Order         int          `json:"order"`
	Mode          string       `json:"mode"`
	BackendSchema string       `json:"backend_schema"`
	Tool          observerTool `json:"tool"`
	Expected      string       `json:"expected"`
	Actual        string       `json:"actual"`
	Matched       bool         `json:"matched"`
	Exit          int          `json:"exit"`
	TimedOut      bool         `json:"timed_out"`
	Failed        bool         `json:"failed"`
	Skipped       bool         `json:"skipped"`
}

type observedCase struct {
	Test          string `json:"test"`
	OrderedOutput string `json:"ordered_output,omitempty"`
	PhaseExit     int    `json:"phase_exit"`
	TimedOut      bool   `json:"timed_out"`
	Terminal      string `json:"terminal"`
}

type observerReceipt struct {
	Schema     string            `json:"schema"`
	Mode       string            `json:"mode"`
	Identities map[string]string `json:"identities"`
	Tool       observerTool      `json:"tool"`
	Cases      []observedCase    `json:"cases"`
}

func main() {
	pinsPath := flag.String("pins", "", "authenticated identity pins")
	evidenceDir := flag.String("evidence", "", "backend evidence directory")
	mode := flag.String("mode", "", "interpreted or compiled")
	version := flag.String("version", "", "expected Bash++ version")
	toolPath := flag.String("tool", "", "expected Bash++ path")
	outPath := flag.String("out", "", "receipt output path")
	flag.Parse()

	if *mode != "interpreted" && *mode != "compiled" {
		fatalObserver("invalid observer mode %q", *mode)
	}
	pins, err := readObserverPins(*pinsPath)
	if err != nil {
		fatalObserver("pins: %v", err)
	}
	identities := make(map[string]string)
	for _, key := range []string{"go_release", "upstream", "instrumentation_patch", "backend_patch", "backend_events_patch", "backend_hook"} {
		value := pins[key]
		if value == "" {
			fatalObserver("missing identity pin %s", key)
		}
		identities[key] = value
	}

	issue, issueTool, err := observeCase(filepath.Join(*evidenceDir, "fixedbugs_issue21808_go.events.jsonl"), "fixedbugs/issue21808.go", *mode, *version, *toolPath)
	if err != nil {
		fatalObserver("ordered output: %v", err)
	}
	cmplx, cmplxTool, err := observeCase(filepath.Join(*evidenceDir, "cmplxdivide_go.events.jsonl"), "cmplxdivide.go", *mode, *version, *toolPath)
	if err != nil {
		fatalObserver("multi-file phase: %v", err)
	}
	if issueTool != cmplxTool {
		fatalObserver("tool identities differ between observed phases")
	}
	if issue.OrderedOutput != "A\n\nB\n" || issue.PhaseExit != 0 || issue.TimedOut || issue.Terminal != "pass" {
		fatalObserver("ordered-output observation is not the exact passing five-byte result: %+v", issue)
	}
	if *mode == "interpreted" {
		if cmplx.PhaseExit != 2 || cmplx.TimedOut || cmplx.Terminal != "fail" {
			fatalObserver("interpreted multi-file terminal observation changed: %+v", cmplx)
		}
	} else if cmplx.PhaseExit != 0 || cmplx.TimedOut || cmplx.Terminal != "pass" {
		fatalObserver("compiled multi-file terminal observation changed: %+v", cmplx)
	}

	receipt := observerReceipt{
		Schema: observerSchema, Mode: *mode, Identities: identities,
		Tool: issueTool, Cases: []observedCase{issue, cmplx},
	}
	encoded, err := json.Marshal(receipt)
	if err != nil {
		fatalObserver("encode receipt: %v", err)
	}
	if err := os.WriteFile(*outPath, append(encoded, '\n'), 0o644); err != nil {
		fatalObserver("write receipt: %v", err)
	}
	fmt.Printf("PASS minimal observer %s: exact ordered output and phase/terminal records\n", *mode)
}

func observeCase(name, wantTest, mode, version, toolPath string) (observedCase, observerTool, error) {
	f, err := os.Open(name)
	if err != nil {
		return observedCase{}, observerTool{}, err
	}
	defer f.Close()

	var backend, comparison, result, terminal []observerRecord
	lastOrder := -1
	s := bufio.NewScanner(f)
	// A generated program or a long diagnostic can exceed the default token size.
	s.Buffer(make([]byte, 1<<20), 1<<28)
	for s.Scan() {
		var record observerRecord
		if err := json.Unmarshal(s.Bytes(), &record); err != nil {
			return observedCase{}, observerTool{}, err
		}
		if record.Test != wantTest {
			continue
		}
		if record.Order <= lastOrder {
			return observedCase{}, observerTool{}, fmt.Errorf("non-increasing record order %d after %d", record.Order, lastOrder)
		}
		lastOrder = record.Order
		switch record.Kind {
		case "backend":
			backend = append(backend, record)
		case "comparison":
			if record.Expected != "" || record.Actual != "" {
				comparison = append(comparison, record)
			}
		case "phase_result":
			result = append(result, record)
		case "terminal":
			terminal = append(terminal, record)
		}
	}
	if err := s.Err(); err != nil {
		return observedCase{}, observerTool{}, err
	}
	if len(backend) != 1 || len(result) != 1 || len(terminal) != 1 {
		return observedCase{}, observerTool{}, fmt.Errorf("wanted one backend/result/terminal record, got %d/%d/%d", len(backend), len(result), len(terminal))
	}
	if backend[0].Mode != mode || backend[0].Tool.Path != toolPath || backend[0].Tool.Version != version {
		return observedCase{}, observerTool{}, fmt.Errorf("backend identity mismatch")
	}
	state := "pass"
	if terminal[0].Skipped {
		state = "skip"
	} else if terminal[0].Failed {
		state = "fail"
	}
	observed := observedCase{Test: wantTest, PhaseExit: result[0].Exit, TimedOut: result[0].TimedOut, Terminal: state}
	if strings.HasSuffix(wantTest, "issue21808.go") {
		if len(comparison) != 1 || !comparison[0].Matched || comparison[0].Expected != comparison[0].Actual {
			return observedCase{}, observerTool{}, fmt.Errorf("missing matched exact-output comparison")
		}
		observed.OrderedOutput = comparison[0].Actual
	}
	return observed, backend[0].Tool, nil
}

func readObserverPins(name string) (map[string]string, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	pins := make(map[string]string)
	s := bufio.NewScanner(f)
	// A generated program or a long diagnostic can exceed the default token size.
	s.Buffer(make([]byte, 1<<20), 1<<28)
	for s.Scan() {
		if s.Text() == "" || strings.HasPrefix(s.Text(), "#") {
			continue
		}
		key, value, ok := strings.Cut(s.Text(), "\t")
		if !ok || key == "" || value == "" {
			return nil, fmt.Errorf("invalid pin line %q", s.Text())
		}
		pins[key] = value
	}
	return pins, s.Err()
}

func fatalObserver(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
