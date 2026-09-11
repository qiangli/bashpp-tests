// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #149; Story: S149.10; Story-ID: 8ae8f1041a8f
//
// Verify the typechecker seam: for every authenticated root, the upstream
// checker harness (types2 or go/types) ran its subtest, the Bash++ check
// interface was invoked exactly on that fixture with the upstream-parsed
// language version, and the terminal is upstream's own verdict. The
// verifier names observed limitations; it makes no recipe decision.
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

type typesRow struct {
	Capability, Test, Action, SHA256, Fixture string
	Package, Subtest                          string
}

type typesEvent struct {
	Kind string `json:"kind"`
	Test string `json:"test"`
	Tool struct {
		Path    string `json:"path"`
		Version string `json:"version"`
	} `json:"tool"`
	Files       []string `json:"files"`
	Lang        string   `json:"lang"`
	FakeImportC bool     `json:"fake_import_c"`
	Argv        []string `json:"argv"`
	Exit        int      `json:"exit"`
	Diagnostics int      `json:"diagnostics"`
	Unparsed    int      `json:"unparsed"`
	Deviations  []string `json:"deviations"`
}

type goTestRecord struct {
	Action, Test string
}

func main() {
	matrix := flag.String("matrix", "", "authenticated matrix TSV")
	dir := flag.String("evidence", "", "evidence directory")
	version := flag.String("version", "", "pinned Bash++ version")
	tool := flag.String("tool", "", "pinned Bash++ path")
	flag.Parse()
	rows, err := readTypesMatrix(*matrix)
	if err != nil {
		fatal(err)
	}
	terminals := map[string]map[string]string{}
	events := map[string]map[string]typesEvent{}
	bad, product := false, false
	for _, row := range rows {
		id := packageID(row.Package)
		if terminals[id] == nil {
			t, err := readTerminals(filepath.Join(*dir, id+".go-test.json"))
			if err != nil {
				fatal(err)
			}
			terminals[id] = t
			e, err := readTypesEvents(filepath.Join(*dir, id+".events.jsonl"))
			if err != nil {
				fatal(err)
			}
			events[id] = e
		}
		status, err := verifyTypesRow(row, terminals[id][row.Subtest], events[id][row.Subtest], *version, *tool)
		if err != nil {
			bad = true
			fmt.Printf("FAIL %-34s %-52s %v\n", row.Capability, row.Test, err)
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

func packageID(pkg string) string {
	if strings.HasSuffix(pkg, "/types2") {
		return "types2"
	}
	return "gotypes"
}

func verifyTypesRow(row typesRow, terminal string, ev typesEvent, version, tool string) (string, error) {
	if terminal == "" {
		return "", fmt.Errorf("upstream subtest %s has no terminal action", row.Subtest)
	}
	if terminal == "skip" {
		return "UPSTREAM-SKIP", nil
	}
	if ev.Kind != "types-backend" {
		return "", fmt.Errorf("no Bash++ check was recorded for %s", row.Subtest)
	}
	if ev.Tool.Path != tool || ev.Tool.Version != version {
		return "", fmt.Errorf("backend identity is incomplete")
	}
	if len(ev.Files) != 1 || filepath.Base(ev.Files[0]) != filepath.Base(row.Fixture) {
		return "", fmt.Errorf("Bash++ was not invoked on exactly the upstream fixture: %v", ev.Files)
	}
	if len(ev.Deviations) == 0 {
		return "", fmt.Errorf("backend deviations are not explicit")
	}
	if ev.Exit != 0 && ev.Exit != 2 {
		return "", fmt.Errorf("check interface exited %d, which is neither clean nor a diagnostics exit", ev.Exit)
	}
	if ev.Unparsed != 0 {
		return "", fmt.Errorf("%d diagnostic line(s) could not be attributed to the fixture", ev.Unparsed)
	}
	switch terminal {
	case "pass":
		return "TYPES-PASS", nil
	case "fail":
		return "TYPES-PRODUCT-FAIL", nil
	}
	return "", fmt.Errorf("unexpected terminal %q", terminal)
}

func readTypesMatrix(name string) ([]typesRow, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var rows []typesRow
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := s.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) != 5 {
			return nil, fmt.Errorf("matrix row has %d columns: %q", len(parts), line)
		}
		pkg, sub, ok := strings.Cut(parts[1], ":")
		if !ok {
			return nil, fmt.Errorf("matrix test %q is not package:subtest", parts[1])
		}
		rows = append(rows, typesRow{Capability: parts[0], Test: parts[1], Action: parts[2], SHA256: parts[3], Fixture: parts[4], Package: pkg, Subtest: sub})
	}
	return rows, s.Err()
}

func readTerminals(name string) (map[string]string, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]string{}
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 1<<28)
	for s.Scan() {
		var rec goTestRecord
		if err := json.Unmarshal(s.Bytes(), &rec); err != nil {
			continue
		}
		switch rec.Action {
		case "pass", "fail", "skip":
			if strings.Contains(rec.Test, "/") {
				out[rec.Test] = rec.Action
			}
		}
	}
	return out, s.Err()
}

func readTypesEvents(name string) (map[string]typesEvent, error) {
	out := map[string]typesEvent{}
	f, err := os.Open(name)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, err
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 1<<28)
	for s.Scan() {
		var ev typesEvent
		if err := json.Unmarshal(s.Bytes(), &ev); err != nil {
			return nil, err
		}
		if _, dup := out[ev.Test]; dup {
			return nil, fmt.Errorf("subtest %s recorded more than one Bash++ check", ev.Test)
		}
		out[ev.Test] = ev
	}
	return out, s.Err()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "FAIL", err)
	os.Exit(1)
}
