package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"
)

// trancheActions is the action set this slice commits to EXECUTING. It is seven
// of the pinned upstream runner's seventeen; the other ten are enumerated with
// their reasons in unsupportedActions, and checkActionCoverage asserts that the
// two lists together are exactly upstream's vocabulary. A tranche row outside
// the seven is a fatal error naming the boundary, never a quiet skip.
var trancheActions = []string{"run", "build", "errorcheck", "compile", "compiledir", "rundir", "runoutput"}

// goEnv is the pinned toolchain's own answer to `go env -json`, read exactly as
// the upstream runner reads it. These are the TOOLCHAIN's values, not the driver
// binary's: runtime.GOOS answers a different question that only happens to
// coincide on a native build.
type goEnv struct {
	GOOS         string `json:"GOOS"`
	GOARCH       string `json:"GOARCH"`
	GOEXPERIMENT string `json:"GOEXPERIMENT"`
	GODEBUG      string `json:"GODEBUG"`
	CGO_ENABLED  string `json:"CGO_ENABLED"`
	GOROOT       string `json:"GOROOT"`

	// TimeoutScale reproduces upstream's $GO_TEST_TIMEOUT_SCALE: every `-t N`
	// recipe timeout is multiplied by it. Not part of `go env`; carried here
	// because it belongs to the same "what environment is this tranche running
	// in" question and is reported in the summary alongside the rest.
	TimeoutScale int `json:"GO_TEST_TIMEOUT_SCALE"`
}

type driver struct {
	corpusRoot          string
	gorootTestDir       string
	goTool              string
	goVersion           string
	stdlibImportcfg     string
	stdlibImportcfgFile string
	workRoot            string
	keepWork            bool
	ctxt                *buildContext
	env                 *goEnv
	inventory           inventory
	aux                 *auxInventory
	toolchain           *ToolchainIdentity
}

// normalize rewrites host-specific absolute paths out of recorded commands and
// artifacts, so two runs of the same tranche on different machines produce
// diffable results. The real values are recorded once, in the summary.
func (d *driver) normalize(s string) string {
	if d.workRoot != "" {
		s = strings.ReplaceAll(s, d.workRoot, "$WORK")
	}
	s = strings.ReplaceAll(s, d.gorootTestDir, "$GOROOT_TEST")
	s = strings.ReplaceAll(s, d.corpusRoot, "$CORPUS")
	s = strings.ReplaceAll(s, d.goTool, "$GOTOOL")
	return s
}

type trancheRow struct {
	Path   string
	Action string
}

// Summary is the run-level record: provenance, the denominator assertions, and
// the counts. It is written on EVERY exit path, including every fatal one,
// because a failed run that leaves no evidence is indistinguishable from a run
// that never happened — and "the driver died" is itself a measurement.
type Summary struct {
	Schema             string             `json:"schema"`
	GeneratedBy        string             `json:"generated_by"`
	Tranche            string             `json:"tranche"`
	CorpusRoot         string             `json:"corpus_root"`
	GoTool             string             `json:"go_tool"`
	GoVersion          string             `json:"go_version"`
	SemanticsSHA256    string             `json:"semantics_sha256"`
	SemanticsSource    string             `json:"semantics_source"`
	Toolchain          *ToolchainIdentity `json:"toolchain,omitempty"`
	GoEnv              *goEnv             `json:"go_env,omitempty"`
	Host               string             `json:"host"`
	Scope              string             `json:"scope"`
	SupportedActions   []string           `json:"supported_actions"`
	UnsupportedActions map[string]string  `json:"unsupported_actions"`
	Selected           int                `json:"selected"`
	Reported           int                `json:"reported"`
	Executed           int                `json:"executed"`
	Commands           int                `json:"commands"`
	Pass               int                `json:"pass"`
	Fail               int                `json:"fail"`
	Skip               int                `json:"skip"`
	ByAction           map[string]int     `json:"by_action"`
	ExecutedByAction   map[string]int     `json:"executed_by_action"`
	DurationMS         int64              `json:"duration_ms"`
	Verdict            string             `json:"verdict"`
	FatalReason        string             `json:"fatal_reason,omitempty"`
}

