// Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
// Command typecheck-diagnostics adjudicates one official go/types or types2
// check-harness root. It reads retained product evidence only; it never invokes
// a Go compiler or type-checker, and it never rewrites a fixture. It is a
// separate binary from tools/go-full/diagnostics, whose testdir errorcheck
// semantics differ and are preserved unchanged.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type fileInput struct {
	Path   string `json:"path"`
	Short  string `json:"short"`
	SHA256 string `json:"sha256"`
}

type processInput struct {
	Spawned bool   `json:"spawned"`
	State   string `json:"state"`
	Exit    *int   `json:"exit"`
	Signal  *int   `json:"signal"`
}

type request struct {
	Family          string        `json:"family"`
	Mode            string        `json:"mode"`
	ColumnTolerance int           `json:"column_tolerance"`
	Sources         []fileInput   `json:"sources"`
	Stdout          fileInput     `json:"stdout"`
	Stderr          fileInput     `json:"stderr"`
	Process         processInput  `json:"process"`
}

type response struct {
	Verdict       string       `json:"verdict"`
	Reason        string       `json:"reason,omitempty"`
	EvidenceScope string       `json:"evidence_scope"`
	Phases        []string     `json:"phases_adjudicated"`
	WantError     bool         `json:"want_error"`
	Match         *matchResult `json:"match,omitempty"`
	Unparsed      []string     `json:"unparsed_output,omitempty"`
}

const scope = "original-source-positioned-typechecker-diagnostics-only"

var phases = []string{"check-original-fixture", "match-source-positioned-diagnostics"}

// readVerified reads a retained file and fails unless it still hashes to the
// digest the driver recorded, so a mutated fixture or stream cannot pass.
func readVerified(input fileInput) ([]byte, error) {
	stat, err := os.Lstat(input.Path)
	if err != nil {
		return nil, err
	}
	if !stat.Mode().IsRegular() {
		return nil, fmt.Errorf("input is not a regular file: %s", input.Path)
	}
	data, err := os.ReadFile(input.Path)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(data)
	if len(input.SHA256) != 64 || hex.EncodeToString(sum[:]) != input.SHA256 {
		return nil, fmt.Errorf("input checksum mismatch: %s", input.Path)
	}
	return data, nil
}

func check(req request) (response, error) {
	res := response{Verdict: "FAIL", EvidenceScope: scope, Phases: phases}
	if req.Mode != "interpreted" && req.Mode != "compiled" {
		return res, fmt.Errorf("unknown checking mode: %q", req.Mode)
	}
	if req.ColumnTolerance < 0 {
		return res, fmt.Errorf("negative column tolerance")
	}
	if !req.Process.Spawned || req.Process.State != "exited" || req.Process.Exit == nil || req.Process.Signal != nil {
		return res, fmt.Errorf("checking phase did not exit normally; timeout/signal/launch failure cannot satisfy a check root")
	}
	if len(req.Sources) == 0 {
		return res, fmt.Errorf("missing fixture inventory")
	}

	// Collect the immutable expectations from the original fixture bytes.
	errmap := make(map[string]map[int][]comment)
	known := map[string]bool{}
	wanted := 0
	for _, input := range req.Sources {
		if input.Short == "" || filepath.IsAbs(input.Short) || strings.Contains(input.Short, "..") {
			return res, fmt.Errorf("empty or unsafe fixture selector: %q", input.Short)
		}
		short := filepath.Clean(input.Short)
		if known[short] {
			return res, fmt.Errorf("duplicate fixture selector: %s", short)
		}
		known[short] = true
		src, err := readVerified(input)
		if err != nil {
			return res, err
		}
		if m := commentMap(src, errorPattern); len(m) > 0 {
			errmap[short] = m
			for _, list := range m {
				wanted += len(list)
			}
		}
	}
	res.WantError = wanted > 0

	out, err := readVerified(req.Stdout)
	if err != nil {
		return res, err
	}
	errout, err := readVerified(req.Stderr)
	if err != nil {
		return res, err
	}

	// A non-zero status with no explained diagnostic, or a zero status with
	// diagnostics, is a failure: an exit code alone never establishes a PASS.
	if (*req.Process.Exit != 0) != res.WantError {
		return res, fmt.Errorf("check exit %d disagrees with %d required source annotation(s)", *req.Process.Exit, wanted)
	}

	gotOut, badOut := parseDiagnostics("stdout", string(out), known)
	gotErr, badErr := parseDiagnostics("stderr", string(errout), known)
	res.Unparsed = append(append([]string{}, badOut...), badErr...)
	got := append(append([]diagnostic{}, gotOut...), gotErr...)

	result := match(errmap, got, req.ColumnTolerance)
	res.Match = &result
	if len(res.Unparsed) > 0 {
		return res, fmt.Errorf("%d line(s) of product output are not positioned diagnostics for the fixture", len(res.Unparsed))
	}
	if len(result.InvalidPatterns) > 0 {
		return res, fmt.Errorf("unusable ERROR annotation: %s", result.InvalidPatterns[0])
	}
	if len(result.UnmatchedObserved) > 0 {
		return res, fmt.Errorf("%d unexpected diagnostic(s), first: %s", len(result.UnmatchedObserved), result.UnmatchedObserved[0])
	}
	if len(result.UnmatchedExpected) > 0 {
		e := result.UnmatchedExpected[0]
		return res, fmt.Errorf("%d unreported error(s), first: %s:%d:%d:%s", len(result.UnmatchedExpected), e.File, e.Line, e.Col, e.Text)
	}
	if len(result.ColumnMismatches) > 0 {
		m := result.ColumnMismatches[0]
		return res, fmt.Errorf("%s: got col = %d; want %d (tolerance %d)", m.Diagnostic, m.GotCol, m.WantCol, m.Tolerance)
	}
	if !result.complete() {
		return res, fmt.Errorf("incomplete diagnostic match")
	}

	// Re-authenticate every input after adjudication: nothing may have been
	// rewritten underneath the matcher while it ran.
	for _, input := range append(append([]fileInput{}, req.Sources...), req.Stdout, req.Stderr) {
		if _, err := readVerified(input); err != nil {
			return res, err
		}
	}
	res.Verdict = "PASS"
	return res, nil
}

func main() {
	var req request
	decoder := json.NewDecoder(os.Stdin)
	decoder.DisallowUnknownFields()
	fail := func(reason string, code int) {
		json.NewEncoder(os.Stdout).Encode(response{Verdict: "FAIL", Reason: reason, EvidenceScope: scope, Phases: phases})
		os.Exit(code)
	}
	if err := decoder.Decode(&req); err != nil {
		fail(err.Error(), 2)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		fail("trailing request data", 2)
	}
	result, err := check(req)
	if err != nil {
		result.Reason = err.Error()
	}
	json.NewEncoder(os.Stdout).Encode(result)
	if err != nil {
		os.Exit(1)
	}
}
