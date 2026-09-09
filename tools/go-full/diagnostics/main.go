// Sprint: #118; Story-ID: 3abd77da923c
// Command diagnostics matches retained product output against immutable ERROR
// annotations. It never runs the source program or invokes a Go compiler.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

type fileInput struct {
	Path   string `json:"path"`
	Short  string `json:"short,omitempty"`
	SHA256 string `json:"sha256"`
}
type request struct {
	WantAuto  bool        `json:"want_auto"`
	WantError bool        `json:"want_error"`
	Sources   []fileInput `json:"sources"`
	Stdout    fileInput   `json:"stdout"`
	Stderr    fileInput   `json:"stderr"`
	Process   struct {
		Spawned bool   `json:"spawned"`
		State   string `json:"state"`
		Exit    *int   `json:"exit"`
		Signal  *int   `json:"signal"`
	} `json:"process"`
}
type response struct {
	Verdict       string `json:"verdict"`
	WantedErrors  int    `json:"wanted_errors"`
	Reason        string `json:"reason,omitempty"`
	EvidenceScope string `json:"evidence_scope"`
}

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
	res := response{Verdict: "FAIL", EvidenceScope: "source-positioned-diagnostics-only"}
	if !req.Process.Spawned || req.Process.State != "exited" || req.Process.Exit == nil || req.Process.Signal != nil {
		return res, fmt.Errorf("process did not exit normally; timeout/signal/launch failure cannot satisfy errorcheck")
	}
	if (*req.Process.Exit != 0) != req.WantError {
		return res, fmt.Errorf("exit %d disagrees with want_error=%v", *req.Process.Exit, req.WantError)
	}
	if len(req.Sources) == 0 {
		return res, fmt.Errorf("missing source inventory")
	}
	var fullshort []string
	seen := map[string]bool{}
	for _, input := range req.Sources {
		if input.Short == "" || strings.ContainsAny(input.Short, "/\\") || seen[input.Short] {
			return res, fmt.Errorf("empty/unsafe/duplicate short source name: %s", input.Short)
		}
		seen[input.Short] = true
		if _, err := readVerified(input); err != nil {
			return res, err
		}
		wanted, err := wantedErrors(input.Path, input.Short)
		if err != nil {
			return res, err
		}
		res.WantedErrors += len(wanted)
		fullshort = append(fullshort, input.Path, input.Short)
	}
	if req.WantError && res.WantedErrors == 0 {
		return res, fmt.Errorf("negative recipe has no required ERROR annotations")
	}
	out, err := readVerified(req.Stdout)
	if err != nil {
		return res, err
	}
	errout, err := readVerified(req.Stderr)
	if err != nil {
		return res, err
	}
	if err := errorCheck(string(out)+"\n"+string(errout), req.WantAuto, fullshort...); err != nil {
		return res, err
	}
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
	if err := decoder.Decode(&req); err != nil {
		json.NewEncoder(os.Stdout).Encode(response{Verdict: "FAIL", Reason: err.Error(), EvidenceScope: "source-positioned-diagnostics-only"})
		os.Exit(2)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		json.NewEncoder(os.Stdout).Encode(response{Verdict: "FAIL", Reason: "trailing request data", EvidenceScope: "source-positioned-diagnostics-only"})
		os.Exit(2)
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