const (
	schemaID    = "bashpp-tests/go-oracle/v1"
	generatedBy = "tools/go-oracle"

	// scopeStatement travels with every result file. It is here, in the machine
	// readable output rather than only in prose, because a summary that says
	// "35/35 pass" and nothing else is exactly the artifact that gets quoted as
	// if it were upstream's full runner.
	scopeStatement = "bounded seven-action tranche of the pinned Go corpus; NOT upstream's full runner " +
		"(src/cmd/internal/testdir/testdir_test.go, historically test/run.go). " +
		"See unsupported_actions for what is deliberately not executed. No Bash++ claim is made."
)

// progress is the summary under construction. fatalf serializes it, so no exit
// path can leave the caller without machine-readable evidence of how far the run
// got and what killed it.
var (
	progress        = &Summary{Schema: schemaID, GeneratedBy: generatedBy}
	progressOutPath string
	progressResults []*Result
	progressWritten bool
)

// tally recomputes the executed/failed counts from whatever results exist so far.
func (s *Summary) tally(results []*Result) {
	s.Reported = len(results)
	s.Executed, s.Commands, s.Pass, s.Fail, s.Skip = 0, 0, 0, 0, 0
	s.ByAction = map[string]int{}
	s.ExecutedByAction = map[string]int{}
	for _, r := range results {
		s.ByAction[r.Action]++
		if len(r.Steps) > 0 {
			s.Executed++
			s.ExecutedByAction[r.Action]++
			s.Commands += len(r.Steps)
		}
		switch r.Status {
		case "pass":
			s.Pass++
		case "fail":
			s.Fail++
		case "skip":
			s.Skip++
		}
	}
}

// fatalf stops the run. Before it exits it always writes the summary — with
// verdict "fatal", the reason, and the executed/failed counts reached so far —
// and always prints that summary as one JSON line on stdout. A fatal path that
// produced only prose would force the next reader to guess whether anything ran.
func fatalf(format string, args ...any) {
	reason := fmt.Sprintf(format, args...)
	fmt.Fprintf(os.Stderr, "FATAL: %s\n", reason)
	progress.Verdict = "fatal"
	progress.FatalReason = reason
	progress.tally(progressResults)
	if !progressWritten && progressOutPath != "" {
		writeResults(progressOutPath, progressResults)
	}
	writeSummary(progress)
	line, err := json.Marshal(progress)
	if err == nil {
		fmt.Println(string(line))
	}
	os.Exit(2)
}

var summaryPath string

