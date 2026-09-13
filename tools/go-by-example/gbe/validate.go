// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Offline fail-closed gate for the pinned Go by Example corpus, ported from
// tools/go-by-example/validate.sh, plus the inventory re-derivation of
// refresh.sh.
//
// What the rejected first cut did, and why it was not enough: it compared a
// COUNT (`rows` vs `find | wc -l`). A count is satisfied by any same-size set,
// so renaming a file, swapping two paths, or dropping one row while adding an
// unrelated one all passed. This validator derives the exact normalized path
// SET from disk and compares it to the inventory SET element by element, then
// verifies every copied byte. Counts are checked too, but only as a redundant
// cross-check against the pin.
//
// Overridable inputs exist so the tamper tests can feed mutated tables without
// editing the checked-in ones.
package main

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type validateExit struct{ code int }

func validateDie(message string) {
	fmt.Fprintln(os.Stderr, "FATAL: "+message)
	panic(validateExit{2})
}

// awk `NF` on a default-FS line: true when the line holds any non-blank text.
func awkNF(line string) bool { return strings.TrimSpace(line) != "" }

// tsvDataLines returns the raw data lines of a table (comment and blank lines
// removed) split on tabs, preserving trailing empty fields like awk -F '\t'.
func tsvDataLines(path string) ([][]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, line := range rubyLinesChomp(string(data)) {
		fields := strings.Split(line, "\t")
		if strings.HasPrefix(fields[0], "#") || line == "" {
			continue
		}
		rows = append(rows, fields)
	}
	return rows, nil
}

type schemaTables struct {
	behaviors      map[string][2]string // requires, allows
	adapters       map[string]bool
	normalizations map[string]bool
}

var (
	reDate       = regexp.MustCompile(`\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z`)
	reLowerHex   = regexp.MustCompile(`\A[0-9a-f]+\z`)
	reDigits     = regexp.MustCompile(`\A[0-9]+\z`)
	reBadState   = regexp.MustCompile(`(^|\t)(n/a|N/A|PLANNED|planned|unsupported|skip|skipped|exception)(\t|$)`)
	rePathChars  = regexp.MustCompile(`[^A-Za-z0-9._/-]`)
	reDotDot     = regexp.MustCompile(`(^|/)\.\.(/|$)`)
	reDot        = regexp.MustCompile(`(^|/)\.(/|$)`)
	reKind       = regexp.MustCompile(`^(program|test_program|runtime_asset|provenance)$`)
	reDriveQual  = regexp.MustCompile(`^[A-Za-z]:`)
	reGoSuffix   = regexp.MustCompile(`\.go$`)
	reTestSuffix = regexp.MustCompile(`_test\.go$`)
)

func loadSchema(path string) *schemaTables {
	rows, err := tsvDataLines(path)
	if err != nil {
		validateDie("behavior schema table is malformed: " + path)
	}
	s := &schemaTables{behaviors: map[string][2]string{}, adapters: map[string]bool{}, normalizations: map[string]bool{}}
	bad := false
	warn := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "FATAL: "+format+"\n", args...)
		bad = true
	}
	for nr, r := range rows {
		switch r[0] {
		case "behavior":
			if len(r) != 4 {
				warn("behavior row %d must have 4 fields", nr+1)
				continue
			}
			if _, dup := s.behaviors[r[1]]; dup {
				warn("duplicate behavior %s", r[1])
			}
			s.behaviors[r[1]] = [2]string{r[2], r[3]}
		case "adapter":
			if len(r) != 4 {
				warn("adapter row %d must have 4 fields", nr+1)
				continue
			}
			if s.adapters[r[1]] {
				warn("duplicate adapter %s", r[1])
			}
			if r[3] == "" {
				warn("adapter %s has no description", r[1])
			}
			s.adapters[r[1]] = true
		case "normalization":
			if len(r) != 4 {
				warn("normalization row %d must have 4 fields", nr+1)
				continue
			}
			if s.normalizations[r[1]] {
				warn("duplicate normalization %s", r[1])
			}
			if r[3] == "" {
				warn("normalization %s has no description", r[1])
			}
			s.normalizations[r[1]] = true
		default:
			warn("unknown schema record type %s at row %d", r[0], nr+1)
		}
	}
	if len(s.behaviors) == 0 || len(s.adapters) == 0 || len(s.normalizations) == 0 {
		warn("schema vocabularies incomplete")
	}
	if !s.adapters["none"] || !s.normalizations["none"] {
		warn("schema must declare the none adapter and none normalization")
	}
	if _, ok := s.behaviors["deterministic"]; !ok {
		warn("schema must declare the deterministic behavior")
	}
	// every required adapter and allowed normalization must itself be declared
	names := make([]string, 0, len(s.behaviors))
	for b := range s.behaviors {
		names = append(names, b)
	}
	sort.Strings(names)
	for _, b := range names {
		for _, a := range strings.Split(s.behaviors[b][0], ",") {
			if !s.adapters[a] {
				warn("behavior %s requires undeclared adapter %s", b, a)
			}
		}
		for _, n := range strings.Split(s.behaviors[b][1], ",") {
			if !s.normalizations[n] {
				warn("behavior %s allows undeclared normalization %s", b, n)
			}
		}
	}
	if bad {
		validateDie("behavior schema table is malformed: " + path)
	}
	return s
}

