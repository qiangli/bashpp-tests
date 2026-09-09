// bridgecorpus is the mechanical helper for the bridge-corpus derivation in
// this repository. It exists so the derivation does not reimplement, in
// ambiguous shell, three things that must be exact:
//
//   treehash   the src/ tree digest algorithm of sh's reviewed generator
//              (syntax/gen_go127stdlib.go hashTree). Byte-for-byte the same
//              framing ("len(name):name:len(data):data", slash paths, sorted).
//
//   classify   the import-bridge capability classification of sh's runtime
//              (interp/bashpp_eval.go classifyBashPPPackage), including the
//              decision-table policy (bashPPPolicyFor). The derivation must
//              not drift from the interpreter's own rules, so the order of
//              checks below is copied from that function; any divergence is a
//              defect in this file.
//
//   testfacts  per-file facts for upstream *_test.go files: package clause,
//              black-box vs in-package kind, testing-entrypoint counts,
//              internal-package imports and build constraints. All mechanical,
//              no judgement calls.
//
// It is run with the pinned Go 1.27.0 toolchain by the shell drivers; it has
// no dependencies outside the standard library.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ---- capability vocabulary (mirrors interp.BashPPCapability) ----

const (
	capUnknown        = "unknown"
	capReviewedStdlib = "reviewed-stdlib"
	capExternalPureGo = "external-pure-go"
	capCgo            = "cgo"
	capCompiledOnly   = "compiled-only"
	capNotBuildable   = "not-buildable"
	capUnreviewedStd  = "unreviewed-stdlib"
	capMissing        = "missing"
)

// classify mirrors classifyBashPPPackage's check order exactly.
func classify(facts doc, reviewed map[string]bool) string {
	f := facts.raw()
	if len(f.GoFiles) == 0 && len(f.CgoFiles) == 0 && len(f.IgnoredGoFiles) > 0 {
		return capNotBuildable
	}
	if f.Error != nil || f.Incomplete {
		return capMissing
	}
	if f.Name == "main" {
		return capNotBuildable
	}
	if len(f.GoFiles) == 0 && len(f.CgoFiles) == 0 {
		if len(f.IgnoredGoFiles) > 0 {
			return capNotBuildable
		}
		if f.Dir == "" {
			return capCompiledOnly
		}
		return capNotBuildable
	}
	if len(f.CgoFiles) > 0 {
		return capCgo
	}
	if f.Standard {
		if reviewed[facts.ImportPath] {
			return capReviewedStdlib
		}
		return capUnreviewedStd
	}
	return capExternalPureGo
}

// policyFor mirrors bashPPPolicyFor: only reviewed stdlib and external pure-Go
// packages reach the toolchain adapter; everything else refuses.
func policyFor(c string) string {
	switch c {
	case capReviewedStdlib, capExternalPureGo:
		return "toolchain"
	default:
		return "refuse"
	}
}

// refusal mirrors the runtime's user-facing refusal strings, so obligations
// documentation quotes the shell's own voice instead of a paraphrase.
func refusal(c string) string {
	switch c {
	case capCgo:
		return "package requires cgo, which this pure-Go shell does not provide"
	case capCompiledOnly:
		return "package has no Go source available to build"
	case capNotBuildable:
		return "package is not importable: it is package main, has no buildable Go files, or is excluded on this platform"
	case capUnreviewedStd:
		return "package is not in the reviewed Go standard library"
	case capMissing:
		return "package could not be resolved"
	case capUnknown:
		return "package could not be classified"
	}
	return "package is not supported by any available evaluator"
}

// ---- `go list -e -json` document ----

type listErr struct{ Err string }

// doc carries ImportPath alongside the exact subset of facts sh's runtime
// reads (interp/bashpp_import.go bashPPPackageFacts).
type doc struct {
	ImportPath     string
	Name           string
	Standard       bool
	Dir            string
	GoFiles        []string
	CgoFiles       []string
	IgnoredGoFiles []string
	Incomplete     bool
	Error          *listErr
}