func main() {
	var (
		corpus    = flag.String("corpus", "", "path to the extracted pinned Go source release (must contain test/ and src/)")
		goTool    = flag.String("gotool", "", "path to the pinned Go toolchain's go binary")
		tranche   = flag.String("tranche", "", "path to the reviewed tranche TSV")
		out       = flag.String("out", "", "path to write per-file results (JSONL)")
		summaryTo = flag.String("summary", "", "path to write the run summary (JSON)")
		semSHA    = flag.String("semantics-sha256", "", "REQUIRED sha256 of the upstream runner this driver was written against")
		invPath   = flag.String("inventory", "", "REQUIRED reviewed corpus inventory TSV; every corpus file read is digest-checked against it")
		auxPath   = flag.String("aux-inventory", "", "REQUIRED reviewed auxiliary-input inventory TSV (.out sidecars and .dir manifests)")
		tcPath    = flag.String("toolchain", "", "REQUIRED reviewed toolchain identity TSV (distribution checksums)")
		wantVer   = flag.String("go-version", "", "expected `go version` release token, e.g. go1.27.0")
		workRoot  = flag.String("work", "", "scratch directory (default: a fresh temp dir)")
		keepWork  = flag.Bool("keep-work", false, "keep the scratch directory")
		verbose   = flag.Bool("v", false, "log each file as it runs")
	)
	flag.Parse()

	summaryPath = *summaryTo
	progressOutPath = *out
	progress.Tranche = *tranche
	progress.SemanticsSource = "src/cmd/internal/testdir/testdir_test.go"
	progress.SemanticsSHA256 = *semSHA
	progress.Host = runtime.GOOS + "/" + runtime.GOARCH
	progress.Scope = scopeStatement
	progress.SupportedActions = slices.Clone(trancheActions)
	progress.UnsupportedActions = unsupportedActions

	// Every provenance input is REQUIRED. An optional digest gate is a gate that
	// is off by default in exactly the runs that most need it, and the previous
	// shape of this driver made both the semantics digest and the corpus
	// inventory optional: passing neither produced a clean, green, entirely
	// unprovenanced result file.
	for _, req := range []struct{ name, value string }{
		{"-corpus", *corpus}, {"-gotool", *goTool}, {"-tranche", *tranche}, {"-out", *out},
		{"-semantics-sha256", *semSHA}, {"-inventory", *invPath},
		{"-aux-inventory", *auxPath}, {"-toolchain", *tcPath},
	} {
		if req.value == "" {
			fatalf("%s is required; this driver has no unprovenanced mode", req.name)
		}
	}

	d := &driver{
		corpusRoot: mustAbs(*corpus),
		goTool:     mustAbs(*goTool),
		keepWork:   *keepWork,
	}
	progress.CorpusRoot = d.corpusRoot
	progress.GoTool = d.goTool
	d.gorootTestDir = filepath.Join(d.corpusRoot, "test")
	if fi, err := os.Stat(d.gorootTestDir); err != nil || !fi.IsDir() {
		fatalf("corpus has no test/ directory: %s", d.gorootTestDir)
	}

	// Provenance gate 1: the driver is a reimplementation of a specific upstream
	// runner. If that runner changed, the reimplementation is stale and every
	// verdict below it is suspect, so refuse rather than report.
	semSrc := filepath.Join(d.corpusRoot, "src", "cmd", "internal", "testdir", "testdir_test.go")
	semData, err := os.ReadFile(semSrc)
	if err != nil {
		fatalf("cannot read upstream runner %s: %v", semSrc, err)
	}
	if got := sha256hex(semData); got != *semSHA {
		fatalf("upstream runner semantics drifted\n  file     %s\n  expected %s\n  actual   %s",
			semSrc, *semSHA, got)
	}
	// ... and the seven/ten split must still exhaust that runner's vocabulary.
	if err := checkActionCoverage(semData); err != nil {
		fatalf("%v", err)
	}

	// Provenance gate 2: WHICH toolchain is this, really?
	//
	// `go version` is asked first, but only for the error message: it is a
	// string, and this package's own mutation tests forge it. The identity that
	// counts comes from verifyToolchain — pinned distribution checksums and the
	// candidate's own GOROOT sources.
	verOut, err := exec.Command(d.goTool, "version").Output()
	if err != nil {
		fatalf("cannot run %s version: %v", d.goTool, err)
	}
	fields := strings.Fields(string(verOut))
	if len(fields) < 3 {
		fatalf("unexpected `go version` output: %q", strings.TrimSpace(string(verOut)))
	}
	d.goVersion = fields[2]
	progress.GoVersion = d.goVersion
	if *wantVer != "" && d.goVersion != *wantVer {
		fatalf("toolchain reports %s, expected %s", d.goVersion, *wantVer)
	}

	d.env = readGoEnv(d.goTool)
	progress.GoEnv = d.env

	release := *wantVer
	if release == "" {
		release = d.goVersion
	}
	d.toolchain = verifyToolchain(*tcPath, d.goTool, release, d.env.GOROOT, d.env.GOOS, d.env.GOARCH, d.goVersion)
	progress.Toolchain = d.toolchain

	inv, err := loadInventory(*invPath)
	if err != nil {
		fatalf("cannot read corpus inventory: %v", err)
	}
	d.inventory = inv

	aux, err := loadAuxInventory(*auxPath)
	if err != nil {
		fatalf("cannot read auxiliary inventory %s: %v", *auxPath, err)
	}
	d.aux = aux

	rows := loadTranche(*tranche)
	if len(rows) == 0 {
		fatalf("tranche %s selected zero files; a run that measures nothing is not a run", *tranche)
	}
	progress.Selected = len(rows)

	if *workRoot == "" {
		tmp, err := os.MkdirTemp("", "go-oracle-")
		if err != nil {
			fatalf("cannot create scratch directory: %v", err)
		}
		*workRoot = tmp
	} else if err := os.MkdirAll(*workRoot, 0o755); err != nil {
		fatalf("cannot create scratch directory: %v", err)
	}
	d.workRoot = mustAbs(*workRoot)
	if !d.keepWork {
		defer os.RemoveAll(d.workRoot)
	}

	cgoEnabled, _ := strconv.ParseBool(d.env.CGO_ENABLED)
	d.ctxt = &buildContext{
		goos:       d.env.GOOS,
		goarch:     d.env.GOARCH,
		cgoEnabled: cgoEnabled,
		noOptEnv: strings.Contains(os.Getenv("GO_GCFLAGS"), "-N") ||
			strings.Contains(os.Getenv("GO_GCFLAGS"), "-l"),
	}
	// The goexperiment.* build tags are answered out of the DRIVER's go/build,
	// as upstream answers them out of its own. That is only correct while the
	// driver's view of GOEXPERIMENT matches the toolchain's, so say so rather
	// than assume it.
	if got := os.Getenv("GOEXPERIMENT"); got != d.env.GOEXPERIMENT {
		fatalf("GOEXPERIMENT disagreement: the pinned toolchain reports %q but this driver runs with %q\n"+
			"  goexperiment.* build tags would be evaluated against the wrong set, so build\n"+
			"  constraints could skip or admit the wrong files. Re-run with GOEXPERIMENT=%q.",
			d.env.GOEXPERIMENT, got, d.env.GOEXPERIMENT)
	}

	d.buildStdlibImportcfg()

	progressResults = make([]*Result, 0, len(rows))
	started := time.Now()
	for i, row := range rows {
		if *verbose {
			fmt.Fprintf(os.Stderr, "%-8s %s\n", row.Action, row.Path)
		}
		progressResults = append(progressResults, d.runOne(i, row))
	}
	elapsed := time.Since(started)
	results := progressResults

	progress.DurationMS = elapsed.Milliseconds()
	progress.tally(results)

	writeResults(*out, results)
	progressWritten = true

	// The three fail-closed invariants of this slice.
	switch {
	case progress.Reported != progress.Selected:
		progress.Verdict = "fatal"
		progress.FatalReason = fmt.Sprintf("denominator mismatch: selected %d, reported %d", progress.Selected, progress.Reported)
	case progress.Executed == 0:
		progress.Verdict = "fatal"
		progress.FatalReason = "zero files executed a command"
	case progress.Commands == 0:
		progress.Verdict = "fatal"
		progress.FatalReason = "zero commands were spawned"
	case progress.Fail > 0:
		progress.Verdict = "fail"
	default:
		progress.Verdict = "pass"
	}
	writeSummary(progress)

	line, _ := json.Marshal(progress)
	fmt.Println(string(line))

	switch progress.Verdict {
	case "fatal":
		// fatalf re-writes the same summary; the counts are already tallied.
		fmt.Fprintf(os.Stderr, "FATAL: %s\n", progress.FatalReason)
		os.Exit(2)
	case "fail":
		for _, r := range results {
			if r.Status == "fail" {
				fmt.Fprintf(os.Stderr, "FAIL %s (%s)\n%s\n", r.Path, r.Action, indent(r.Error))
			}
		}
		os.Exit(1)
	}
}