func inSet(commaJoined, member string) bool {
	return strings.Contains(","+commaJoined+",", ","+member+",")
}

// checkRows applies the row-shape and coupling checks identically to the
// authored classification table and to the derived inventory.
func checkRows(path string, nf int, label string, s *schemaTables) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %s: unreadable: %s\n", label, path)
		return false
	}
	bad := false
	fail := func(fnr int, msg string) {
		fmt.Fprintf(os.Stderr, "FATAL: %s: %s (row %d)\n", label, msg, fnr)
		bad = true
	}
	seen := map[string]bool{}
	prev := ""
	for i, line := range rubyLinesChomp(string(data)) {
		fnr := i + 1
		fields := strings.Split(line, "\t")
		if strings.HasPrefix(fields[0], "#") || line == "" {
			continue
		}
		if len(fields) != nf {
			fail(fnr, fmt.Sprintf("expected %d fields, found %d", nf, len(fields)))
			continue
		}
		checkset := func(val string, vocab map[string]bool, what string) {
			if val == "" {
				fail(fnr, what+" is empty")
				return
			}
			parts := strings.Split(val, ",")
			for i, p := range parts {
				if p == "" {
					fail(fnr, what+" has an empty member")
					return
				}
				if !vocab[p] {
					fail(fnr, what+" uses undeclared term "+p)
					return
				}
				if i > 0 && p <= parts[i-1] {
					fail(fnr, what+" must be sorted and duplicate-free: "+val)
					return
				}
			}
		}
		p := fields[0]
		// --- path safety: exact normalized repo-relative path, nothing else ---
		if strings.HasPrefix(p, "/") {
			fail(fnr, "absolute path: "+p)
		}
		if reDriveQual.MatchString(p) {
			fail(fnr, "drive-qualified path: "+p)
		}
		if strings.Contains(p, `\`) {
			fail(fnr, "backslash in path: "+p)
		}
		if strings.Contains(p, "//") {
			fail(fnr, "empty path component: "+p)
		}
		if strings.HasSuffix(p, "/") {
			fail(fnr, "trailing slash: "+p)
		}
		if reDotDot.MatchString(p) {
			fail(fnr, "parent traversal: "+p)
		}
		if reDot.MatchString(p) {
			fail(fnr, "dot component: "+p)
		}
		if strings.HasPrefix(p, "~") {
			fail(fnr, "home-relative path: "+p)
		}
		if rePathChars.MatchString(p) {
			fail(fnr, "path outside the permitted character set: "+p)
		}
		if !strings.HasPrefix(p, "examples/") {
			fail(fnr, "path outside the pinned examples/ tree: "+p)
		}
		if seen[p] {
			fail(fnr, "duplicate path: "+p)
		}
		seen[p] = true
		if prev != "" && p <= prev {
			fail(fnr, "path order regression (inventory must be a sorted set): "+p)
		}
		prev = p
		if !reKind.MatchString(fields[1]) {
			fail(fnr, "invalid kind: "+fields[1])
		}
		kind, behavior, normalization, adapter, requires := fields[1], fields[2], fields[3], fields[4], fields[5]
		if kind == "runtime_asset" || kind == "provenance" {
			// Structural, not failure-derived: a .txt asset is not a program, so it
			// has no behavior to classify. The gate never "discovers" this state.
			if behavior != "not_a_program" || normalization != "not_a_program" || adapter != "not_a_program" {
				fail(fnr, "non-program row must use not_a_program on all three axes: "+p)
			}
			if requires != "none" {
				fail(fnr, "non-program row must not declare requires: "+p)
			}
			if kind == "provenance" && !strings.HasSuffix(p, ".md") {
				fail(fnr, "provenance row must be the upstream README: "+p)
			}
			if kind == "runtime_asset" && reGoSuffix.MatchString(p) {
				fail(fnr, "runtime asset must not be a .go file: "+p)
			}
		} else {
			if !reGoSuffix.MatchString(p) {
				fail(fnr, "program row must be a .go file: "+p)
			}
			if kind == "test_program" && !reTestSuffix.MatchString(p) {
				fail(fnr, "test_program row must be a _test.go file: "+p)
			}
			if kind == "program" && reTestSuffix.MatchString(p) {
				fail(fnr, "_test.go file must be kind test_program: "+p)
			}
			if strings.Contains(behavior, "not_a_program") || strings.Contains(normalization, "not_a_program") || strings.Contains(adapter, "not_a_program") {
				fail(fnr, "program row must not use not_a_program: "+p)
			}
			// An N/A that a failing run could produce is exactly what is banned.
			if reBadState.MatchString(line) {
				fail(fnr, "failure-derived or deferred state is not a valid classification: "+p)
			}
			behaviorVocab := map[string]bool{}
			for b := range s.behaviors {
				behaviorVocab[b] = true
			}
			checkset(behavior, behaviorVocab, "behavior")
			checkset(normalization, s.normalizations, "normalization")
			checkset(adapter, s.adapters, "adapter")

			bs := strings.Split(behavior, ",")
			if inSet(behavior, "deterministic") && len(bs) != 1 {
				fail(fnr, "deterministic is exclusive and cannot be combined: "+behavior)
			}
			if inSet(behavior, "deterministic") && (normalization != "none" || adapter != "none") {
				fail(fnr, "a deterministic row must compare raw bytes with no adapter: "+p)
			}
			if (kind == "test_program") != inSet(behavior, "test_harness") {
				fail(fnr, "test_harness behavior and test_program kind must agree: "+p)
			}
			// --- coupling: every declared behavior requires its adapters ---
			for _, b := range bs {
				req := s.behaviors[b][0]
				if req == "none" {
					continue
				}
				for _, r := range strings.Split(req, ",") {
					if !inSet(adapter, r) {
						fail(fnr, "behavior "+b+" requires adapter "+r+", missing on "+p)
					}
				}
			}
			// --- no unlicensed adapter ---
			for _, a := range strings.Split(adapter, ",") {
				if a == "none" {
					continue
				}
				ok := false
				for _, b := range bs {
					if inSet(s.behaviors[b][0], a) {
						ok = true
					}
				}
				if !ok {
					fail(fnr, "adapter "+a+" is not required by any declared behavior on "+p)
				}
			}
			// --- no unlicensed normalization (normalization only where licensed) ---
			for _, n := range strings.Split(normalization, ",") {
				if n == "none" {
					continue
				}
				if n == "closing_channel_order" {
					if p != "examples/closing-channels/closing-channels.go" || normalization != "closing_channel_order" {
						fail(fnr, "closing_channel_order is bound exclusively to the reviewed closing-channels row")
					}
					if len(fields) == 8 && fields[7] != "b2ddb4aa5bce6a532fc9bc29e67800e1a31f8da7fb7131f4ee8bde7eecfbe15c" {
						fail(fnr, "closing_channel_order source digest is not the reviewed program")
					}
				}
				ok := false
				for _, b := range bs {
					if inSet(s.behaviors[b][1], n) {
						ok = true
					}
				}
				if !ok {
					fail(fnr, "normalization "+n+" is not licensed by any declared behavior on "+p)
				}
			}
			if adapter != "none" && inSet(adapter, "none") {
				fail(fnr, "none cannot be combined with a real adapter: "+p)
			}
			if normalization != "none" && inSet(normalization, "none") {
				fail(fnr, "none cannot be combined with a real normalization: "+p)
			}
		}
		if requires != "none" {
			rq := strings.Split(requires, ",")
			for i, r := range rq {
				if !strings.HasPrefix(r, "examples/") {
					fail(fnr, "requires entry outside examples/: "+r)
				}
				if reDotDot.MatchString(r) || strings.HasPrefix(r, "/") {
					fail(fnr, "unsafe requires entry: "+r)
				}
				if i > 0 && r <= rq[i-1] {
					fail(fnr, "requires must be sorted and duplicate-free: "+requires)
				}
			}
		}
	}
	return !bad
}

// validateMain is validate.sh: exit status 0 on success, 2 on any rejection.
func validateMain(args []string, out io.Writer) (code int) {
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(validateExit); ok {
				code = e.code
				return
			}
			panic(r)
		}
	}()
	docs := DOCS
	pin := envOr("GBE_PIN", docs+"/pin.tsv")
	inv := envOr("GBE_INVENTORY", docs+"/inventory.tsv")
	cls := envOr("GBE_CLASSIFICATION", docs+"/classification.tsv")
	schemaPath := envOr("GBE_SCHEMA", docs+"/behavior-schema.tsv")
	corpus := envOr("GBE_CORPUS", ROOT+"/examples")
	// Inventory paths are repo-relative and all start with examples/, so file
	// lookups resolve against the corpus PARENT. Keeping this indirection lets
	// the tamper tests point the validator at a mutated copy of the tree.
	base := expandPath(filepath.Dir(corpus))
	if filepath.Base(corpus) != "examples" {
		validateDie("corpus directory must be named examples/, got " + filepath.Base(corpus))
	}
	for _, f := range []string{pin, inv, cls, schemaPath} {
		if !isRegularFile(f) {
			validateDie("missing required table: " + f)
		}
	}
	if !isDir(corpus) {
		validateDie("missing corpus tree: " + corpus)
	}

	// 1. Pin: provenance for the exact upstream commit.
	pinRows, err := tsvDataLines(pin)
	if err != nil {
		validateDie("missing required table: " + pin)
	}
	if len(pinRows) != 1 {
		validateDie(fmt.Sprintf("pin must contain exactly one data row, found %d", len(pinRows)))
	}
	if len(pinRows[0]) != 9 {
		validateDie(fmt.Sprintf("pin row must have 9 fields, found %d", len(pinRows[0])))
	}
	repo, commit, observed, license, provenance := pinRows[0][0], pinRows[0][1], pinRows[0][2], pinRows[0][3], pinRows[0][4]
	wantClsRows, wantInvRows, wantDataSHA, wantGoFiles := pinRows[0][5], pinRows[0][6], pinRows[0][7], pinRows[0][8]
	if repo != "https://github.com/mmcgrana/gobyexample.git" {
		validateDie("pin repository must be the upstream Go by Example repository, got: " + repo)
	}
	if !reLowerHex.MatchString(commit) {
		validateDie("pin commit must be lowercase hex")
	}
	if len(commit) != 40 {
		validateDie(fmt.Sprintf("pin commit must be a 40-character sha1, got %d", len(commit)))
	}
	if commit != "7d705626375ba0263b616865a286e1587d6989c8" {
		validateDie("pin commit drifted from the reviewed Sprint 98 pin")
	}
	if !reDate.MatchString(observed) {
		validateDie("pin observed must be YYYY-MM-DD")
	}
	if license != "CC-BY-3.0" {
		validateDie("pin must preserve the upstream CC BY 3.0 grant")
	}
	if provenance == "" {
		validateDie("pin provenance is required")
	}
	if !reDigits.MatchString(wantClsRows + wantInvRows + wantGoFiles) {
		validateDie("pin row counts must be integers")
	}
	if wantGoFiles != "85" {
		validateDie("pin upstream_go_files must be the 85 .go files present at the pinned commit, got " + wantGoFiles)
	}
	if !reLowerHex.MatchString(wantDataSHA) {
		validateDie("pin inventory_data_sha256 must be lowercase hex")
	}
	if len(wantDataSHA) != 64 {
		validateDie("pin inventory_data_sha256 must be 64 hex characters")
	}

	// 2. Schema: vocabularies and behavior->adapter/normalization coupling.
	schema := loadSchema(schemaPath)

	// 3. Row-shape and coupling checks.
	if !checkRows(cls, 6, "classification.tsv", schema) {
		validateDie("classification table rejected")
	}
	if !checkRows(inv, 8, "inventory.tsv", schema) {
		validateDie("inventory table rejected")
	}

	// 4. Inventory headers and data digest.
	invData, err := os.ReadFile(inv)
	if err != nil {
		validateDie("missing required table: " + inv)
	}
	invLines := rubyLinesChomp(string(invData))
	expectHeader := func(key, want string) {
		for _, line := range invLines {
			fields := strings.Split(line, "\t")
			if fields[0] == "# "+key {
				got := ""
				if len(fields) > 1 {
					got = fields[1]
				}
				if got != want {
					validateDie(fmt.Sprintf("inventory # %s header mismatch: expected %s, got %s", key, want, got))
				}
				return
			}
		}
		validateDie("inventory is missing the # " + key + " header")
	}
	expectHeader("repository", repo)
	expectHeader("commit", commit)
	expectHeader("observed", observed)
	expectHeader("license", license)
	expectHeader("generated_by", "tools/go-by-example/refresh.sh")
	expectHeader("derived_from", "docs/go-by-example/classification.tsv")
	var dataText strings.Builder
	for _, line := range invLines {
		if !strings.HasPrefix(line, "#") && awkNF(line) {
			dataText.WriteString(line + "\n")
		}
	}
	dataSHA := sha256Hex([]byte(dataText.String()))
	if dataSHA != wantDataSHA {
		validateDie("inventory data digest mismatch: pin says " + wantDataSHA + ", computed " + dataSHA)
	}

	// 5. Exact normalized path SET comparisons.
	//    classification set == inventory set == on-disk set.
	//    A count check cannot see a substitution; a set difference always can.
	pathSet := func(path string) []string {
		rows, _ := tsvDataLines(path)
		var out []string
		for _, r := range rows {
			out = append(out, r[0])
		}
		sort.Strings(out)
		return out
	}
	clsSet := pathSet(cls)
	invSet := pathSet(inv)
	// Derive the on-disk set the same way the inventory spells it: repo-relative,
	// no leading ./, sorted. Regular files only: a symlink is not a copied source byte.
	var diskSet, strays []string
	filepath.WalkDir(filepath.Join(base, "examples"), func(path string, d fs.DirEntry, err error) error {
		if err != nil || path == filepath.Join(base, "examples") {
			return nil
		}
		rel, _ := filepath.Rel(base, path)
		st, lerr := os.Lstat(path)
		if lerr != nil {
			return nil
		}
		switch {
		case st.Mode().IsRegular():
			diskSet = append(diskSet, rel)
		case st.IsDir():
		default:
			strays = append(strays, rel)
		}
		return nil
	})
	sort.Strings(diskSet)
	if len(diskSet) == 0 {
		validateDie("no files found under " + corpus + " — the corpus did not load")
	}
	reportSetdiff := func(a, b []string, aLabel, bLabel string) bool {
		onlyA := sortedDifference(a, b)
		onlyB := sortedDifference(b, a)
		if len(onlyA) == 0 && len(onlyB) == 0 {
			return true
		}
		if len(onlyA) > 0 {
			fmt.Fprintf(os.Stderr, "FATAL: present in %s but not in %s:\n%s\n", aLabel, bLabel, strings.Join(onlyA, "\n"))
		}
		if len(onlyB) > 0 {
			fmt.Fprintf(os.Stderr, "FATAL: present in %s but not in %s:\n%s\n", bLabel, aLabel, strings.Join(onlyB, "\n"))
		}
		return false
	}
	if !reportSetdiff(clsSet, invSet, "classification.tsv", "inventory.tsv") {
		validateDie("classification and inventory path sets differ")
	}
	if !reportSetdiff(invSet, diskSet, "inventory.tsv", "the corpus tree") {
		validateDie("inventory and on-disk path sets differ (missing or extra rows/files)")
	}
	// Symlinks and non-regular entries must not exist at all in the corpus tree.
	if len(strays) > 0 {
		validateDie("corpus contains non-regular files: " + strings.Join(strays, "\n"))
	}

	// 6. Every copied source byte is verified, not just counted.
	verified := 0
	invRows, _ := tsvDataLines(inv)
	for _, r := range invRows {
		path, bytes, digestWant := r[0], r[6], r[7]
		f := base + "/" + path
		if !isRegularFile(f) {
			validateDie("inventory row has no file: " + path)
		}
		actualBytes := strconv.FormatInt(fileSize(f), 10)
		if actualBytes != bytes {
			validateDie("byte-count drift on " + path + ": inventory " + bytes + ", file " + actualBytes)
		}
		actualDigest := sha(f)
		if actualDigest != digestWant {
			validateDie("content drift on " + path + ": inventory " + digestWant + ", file " + actualDigest)
		}
		verified++
	}

	// 7. Classification columns of the derived inventory must equal the authored
	//    table exactly, and the two must agree row for row.
	clsRows, _ := tsvDataLines(cls)
	firstSix := func(rows [][]string) string {
		var b strings.Builder
		for _, r := range rows {
			n := 6
			if len(r) < n {
				n = len(r)
			}
			b.WriteString(strings.Join(r[:n], "\t") + "\n")
		}
		return b.String()
	}
	if firstSix(invRows) != firstSix(clsRows) {
		validateDie("inventory classification columns do not match the authored classification table")
	}

	// 8. Runtime-asset closure: every required asset is an inventoried asset row,
	//    and every asset row is required by at least one program.
	kindOf := map[string]string{}
	needed := map[string]string{}
	var neededOrder []string
	for _, r := range invRows {
		kindOf[r[0]] = r[1]
		if r[5] != "none" {
			for _, rq := range strings.Split(r[5], ",") {
				if _, ok := needed[rq]; !ok {
					neededOrder = append(neededOrder, rq)
				}
				needed[rq] = r[0]
			}
		}
	}
	closureBad := false
	for _, p := range neededOrder {
		if _, ok := kindOf[p]; !ok {
			fmt.Fprintf(os.Stderr, "FATAL: %s requires uninventoried asset %s\n", needed[p], p)
			closureBad = true
			continue
		}
		if kindOf[p] != "runtime_asset" {
			fmt.Fprintf(os.Stderr, "FATAL: %s requires %s which is kind %s, not runtime_asset\n", needed[p], p, kindOf[p])
			closureBad = true
		}
	}
	for _, r := range invRows {
		if r[1] == "runtime_asset" {
			if _, ok := needed[r[0]]; !ok {
				fmt.Fprintf(os.Stderr, "FATAL: runtime asset %s is not required by any program row\n", r[0])
				closureBad = true
			}
		}
	}
	if closureBad {
		validateDie("runtime-asset closure failed")
	}

	// 9. Redundant count cross-check against the pin.
	goFiles := 0
	for _, p := range invSet {
		if strings.HasSuffix(p, ".go") {
			goFiles++
		}
	}
	if strconv.Itoa(len(clsSet)) != wantClsRows {
		validateDie(fmt.Sprintf("classification row count %d != pinned %s", len(clsSet), wantClsRows))
	}
	if strconv.Itoa(len(invSet)) != wantInvRows {
		validateDie(fmt.Sprintf("inventory row count %d != pinned %s", len(invSet), wantInvRows))
	}
	if strconv.Itoa(goFiles) != wantGoFiles {
		validateDie(fmt.Sprintf("corpus holds %d .go files, pin says %s", goFiles, wantGoFiles))
	}
	if verified != len(invSet) {
		validateDie(fmt.Sprintf("verified %d files but inventory has %d rows", verified, len(invSet)))
	}
	programs, assets := 0, 0
	for _, r := range invRows {
		switch r[1] {
		case "program", "test_program":
			programs++
		case "runtime_asset":
			assets++
		}
	}
	fmt.Fprintf(out, "Go by Example inventory OK: %s — %d/%d files verified (%d programs, %d runtime assets, %d .go)\n", commit, verified, len(invSet), programs, assets, goFiles)
	return 0
}

func sortedDifference(a, b []string) []string {
	inB := map[string]bool{}
	for _, x := range b {
		inB[x] = true
	}
	var out []string
	for _, x := range a {
		if !inB[x] {
			out = append(out, x)
		}
	}
	return out
}

// refreshMain is refresh.sh: re-derive docs/go-by-example/inventory.tsv from
// the authored classification table plus the measured bytes of the copied
// corpus. With GBE_ROOT -- a clone of mmcgrana/gobyexample checked out at the
// pinned commit -- it additionally proves the copy against upstream.
func refreshMain(args []string) {
	die := func(message string) {
		fmt.Fprintln(os.Stderr, "FATAL: "+message)
		os.Exit(2)
	}
	cls := DOCS + "/classification.tsv"
	pin := DOCS + "/pin.tsv"
	toStdout := false
	gbeRoot := ""
	for _, a := range args {
		switch {
		case a == "--inventory-only":
			toStdout = true
		case strings.HasPrefix(a, "-"):
			die("unknown option: " + a)
		default:
			if gbeRoot != "" {
				die("at most one GBE_ROOT may be given")
			}
			gbeRoot = a
		}
	}
	if !isRegularFile(cls) {
		die("missing classification table: " + cls)
	}
	if !isRegularFile(pin) {
		die("missing pin: " + pin)
	}
	pinRows, _ := tsvDataLines(pin)
	if len(pinRows) == 0 || len(pinRows[0]) < 4 || pinRows[0][1] == "" {
		die("pin has no commit")
	}
	repo, commit, observed, license := pinRows[0][0], pinRows[0][1], pinRows[0][2], pinRows[0][3]
	clsRows, _ := tsvDataLines(cls)

	if gbeRoot != "" {
		if !isDir(gbeRoot) {
			die("GBE_ROOT is not a directory: " + gbeRoot)
		}
		if !isDir(gbeRoot + "/examples") {
			die("GBE_ROOT has no examples/ tree: " + gbeRoot)
		}
		if !isRegularFile(gbeRoot + "/README.md") {
			die("GBE_ROOT has no README.md (license provenance)")
		}
		if _, err := exec.LookPath("git"); err == nil && isDir(gbeRoot+"/.git") {
			actual, ok := gitOutput(gbeRoot, "rev-parse", "HEAD")
			if !ok || strings.TrimSpace(actual) != commit {
				die("GBE_ROOT commit mismatch: expected " + commit + ", got " + strings.TrimSpace(actual))
			}
		}
		var upstreamGo []string
		filepath.WalkDir(gbeRoot+"/examples", func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if st, e := os.Lstat(path); e == nil && st.Mode().IsRegular() && strings.HasSuffix(path, ".go") {
				rel, _ := filepath.Rel(gbeRoot, path)
				upstreamGo = append(upstreamGo, rel)
			}
			return nil
		})
		sort.Strings(upstreamGo)
		var classifiedGo []string
		for _, r := range clsRows {
			if r[1] == "program" || r[1] == "test_program" {
				classifiedGo = append(classifiedGo, r[0])
			}
		}
		if strings.Join(upstreamGo, "\n") != strings.Join(classifiedGo, "\n") {
			var diff []string
			for _, p := range sortedDifference(upstreamGo, classifiedGo) {
				diff = append(diff, "< "+p)
			}
			for _, p := range sortedDifference(classifiedGo, upstreamGo) {
				diff = append(diff, "> "+p)
			}
			die("upstream examples/**/*.go set differs from the classified program rows (< upstream, > classification):\n" + strings.Join(diff, "\n"))
		}
		for _, r := range clsRows {
			path, kind := r[0], r[1]
			src := gbeRoot + "/" + path
			if kind == "provenance" {
				src = gbeRoot + "/README.md"
			}
			if !isRegularFile(src) {
				die("upstream source missing for " + path + ": " + src)
			}
			if !isRegularFile(ROOT + "/" + path) {
				die("corpus copy missing: " + path)
			}
			a, _ := os.ReadFile(src)
			b, _ := os.ReadFile(ROOT + "/" + path)
			if string(a) != string(b) {
				die("copied bytes differ from upstream: " + path)
			}
		}
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# repository\t%s\n", repo)
	fmt.Fprintf(&b, "# commit\t%s\n", commit)
	fmt.Fprintf(&b, "# observed\t%s\n", observed)
	fmt.Fprintf(&b, "# license\t%s\n", license)
	b.WriteString("# generated_by\ttools/go-by-example/refresh.sh\n")
	b.WriteString("# derived_from\tdocs/go-by-example/classification.tsv\n")
	b.WriteString("# path\tkind\tbehavior\tnormalization\tadapter\trequires\tbytes\tsha256\n")
	for _, r := range clsRows {
		f := ROOT + "/" + r[0]
		if !isRegularFile(f) {
			die("classified path is not a regular file in the corpus: " + r[0])
		}
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", r[0], r[1], r[2], r[3], r[4], r[5], fileSize(f), sha(f))
	}
	if toStdout {
		fmt.Print(b.String())
		return
	}
	tmp, err := os.CreateTemp(DOCS, ".inventory.*.tsv")
	if err != nil {
		die(err.Error())
	}
	tmp.WriteString(b.String())
	tmp.Close()
	if err := os.Rename(tmp.Name(), DOCS+"/inventory.tsv"); err != nil {
		die(err.Error())
	}
	fmt.Println("wrote " + DOCS + "/inventory.tsv")
}
