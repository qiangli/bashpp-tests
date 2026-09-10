// Sprint: #148; Story: #31; Story-ID: 7a1175a64d88
// Command source-remap validates bashy-transpile-map-v1 source maps, remaps
// product diagnostics from lowered positions onto original positions, and
// matches them exactly against the original ERROR annotations, optionally
// alongside an exact byte comparison. It never runs a program or a compiler;
// it adjudicates retained evidence only. Process gating and recipe policy stay
// with the orchestration owner and Sprint 154.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const evidenceScope = "remapped-original-position-diagnostics-and-exact-bytes-only"

type fileInput struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

// sourceInput is one retained original. Name is what the lowerer called it in
// the map; Short is the name diagnostics and ERROR annotations use; Aliases
// are compile-time spellings of the file that product output may carry.
type sourceInput struct {
	fileInput
	Name    string   `json:"name"`
	Short   string   `json:"short"`
	Aliases []string `json:"aliases,omitempty"`
}

// unit is one lowered compilation: a generated file, its map and originals.
type unit struct {
	Generated fileInput     `json:"generated"`
	Short     string        `json:"short"`
	Aliases   []string      `json:"aliases,omitempty"`
	Map       fileInput     `json:"map"`
	Sources   []sourceInput `json:"sources"`
}

type request struct {
	// EvidenceRoot is the canonical directory containing every retained input.
	EvidenceRoot string `json:"evidence_root"`
	Units        []unit `json:"units"`
	// Output is the captured product diagnostics, concatenated in order.
	Output []fileInput `json:"output"`
	// Optional exact byte comparison; both or neither must be supplied.
	ExpectedBytes *fileInput `json:"expected_bytes,omitempty"`
	ObservedBytes *fileInput `json:"observed_bytes,omitempty"`
}

type response struct {
	Verdict       string           `json:"verdict"`
	Reason        string           `json:"reason,omitempty"`
	EvidenceScope string           `json:"evidence_scope"`
	Units         int              `json:"validated_maps"`
	Remapped      []diagnostic     `json:"remapped_diagnostics,omitempty"`
	Match         *diagnosticMatch `json:"diagnostic_match,omitempty"`
	Bytes         *byteMatch       `json:"byte_match,omitempty"`
}

func canonicalEvidenceRoot(path string) (string, error) {
	if path == "" || !filepath.IsAbs(path) {
		return "", errors.New("evidence_root must be an absolute directory")
	}
	root, err := filepath.EvalSymlinks(filepath.Clean(path))
	if err != nil {
		return "", fmt.Errorf("resolve evidence_root: %v", err)
	}
	stat, err := os.Stat(root)
	if err != nil || !stat.IsDir() {
		return "", errors.New("evidence_root is not a directory")
	}
	return root, nil
}