// readGoEnv asks the PINNED TOOLCHAIN what it is targeting, the same way the
// upstream runner does (`go env -json`, decoded into the same five fields). The
// timeout scale is folded in here because it belongs to the same question.
func readGoEnv(goTool string) *goEnv {
	cmd := exec.Command(goTool, "env", "-json")
	cmd.Env = append(os.Environ(), "GOENV=off", "GOFLAGS=")
	out, err := cmd.Output()
	if err != nil {
		fatalf("cannot run %s env -json: %v", goTool, err)
	}
	env := &goEnv{}
	if err := json.Unmarshal(out, env); err != nil {
		fatalf("cannot decode `go env -json`: %v", err)
	}
	if env.GOOS == "" || env.GOARCH == "" {
		fatalf("`go env -json` reported no GOOS/GOARCH: %s", strings.TrimSpace(string(out)))
	}
	env.TimeoutScale = resolveTimeoutScale()
	return env
}

// resolveTimeoutScale reproduces upstream's $GO_TEST_TIMEOUT_SCALE handling: an
// unset variable means 1, and an unparseable one is fatal rather than silently
// 1. A recipe's `-t N` is multiplied by the result.
func resolveTimeoutScale() int {
	s := os.Getenv("GO_TEST_TIMEOUT_SCALE")
	if s == "" {
		return 1
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		fatalf("failed to parse $GO_TEST_TIMEOUT_SCALE = %q as integer: %v", s, err)
	}
	if n <= 0 {
		fatalf("$GO_TEST_TIMEOUT_SCALE = %q must be positive", s)
	}
	return n
}

