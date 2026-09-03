package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// inventory is the pinned corpus digest map, keyed by "test/..." path.
//
// The oracle reads source out of a refresh cache that is not under version
// control. Without this check, a locally edited corpus file would be executed
// and reported as an official-corpus result. Every .go file the driver reads —
// the test case AND the files of its .dir directory — is checked against the
// reviewed digest before it is compiled.
type inventory map[string]string

func loadInventory(pathname string) (inventory, error) {
	f, err := os.Open(pathname)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	inv := inventory{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 4 {
			return nil, fmt.Errorf("malformed inventory row: %q", line)
		}
		inv[fields[0]] = fields[3]
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(inv) == 0 {
		return nil, fmt.Errorf("inventory %s has no rows", pathname)
	}
	return inv, nil
}

// verify checks one corpus file's bytes against the reviewed digest. A file the
// inventory does not list is just as fatal as one whose bytes changed: the
// oracle may only execute reviewed corpus source.
func (d *driver) verify(rel string, data []byte) {
	if d.inventory == nil {
		return
	}
	rel = filepath.ToSlash(rel)
	want, ok := d.inventory["test/"+rel]
	if !ok {
		fatalf("corpus file test/%s is not in the reviewed inventory", rel)
	}
	sum := sha256.Sum256(data)
	if got := hex.EncodeToString(sum[:]); got != want {
		fatalf("corpus file test/%s does not match the reviewed inventory\n  expected %s\n  actual   %s", rel, want, got)
	}
}

func sha256hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