func (d doc) raw() doc { return d }

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "treehash":
		if len(os.Args) != 3 {
			fatal("treehash: want <root>")
		}
		fmt.Println(hashTree(os.Args[2]))
	case "listsha":
		// Digest of the joined inventory list, framed exactly as sh's
		// generator frames it for its inventorySHA256 review constant:
		// strings.Join(paths, "\n") + "\n".
		if len(os.Args) != 3 {
			fatal("listsha: want <list-file>")
		}
		fmt.Println(listSHA(os.Args[2]))
	case "classify":
		if len(os.Args) != 3 {
			fatal("classify: want <reviewed-list-file> (reads `go list -e -json` on stdin)")
		}
		runClassify(os.Args[2])
	case "testfacts":
		if len(os.Args) != 4 {
			fatal("testfacts: want <src-root> <stdlib-inventory.tsv>")
		}
		runTestFacts(os.Args[2], os.Args[3])
	case "refusal":
		if len(os.Args) != 3 {
			fatal("refusal: want <class>")
		}
		fmt.Println(refusal(os.Args[2]))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: bridgecorpus treehash <root> | listsha <list-file> | classify <reviewed-list> | testfacts <src-root> <stdlib-inventory.tsv> | refusal <class>")
	os.Exit(2)
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FATAL: "+format+"\n", args...)
	os.Exit(2)
}

// listSHA hashes strings.Join(paths, "\n") + "\n" over the trimmed,
// non-empty lines of the file — the exact framing of the generator's
// inventorySHA256 review constant.
func listSHA(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		fatal("listsha: %v", err)
	}
	var paths []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			paths = append(paths, line)
		}
	}
	if len(paths) == 0 {
		fatal("listsha: empty list: %s", path)
	}
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(paths, "\n")+"\n")))
}

// ---- treehash (mirrors gen_go127stdlib.go hashTree framing) ----

func hashTree(root string) string {
	var names []string
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			names = append(names, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		fatal("treehash: walk %s: %v", root, err)
	}
	sort.Strings(names)
	var h hash.Hash = sha256.New()
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(name)))
		if err != nil {
			fatal("treehash: %v", err)
		}
		fmt.Fprintf(h, "%d:%s:%d:", len(name), name, len(data))
		h.Write(data)
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

// ---- classify over batched `go list -e -json` output ----

func runClassify(reviewedListFile string) {
	reviewed := map[string]bool{}
	listBytes, err := os.ReadFile(reviewedListFile)
	if err != nil {
		fatal("classify: %v", err)
	}
	for _, line := range strings.Split(string(listBytes), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			reviewed[line] = true
		}
	}
	dec := json.NewDecoder(os.Stdin)
	for {
		var d doc
		if err := dec.Decode(&d); err != nil {
			if err == io.EOF {
				break
			}
			fatal("classify: decode go list json: %v", err)
		}
		capability := classify(d, reviewed)
		listErr := ""
		if d.Error != nil {
			listErr = d.Error.Err
		}
		// Fields: path, name, standard, go_files, cgo_files, ignored_files,
		// incomplete, err_len, capability, policy, list_error (sanitized to
		// one line so the row stays a single TSV line).
		fmt.Printf("%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n",
			d.ImportPath, orDash(d.Name), b01(d.Standard),
			len(d.GoFiles), len(d.CgoFiles), len(d.IgnoredGoFiles),
			b01(d.Incomplete), len(listErr),
			capability, policyFor(capability), sanitize(listErr))
	}
}

type ioEOF struct{}

func (ioEOF) Error() string { return "EOF" }

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func b01(b bool) int {
	if b {
		return 1
	}
	return 0
}

// sanitize keeps a TSV field single-line.
func sanitize(s string) string {
	return strings.NewReplacer("\t", " ", "\n", " ", "\r", " ").Replace(s)
}

