package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// AUXILIARY PROVENANCE.
//
// inventory.go digest-checks the .go files, because docs/go-corpus/inventory.tsv
// covers test/**/*.go. That leaves everything else the driver reads unchecked:
// the sibling "<name>.out", the membership of a "<name>.dir", and any non-.go
// input inside one. Those bytes decide verdicts — a .out IS the expected result
// — so an unchecked .out is an unchecked oracle.
//
// docs/go-oracle/aux-inventory.tsv pins them, including the sidecars upstream
// deliberately does not ship: "absent" is an assertion, because a .out created
// where there was none silently converts "must print nothing" into "must print
// this".
type auxRow struct {
	Role     string
	Path     string
	Present  bool
	Bytes    int64
	SHA256   string
	FileLine int
}

type auxInventory struct {
	path string
	rows map[string]auxRow // keyed by role + "\x00" + path
}

func auxKey(role, p string) string { return role + "\x00" + p }

func loadAuxInventory(pathname string) (*auxInventory, error) {
	f, err := os.Open(pathname)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	inv := &auxInventory{path: pathname, rows: map[string]auxRow{}}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 5 {
			return nil, fmt.Errorf("line %d: expected 5 tab-separated fields, got %d", n, len(fields))
		}
		role, p, presence, byteStr, digest := fields[0], fields[1], fields[2], fields[3], fields[4]
		switch role {
		case "expected_output", "dir_manifest", "dir_input":
		default:
			return nil, fmt.Errorf("line %d: unknown role %q", n, role)
		}
		if !strings.HasPrefix(p, "test/") {
			return nil, fmt.Errorf("line %d: path must be a corpus path: %s", n, p)
		}
		nbytes, err := strconv.ParseInt(byteStr, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("line %d: bad byte count %q", n, byteStr)
		}
		row := auxRow{Role: role, Path: p, Bytes: nbytes, SHA256: digest, FileLine: n}
		switch presence {
		case "present":
			row.Present = true
			if len(digest) != 64 {
				return nil, fmt.Errorf("line %d: present row needs a sha256, got %q", n, digest)
			}
		case "absent":
			if digest != "-" {
				return nil, fmt.Errorf("line %d: absent row must record sha256 \"-\", got %q", n, digest)
			}
			if nbytes != 0 {
				return nil, fmt.Errorf("line %d: absent row must record 0 bytes, got %d", n, nbytes)
			}
		default:
			return nil, fmt.Errorf("line %d: presence must be present or absent, got %q", n, presence)
		}
		key := auxKey(role, p)
		if _, dup := inv.rows[key]; dup {
			return nil, fmt.Errorf("line %d: duplicate %s row for %s", n, role, p)
		}
		inv.rows[key] = row
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	// A zero-row inventory is not rejected here: a tranche whose actions consume
	// no sidecar legitimately pins nothing. Fail-closed lives per file — reading
	// a sidecar with no reviewed row is fatal in verifyExpectedOutput and
	// verifyDirManifest — so an emptied inventory still stops the run, at the
	// first byte it would have had to trust.
	return inv, nil
}

