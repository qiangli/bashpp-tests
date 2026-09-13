// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #162; Story: S162.0; Story-ID: cda64bde8fea
package test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestLibraryOverlayUsesOneInvocationAndAllFileClasses(t *testing.T) {
	dir := t.TempDir()
	files := []bashppPackageFile{
		{path: filepath.Join(dir, "a.go"), flag: "--go-file"},
		{path: filepath.Join(dir, "a_test.go"), flag: "--go-test-file"},
		{path: filepath.Join(dir, "external_test.go"), flag: "--go-xtest-file"},
	}
	args := bashppLibraryArgs(files)
	if want := []string{"--go-file", files[0].path, "--go-test-file", files[1].path, "--go-xtest-file", files[2].path}; !sameStrings(args, want) {
		t.Fatalf("library args = %v, want %v", args, want)
	}
	libraryDir := filepath.Join(dir, "library")
	generated, err := bashppLibraryOutputNames(libraryDir, files)
	if err != nil {
		t.Fatal(err)
	}
	transcript := filepath.Join(dir, "library-output.txt")
	data := "library " + files[0].path + " -> " + generated[0] + "\n" +
		"library " + files[1].path + " -> " + generated[1] + "\n" +
		"library " + files[2].path + " -> " + generated[2] + "\n"
	if err := os.WriteFile(transcript, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	overlay := filepath.Join(dir, "overlay.json")
	script := bashppLibraryOverlayScript(transcript, overlay, []string{files[0].path, files[1].path, files[2].path}, generated)
	if err := exec.Command("/bin/sh", "-c", script).Run(); err != nil {
		t.Fatalf("library transcript validation: %v\n%s", err, script)
	}
	var got struct {
		Replace map[string]string
	}
	overlayData, err := os.ReadFile(overlay)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(overlayData, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Replace) != len(files) {
		t.Fatalf("overlay replacements = %v, want %d entries", got.Replace, len(files))
	}
	for i, file := range files {
		if got.Replace[file.path] != generated[i] {
			t.Errorf("overlay[%q] = %q, want %q", file.path, got.Replace[file.path], generated[i])
		}
	}
}

func sameStrings(a, b []string) bool {
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
