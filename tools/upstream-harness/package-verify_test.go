// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #162; Story: S162.0; Story-ID: cda64bde8fea
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The fixture has two package files because an overlay that maps only a
// convenient entry file can otherwise look plausible while cmd/go compiles an
// original sibling natively.
func TestOverlayProofRequiresEveryPackageFile(t *testing.T) {
	dir := t.TempDir()
	originals := []string{filepath.Join(dir, "one.go"), filepath.Join(dir, "two_test.go")}
	generated := []string{filepath.Join(dir, "one.generated.go"), filepath.Join(dir, "two_test.generated.go")}
	for i := range originals {
		if err := os.WriteFile(originals[i], []byte("package tiny\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(generated[i], []byte("// generated\npackage tiny\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	overlayPath := filepath.Join(dir, "overlay.json")
	overlayData, err := json.Marshal(struct {
		Replace map[string]string `json:"Replace"`
	}{Replace: map[string]string{originals[0]: generated[0], originals[1]: generated[1]}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(overlayPath, overlayData, 0o600); err != nil {
		t.Fatal(err)
	}
	tracePath := filepath.Join(dir, "go-test-n.trace")
	trace := []byte(strings.Join(generated, "\n"))
	if err := os.WriteFile(tracePath, trace, 0o600); err != nil {
		t.Fatal(err)
	}
	p := planRecord{Package: "example/tiny", Overlay: overlayPath, Artifacts: generated}
	p.Program.Packages = []struct {
		Path  string
		Files []string
	}{{Path: "example/tiny", Files: originals}}
	proof := overlayProof{Schema: schema, Kind: "overlay-proof", Package: p.Package, GoTool: "/pinned/go", Overlay: fileProof{Path: overlayPath, SHA256: digest(overlayData)}, Trace: fileProof{Path: tracePath, SHA256: digest(trace)}, CompilerArgv: []string{"/pinned/go", "test", "-overlay=" + overlayPath, p.Package}}
	for i := range originals {
		data, err := os.ReadFile(generated[i])
		if err != nil {
			t.Fatal(err)
		}
		proof.Files = append(proof.Files, struct {
			Original  string `json:"original"`
			Generated string `json:"generated"`
			SHA256    string `json:"sha256"`
		}{originals[i], generated[i], digest(data)})
	}
	if err := verifyOverlay(p, []overlayProof{proof}, p.Package); err != nil {
		t.Fatalf("verifyOverlay: %v", err)
	}
	proof.Files = proof.Files[:1]
	if err := verifyOverlay(p, []overlayProof{proof}, p.Package); err == nil || !strings.Contains(err.Error(), "cover every generated") {
		t.Fatalf("missing sibling error = %v", err)
	}
}