func readVerified(root string, input fileInput) ([]byte, error) {
	if !filepath.IsAbs(input.Path) {
		return nil, fmt.Errorf("input path is not absolute: %s", input.Path)
	}
	clean := filepath.Clean(input.Path)
	stat, err := os.Lstat(clean)
	if err != nil {
		return nil, err
	}
	if !stat.Mode().IsRegular() {
		return nil, fmt.Errorf("input is not a regular file: %s", input.Path)
	}
	resolved, err := filepath.EvalSymlinks(clean)
	if err != nil {
		return nil, err
	}
	rel, err := filepath.Rel(root, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return nil, fmt.Errorf("input path resolves outside evidence_root: %s", input.Path)
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
	res := response{Verdict: "FAIL", EvidenceScope: evidenceScope}
	root, err := canonicalEvidenceRoot(req.EvidenceRoot)
	if err != nil {
		return res, err
	}
	if (req.ExpectedBytes == nil) != (req.ObservedBytes == nil) {
		return res, errors.New("expected_bytes and observed_bytes must be supplied together")
	}
	if len(req.Units) == 0 && req.ExpectedBytes == nil {
		return res, errors.New("request has neither lowered units nor a byte obligation")
	}
	if len(req.Units) == 0 && len(req.Output) != 0 {
		return res, errors.New("diagnostic output cannot be remapped without lowered units")
	}
	r := newRemapper()
	var want []annotation
	seenShort := map[string]string{}
	var reverify []fileInput
	var aliases [][2]string
	for _, u := range req.Units {
		for _, alias := range u.Aliases {
			aliases = append(aliases, [2]string{alias, u.Short})
		}
		if !validShortName(u.Short) {
			return res, fmt.Errorf("empty/unsafe generated short name: %q", u.Short)
		}
		generated, err := readVerified(root, u.Generated)
		if err != nil {
			return res, err
		}
		mapBytes, err := readVerified(root, u.Map)
		if err != nil {
			return res, err
		}
		m, err := decodeSourceMap(mapBytes)
		if err != nil {
			return res, err
		}
		sources := map[string]sourceBytes{}
		shorts := map[string]string{}
		for _, src := range u.Sources {
			if !validSourceName(src.Name) || !validShortName(src.Short) {
				return res, fmt.Errorf("empty/unsafe source name or short name: %q %q", src.Name, src.Short)
			}
			if _, dup := sources[src.Name]; dup {
				return res, fmt.Errorf("duplicate source name in unit: %s", src.Name)
			}
			data, err := readVerified(root, src.fileInput)
			if err != nil {
				return res, err
			}
			if prior, seen := seenShort[src.Short]; seen {
				if prior != src.SHA256 {
					return res, fmt.Errorf("ambiguous original: short name %q names two different files", src.Short)
				}
			} else {
				seenShort[src.Short] = src.SHA256
				w, err := annotations(data, src.Short)
				if err != nil {
					return res, err
				}
				want = append(want, w...)
			}
			sources[src.Name] = sourceBytes{SHA256: src.SHA256, Data: data}
			shorts[src.Name] = src.Short
			reverify = append(reverify, src.fileInput)
			for _, alias := range src.Aliases {
				aliases = append(aliases, [2]string{alias, src.Short})
			}
		}
		if err := validateSourceMap(m, generated, u.Generated.SHA256, sources); err != nil {
			return res, fmt.Errorf("invalid source map %s: %v", u.Map.Path, err)
		}
		if err := r.add(u.Short, m, shorts); err != nil {
			return res, err
		}
		res.Units++
		reverify = append(reverify, u.Generated, u.Map)
	}
	var output strings.Builder
	for _, o := range req.Output {
		data, err := readVerified(root, o)
		if err != nil {
			return res, err
		}
		// Parse retained streams independently so their boundary is preserved
		// without synthesizing a newline that was never captured.
		messages := splitMessages(string(data))
		for i := range messages {
			for _, pair := range aliases {
				messages[i] = replacePrefix(messages[i], pair[0], pair[1])
			}
		}
		if len(messages) > 0 {
			output.WriteString(strings.Join(messages, "\n"))
			output.WriteByte('\n')
		}
		reverify = append(reverify, o)
	}
	for _, pair := range aliases {
		if pair[0] == "" {
			return res, errors.New("empty path alias")
		}
	}
	aliasTargets := map[string]string{}
	for _, pair := range aliases {
		if prior, ok := aliasTargets[pair[0]]; ok && prior != pair[1] {
			return res, fmt.Errorf("ambiguous path alias %q names %q and %q", pair[0], prior, pair[1])
		}
		aliasTargets[pair[0]] = pair[1]
	}
	var reasons []string
	if len(req.Units) > 0 {
		parsed := parseDiagnostics(output.String())
		remapped, err := r.remapAll(parsed)
		res.Remapped = remapped
		if err != nil {
			return res, err
		}
		match := matchDiagnostics(want, remapped)
		res.Match = &match
		if !match.complete() {
			for _, a := range match.Missing {
				reasons = append(reasons, "missing diagnostic for "+a.String())
			}
			for _, d := range match.Extra {
				reasons = append(reasons, "extra diagnostic "+d.Remapped)
			}
			if len(reasons) == 0 {
				reasons = append(reasons, "diagnostic multiplicity disagrees")
			}
		}
	}
	if req.ExpectedBytes != nil {
		expected, err := readVerified(root, *req.ExpectedBytes)
		if err != nil {
			return res, err
		}
		observed, err := readVerified(root, *req.ObservedBytes)
		if err != nil {
			return res, err
		}
		bytesMatch := matchBytes(expected, observed)
		res.Bytes = &bytesMatch
		if !bytesMatch.Equal {
			reasons = append(reasons, fmt.Sprintf("bytes %s at offset %d (expected %d bytes, observed %d)", bytesMatch.Kind, bytesMatch.FirstDifference, bytesMatch.ExpectedBytes, bytesMatch.ObservedBytes))
		}
		reverify = append(reverify, *req.ExpectedBytes, *req.ObservedBytes)
	}
	if len(reasons) > 0 {
		return res, errors.New(strings.Join(reasons, "; "))
	}
	for _, input := range reverify {
		if _, err := readVerified(root, input); err != nil {
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
		json.NewEncoder(os.Stdout).Encode(response{Verdict: "FAIL", Reason: err.Error(), EvidenceScope: evidenceScope})
		os.Exit(2)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		json.NewEncoder(os.Stdout).Encode(response{Verdict: "FAIL", Reason: "trailing request data", EvidenceScope: evidenceScope})
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