// verifyExpectedOutput checks the sibling "<name>.out" against the reviewed row
// and returns its bytes (nil when upstream ships none). A tranche file whose
// action consumes a .out but which has no reviewed row is fatal: the driver may
// not read an unpinned byte and call the result an official-corpus result.
func (d *driver) verifyExpectedOutput(rel string) []byte {
	name := strings.TrimSuffix(rel, ".go") + ".out"
	key := auxKey("expected_output", "test/"+filepath.ToSlash(name))
	row, ok := d.aux.rows[key]
	if !ok {
		fatalf("auxiliary provenance: test/%s is consumed as expected output but has no row in %s\n"+
			"  Regenerate with tools/go-oracle/select-aux.sh and review the diff.", name, d.aux.path)
	}

	full := filepath.Join(d.gorootTestDir, filepath.FromSlash(name))
	data, err := os.ReadFile(full)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if row.Present {
			fatalf("auxiliary provenance: reviewed expected-output file test/%s is missing from the corpus", name)
		}
		return nil
	case err != nil:
		fatalf("auxiliary provenance: cannot read test/%s: %v", name, err)
	}
	if !row.Present {
		fatalf("auxiliary provenance: test/%s exists but the reviewed inventory records it as absent\n"+
			"  This matters: with no .out file the program's output must be EMPTY, so an\n"+
			"  added .out silently rewrites the expectation.", name)
	}
	if got := sha256hex(data); int64(len(data)) != row.Bytes || got != row.SHA256 {
		fatalf("auxiliary provenance: test/%s does not match the reviewed digest\n"+
			"  expected %d bytes, %s\n  actual   %d bytes, %s",
			name, row.Bytes, row.SHA256, len(data), got)
	}
	return data
}

// dirManifestDigest reproduces tools/go-oracle/select-aux.sh: for every regular
// file under dir, in C order, one "<relpath>\t<sha256>\n" line, digested.
func dirManifestDigest(dir string) (string, int, []string, error) {
	var names []string
	err := filepath.WalkDir(dir, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if e.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		names = append(names, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return "", 0, nil, err
	}
	sort.Strings(names)
	h := sha256.New()
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(name)))
		if err != nil {
			return "", 0, nil, err
		}
		fmt.Fprintf(h, "%s\t%s\n", name, sha256hex(data))
	}
	return hex.EncodeToString(h.Sum(nil)), len(names), names, nil
}

// verifyDirManifest checks a "<name>.dir" as a whole before any of it is
// compiled. The .go members are separately digest-checked against the corpus
// inventory; what this adds is membership — an ADDED file changes the package
// grouping, a DELETED one changes the compile order, and neither is an edit to
// any file the corpus inventory lists.
func (d *driver) verifyDirManifest(dirRel string) {
	key := auxKey("dir_manifest", "test/"+filepath.ToSlash(dirRel))
	row, ok := d.aux.rows[key]
	if !ok {
		fatalf("auxiliary provenance: directory test/%s is compiled but has no dir_manifest row in %s",
			dirRel, d.aux.path)
	}
	full := filepath.Join(d.gorootTestDir, filepath.FromSlash(dirRel))
	digest, count, names, err := dirManifestDigest(full)
	if err != nil {
		fatalf("auxiliary provenance: cannot read directory test/%s: %v", dirRel, err)
	}
	if int64(count) != row.Bytes || digest != row.SHA256 {
		fatalf("auxiliary provenance: directory test/%s does not match the reviewed manifest\n"+
			"  expected %d files, digest %s\n  actual   %d files, digest %s\n  members: %s",
			dirRel, row.Bytes, row.SHA256, count, digest, strings.Join(names, " "))
	}
	// Non-.go members carry their own row, because the corpus inventory only
	// covers *.go and these are still compiler inputs.
	for _, name := range names {
		if path.Ext(name) == ".go" {
			continue
		}
		d.verifyDirInput(path.Join(dirRel, name))
	}
}

func (d *driver) verifyDirInput(rel string) {
	key := auxKey("dir_input", "test/"+filepath.ToSlash(rel))
	row, ok := d.aux.rows[key]
	if !ok {
		fatalf("auxiliary provenance: directory input test/%s has no dir_input row in %s", rel, d.aux.path)
	}
	data, err := os.ReadFile(filepath.Join(d.gorootTestDir, filepath.FromSlash(rel)))
	if err != nil {
		fatalf("auxiliary provenance: cannot read test/%s: %v", rel, err)
	}
	if got := sha256hex(data); int64(len(data)) != row.Bytes || got != row.SHA256 {
		fatalf("auxiliary provenance: test/%s does not match the reviewed digest\n"+
			"  expected %d bytes, %s\n  actual   %d bytes, %s",
			rel, row.Bytes, row.SHA256, len(data), got)
	}
}