// ---- testfacts ----

var (
	packageRe  = regexp.MustCompile(`(?m)^package\s+([A-Za-z_][A-Za-z0-9_]*)`)
	testRe     = regexp.MustCompile(`(?m)^func\s+Test[A-Z][A-Za-z0-9_]*\s*\(`)
	benchRe    = regexp.MustCompile(`(?m)^func\s+Benchmark[A-Z][A-Za-z0-9_]*\s*\(`)
	exampleRe  = regexp.MustCompile(`(?m)^func\s+Example[A-Z][A-Za-z0-9_]*\s*\(`)
	fuzzRe     = regexp.MustCompile(`(?m)^func\s+Fuzz[A-Z][A-Za-z0-9_]*\s*\(`)
	buildTagRe = regexp.MustCompile(`(?m)^//go:build\s+`)
	// Quoted strings that look like import paths (letters, digits, punct,
	// and GOOS/GOARCH expansion braces as used by net/http tests etc).
	quotedRe = regexp.MustCompile(`"([A-Za-z0-9_\-./~+]+|\{[A-Za-z0-9_,\-]+\})+`)
)

// internalImport reports whether an import path contains an `internal`
// element anywhere — Go's internal-package rule applied per path element.
func internalImport(path string) bool {
	for _, elem := range strings.Split(path, "/") {
		if elem == "internal" {
			return true
		}
	}
	return false
}

func runTestFacts(srcRoot, invPath string) {
	// path -> go list package name, for black-box vs in-package classification.
	pkgName := map[string]string{}
	invBytes, err := os.ReadFile(invPath)
	if err != nil {
		fatal("testfacts: %v", err)
	}
	for _, line := range strings.Split(string(invBytes), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 2 {
			fatal("testfacts: malformed stdlib-inventory row: %q", line)
		}
		pkgName[fields[0]] = fields[1]
	}
	dirs := make([]string, 0, len(pkgName))
	for path := range pkgName {
		dirs = append(dirs, path)
	}
	sort.Strings(dirs)
	for _, pkgPath := range dirs {
		dir := filepath.Join(srcRoot, filepath.FromSlash(pkgPath))
		entries, err := os.ReadDir(dir)
		if err != nil {
			fatal("testfacts: read %s: %v", dir, err)
		}
		files := make([]string, 0, len(entries))
		for _, e := range entries {
			if !e.IsDir() && strings.HasSuffix(e.Name(), "_test.go") {
				files = append(files, e.Name())
			}
		}
		sort.Strings(files)
		name := pkgName[pkgPath]
		for _, file := range files {
			rel := pkgPath + "/" + file
			data, err := os.ReadFile(filepath.Join(dir, file))
			if err != nil {
				fatal("testfacts: %v", err)
			}
			clause := "-"
			if m := packageRe.FindSubmatch(data); m != nil {
				clause = string(m[1])
			}
			kind := "other"
			switch {
			case clause == name+"_test":
				kind = "black_box"
			case clause == name:
				kind = "in_package"
			}
			internal := 0
			for _, m := range quotedRe.FindAllStringSubmatch(string(data), -1) {
				if internalImport(m[1]) {
					internal++
				}
			}
			// Fields: path, package_clause, kind, bytes, sha256, tests,
			// benchmarks, examples, fuzz_targets, internal_imports,
			// build_constraint.
			fmt.Printf("%s\t%s\t%s\t%d\t%x\t%d\t%d\t%d\t%d\t%d\t%d\n",
				rel, clause, kind, len(data), sha256.Sum256(data),
				countMatches(data, testRe), countMatches(data, benchRe),
				countMatches(data, exampleRe), countMatches(data, fuzzRe),
				internal, b01(buildTagRe.Match(data)))
		}
	}
}

func countMatches(data []byte, re *regexp.Regexp) int {
	return len(re.FindAll(data, -1))
}