// runOne executes a single corpus file and always returns a record.
func (d *driver) runOne(index int, row trancheRow) *Result {
	rel := strings.TrimPrefix(row.Path, "test/")
	dir := path.Dir(rel)
	goFile := path.Base(rel)
	res := &Result{
		Path:           row.Path,
		Dir:            dir,
		GoFile:         goFile,
		DeclaredAction: row.Action,
		Action:         row.Action,
		Steps:          []Step{},
		ExpectFail:     expectFail(dir, goFile),
	}

	if !isUpstreamTestDir(dir) {
		fatalf("%s: %q is not an upstream test directory; a .dir subdirectory holds inputs, not test cases", row.Path, dir)
	}

	src, err := os.ReadFile(filepath.Join(d.gorootTestDir, rel))
	if err != nil {
		fatalf("%s: %v", row.Path, err)
	}
	d.verify(rel, src)
	if strings.HasPrefix(string(src), "\n") {
		fatalf("%s: .go file source starts with a newline", row.Path)
	}

	line := parseRecipeLine(string(src))
	res.Recipe = line
	rec, err := parseRecipe(line, d.env)
	if err != nil {
		fatalf("%s: %v", row.Path, err)
	}
	// The tranche is reviewed, so a disagreement between it and the file means
	// one of the two has drifted. Neither is allowed to win silently.
	if rec.action != row.Action {
		fatalf("%s: tranche declares action %q but the file's recipe is %q", row.Path, row.Action, rec.action)
	}
	res.Action = rec.action

	header, _, ok := strings.Cut(string(src), "\npackage")
	if !ok {
		header = line
	}
	if ok, why := shouldTest(header, d.ctxt); !ok {
		res.Status = "skip"
		res.SkipReason = strings.TrimSpace(why)
		return res
	}

	// Deterministic scratch names keep the recorded commands diffable between
	// runs once $WORK is normalized away.
	tempDir := filepath.Join(d.workRoot, fmt.Sprintf("t-%04d", index))
	if err := os.MkdirAll(tempDir, 0o755); err != nil {
		fatalf("%s: %v", row.Path, err)
	}
	if !d.keepWork {
		defer os.RemoveAll(tempDir)
	}
	if err := os.MkdirAll(filepath.Join(tempDir, "test"), 0o755); err != nil {
		fatalf("%s: %v", row.Path, err)
	}
	if err := os.WriteFile(filepath.Join(tempDir, goFile), src, 0o644); err != nil {
		fatalf("%s: %v", row.Path, err)
	}

	e := &execution{drv: d, res: res, rec: rec, dir: dir, goFile: goFile, tempDir: tempDir, runInDir: tempDir}
	start := time.Now()
	runErr := e.perform()
	res.DurationMS = time.Since(start).Milliseconds()

	// Upstream inverts the verdict for its known-failure set; so do we, so that
	// "the oracle is green" means "the oracle agrees with upstream", not "every
	// upstream test happens to pass".
	switch {
	case runErr != nil && res.ExpectFail:
		res.Status = "pass"
		res.Error = "expected failure: " + runErr.Error()
	case runErr != nil:
		res.Status = "fail"
		res.Error = runErr.Error()
	case res.ExpectFail:
		res.Status = "fail"
		res.Error = "unexpected success: this file is in the upstream known-failure set"
	default:
		res.Status = "pass"
	}
	res.Error = d.normalize(res.Error)
	res.seal()
	return res
}

func (d *driver) buildStdlibImportcfg() {
	cmd := exec.Command(d.goTool, "list", "-export", "-f",
		"{{if .Export}}packagefile {{.ImportPath}}={{.Export}}{{end}}", "std")
	cmd.Env = append(os.Environ(), "GOENV=off", "GOFLAGS=")
	out, err := cmd.Output()
	if err != nil {
		fatalf("'go list -export std' failed: %v", err)
	}
	d.stdlibImportcfg = string(out)
	name := filepath.Join(d.workRoot, "importcfg")
	if err := os.WriteFile(name, out, 0o644); err != nil {
		fatalf("cannot write stdlib importcfg: %v", err)
	}
	d.stdlibImportcfgFile = name
}

// loadTranche reads the reviewed selection. Order, uniqueness and action
// membership are all enforced here: the tranche is the denominator, so it has to
// be exactly as reviewed or the denominator means nothing.
func loadTranche(pathname string) []trancheRow {
	f, err := os.Open(pathname)
	if err != nil {
		fatalf("cannot read tranche: %v", err)
	}
	defer f.Close()

	allowed := map[string]bool{}
	for _, a := range trancheActions {
		allowed[a] = true
	}
	var rows []trancheRow
	seen := map[string]bool{}
	prev := ""
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) != 2 {
			fatalf("tranche line %d: expected 2 tab-separated fields, got %d", n, len(parts))
		}
		p, a := parts[0], parts[1]
		if !strings.HasPrefix(p, "test/") || !strings.HasSuffix(p, ".go") {
			fatalf("tranche line %d: path must be a test/**/*.go corpus path: %s", n, p)
		}
		if !allowed[a] {
			if reason, known := unsupportedActions[a]; known {
				fatalf("tranche line %d: action %q is an upstream action this bounded tranche does not implement: %s\n"+
					"  This driver executes only %s.", n, a, reason, strings.Join(trancheActions, ", "))
			}
			fatalf("tranche line %d: action %q is outside the tranche-1 action set %v", n, a, trancheActions)
		}
		if seen[p] {
			fatalf("tranche line %d: duplicate path %s", n, p)
		}
		if prev != "" && p <= prev {
			fatalf("tranche line %d: path order regression: %s after %s", n, p, prev)
		}
		seen[p] = true
		prev = p
		rows = append(rows, trancheRow{Path: p, Action: a})
	}
	if err := sc.Err(); err != nil {
		fatalf("cannot read tranche: %v", err)
	}
	return rows
}

func writeResults(pathname string, results []*Result) {
	if pathname == "" {
		return
	}
	if dir := filepath.Dir(pathname); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	f, err := os.Create(pathname)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot write results: %v\n", err)
		return
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	for _, r := range results {
		if err := enc.Encode(r); err != nil {
			fmt.Fprintf(os.Stderr, "cannot encode result for %s: %v\n", r.Path, err)
			return
		}
	}
	if err := w.Flush(); err != nil {
		fmt.Fprintf(os.Stderr, "cannot write results: %v\n", err)
	}
}

// writeSummary never calls fatalf: it is itself on the fatal path.
func writeSummary(s *Summary) {
	if summaryPath == "" {
		return
	}
	if dir := filepath.Dir(summaryPath); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot encode summary: %v\n", err)
		return
	}
	if err := os.WriteFile(summaryPath, append(data, '\n'), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "cannot write summary: %v\n", err)
	}
}

func fileSHA256(pathname string) (string, error) {
	data, err := os.ReadFile(pathname)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

func mustAbs(p string) string {
	a, err := filepath.Abs(p)
	if err != nil {
		fatalf("cannot resolve %s: %v", p, err)
	}
	return a
}

func indent(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	return "    " + strings.Join(lines, "\n    ")
}
