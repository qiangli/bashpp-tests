package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// These tests exist to answer one question that a metadata-driven suite can
// never answer about itself: did anything actually run?
//
// Every case below either (a) sabotages an input and demands that the driver
// notices, or (b) sabotages the toolchain and demands that the driver stops
// producing results. A driver that classified files from their action header
// would sail through all of them, which is the point.

var (
	driverBin   string
	fakeRefuse  string // a native `go` that answers the probes and refuses to compile
	fakeZero    string // a native `go` that "succeeds" and writes zero-byte artifacts
	realGOROOT  string
	realVersion string
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "go-oracle-test-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	driverBin = filepath.Join(dir, "go-oracle")
	build := exec.Command(goToolPath(), "build", "-o", driverBin, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "cannot build driver:", err)
		os.Exit(2)
	}
	// The sabotage toolchains are compiled binaries, not scripts, because the
	// identity gate refuses anything that is not a native executable.
	for name, dst := range map[string]*string{"go-refuse": &fakeRefuse, "go-zero": &fakeZero} {
		*dst = filepath.Join(dir, name)
		b := exec.Command(goToolPath(), "build", "-o", *dst, "./internal/fakego")
		b.Stderr = os.Stderr
		if err := b.Run(); err != nil {
			fmt.Fprintln(os.Stderr, "cannot build", name, ":", err)
			os.Exit(2)
		}
	}
	realGOROOT = strings.TrimSpace(capture(goToolPath(), "env", "GOROOT"))
	fields := strings.Fields(capture(goToolPath(), "version"))
	if len(fields) >= 3 {
		realVersion = fields[2]
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func capture(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, name, args, ":", err)
		os.Exit(2)
	}
	return string(out)
}

func goToolPath() string {
	if p := os.Getenv("GO_ORACLE_GOTOOL"); p != "" {
		return p
	}
	if root := runtime.GOROOT(); root != "" {
		if p := filepath.Join(root, "bin", "go"); fileExists(p) {
			return p
		}
	}
	p, err := exec.LookPath("go")
	if err != nil {
		return "go"
	}
	return p
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

type run struct {
	exit    int
	stdout  string
	stderr  string
	results []Result
	summary Summary
	sumPath string
}

// opts controls one driver invocation. The zero value is the normal case: real
// toolchain, full provenance generated for the scratch corpus.
type opts struct {
	gotool     string   // default: goToolPath()
	env        []string // extra environment for the driver process
	extra      []string // extra driver flags
	noProv     bool     // omit the four mandatory provenance flags
	invTweak   func(string) string
	auxTweak   func(string) string
	tcTweak    func(string) string
	semSHA     string // override the semantics digest
	skipSemSHA bool
}

// provenance writes the four reviewed inputs the driver now REQUIRES, derived
// from the scratch corpus and from the toolchain actually under test. Tests that
// want to prove a gate fires mutate one of them through the *Tweak hooks; tests
// that want to prove something else get a set that passes.
func provenance(t *testing.T, corpus, tranche, gotool string, o opts) []string {
	t.Helper()
	dir := t.TempDir()

	// Corpus inventory: every .go file under the scratch test/ tree.
	var invBody strings.Builder
	invBody.WriteString("# path\taction\tbytes\tsha256\n")
	testDir := filepath.Join(corpus, "test")
	err := filepath.WalkDir(testDir, func(p string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() || filepath.Ext(p) != ".go" {
			return err
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(corpus, p)
		fmt.Fprintf(&invBody, "%s\tnone\t%d\t%s\n", filepath.ToSlash(rel), len(data), sha256hex(data))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	inv := invBody.String()
	if o.invTweak != nil {
		inv = o.invTweak(inv)
	}
	invPath := filepath.Join(dir, "inventory.tsv")
	write(t, invPath, inv)

	auxPath := filepath.Join(dir, "aux-inventory.tsv")
	aux := auxInventoryFor(t, corpus, tranche)
	if o.auxTweak != nil {
		aux = o.auxTweak(aux)
	}
	write(t, auxPath, aux)

	tcPath := filepath.Join(dir, "toolchain.tsv")
	tc := toolchainPinFor(t, gotool)
	if o.tcTweak != nil {
		tc = o.tcTweak(tc)
	}
	write(t, tcPath, tc)

	sem := o.semSHA
	if sem == "" {
		digest, err := fileSHA256(filepath.Join(corpus, "src", "cmd", "internal", "testdir", "testdir_test.go"))
		if err != nil {
			t.Fatal(err)
		}
		sem = digest
	}

	args := []string{"-inventory", invPath, "-aux-inventory", auxPath, "-toolchain", tcPath}
	if !o.skipSemSHA {
		args = append(args, "-semantics-sha256", sem)
	}
	return args
}

// auxInventoryFor reproduces tools/go-oracle/select-aux.sh for a scratch corpus.
func auxInventoryFor(t *testing.T, corpus, tranche string) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("# role\tpath\tpresence\tbytes\tsha256\n")
	data, err := os.ReadFile(tranche)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 2 {
			continue
		}
		base := strings.TrimSuffix(f[0], ".go")
		switch f[1] {
		case "run", "rundir", "runoutput":
			out := filepath.Join(corpus, filepath.FromSlash(base)+".out")
			if body, err := os.ReadFile(out); err == nil {
				fmt.Fprintf(&b, "expected_output\t%s.out\tpresent\t%d\t%s\n", base, len(body), sha256hex(body))
			} else {
				fmt.Fprintf(&b, "expected_output\t%s.out\tabsent\t0\t-\n", base)
			}
		}
		switch f[1] {
		case "compiledir", "rundir":
			d := filepath.Join(corpus, filepath.FromSlash(base)+".dir")
			digest, count, names, err := dirManifestDigest(d)
			if err != nil {
				t.Fatal(err)
			}
			fmt.Fprintf(&b, "dir_manifest\t%s.dir\tpresent\t%d\t%s\n", base, count, digest)
			for _, name := range names {
				if filepath.Ext(name) == ".go" {
					continue
				}
				body, err := os.ReadFile(filepath.Join(d, name))
				if err != nil {
					t.Fatal(err)
				}
				fmt.Fprintf(&b, "dir_input\t%s.dir/%s\tpresent\t%d\t%s\n", base, name, len(body), sha256hex(body))
			}
		}
	}
	return b.String()
}

// toolchainPinFor records the toolchain under test as if it had been reviewed:
// GOROOT probes taken from the real GOROOT, and the binary's own digest.
func toolchainPinFor(t *testing.T, gotool string) string {
	t.Helper()
	var b strings.Builder
	for _, probe := range []string{"VERSION", "src/cmd/internal/testdir/testdir_test.go"} {
		digest, err := fileSHA256(filepath.Join(realGOROOT, filepath.FromSlash(probe)))
		if err != nil {
			t.Skipf("real GOROOT has no %s: %v", probe, err)
		}
		fmt.Fprintf(&b, "goroot_probe\t%s\t%s\n", probe, digest)
	}
	digest, err := fileSHA256(gotool)
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(&b, "toolchain\t%s\t%s\t%s\t%s\tunder-test.tar.gz\t%s\tgolang.org/toolchain\tv0.0.1-%s.%s-%s\th1:test\n",
		realVersion, runtime.GOOS, runtime.GOARCH, digest, strings.Repeat("0", 64),
		realVersion, runtime.GOOS, runtime.GOARCH)
	return b.String()
}

// invoke runs the driver against a corpus and reads back everything it wrote.
func invoke(t *testing.T, corpus, tranche string, extra ...string) run {
	t.Helper()
	return invokeOpts(t, corpus, tranche, opts{extra: extra})
}

func invokeOpts(t *testing.T, corpus, tranche string, o opts) run {
	t.Helper()
	dir := t.TempDir()
	outPath := filepath.Join(dir, "results.jsonl")
	sumPath := filepath.Join(dir, "summary.json")
	gotool := o.gotool
	if gotool == "" {
		gotool = goToolPath()
	}
	args := []string{
		"-corpus", corpus,
		"-gotool", gotool,
		"-tranche", tranche,
		"-out", outPath,
		"-summary", sumPath,
	}
	if !o.noProv {
		args = append(args, provenance(t, corpus, tranche, gotool, o)...)
	}
	args = append(args, o.extra...)
	cmd := exec.Command(driverBin, args...)
	cmd.Env = append(os.Environ(), "FAKEGO_GOROOT="+realGOROOT)
	cmd.Env = append(cmd.Env, o.env...)
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	r := run{stdout: stdout.String(), stderr: stderr.String(), sumPath: sumPath}
	if err != nil {
		var ee *exec.ExitError
		if !errorsAs(err, &ee) {
			t.Fatalf("running driver: %v", err)
		}
		r.exit = ee.ExitCode()
	}
	if f, err := os.Open(outPath); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		for sc.Scan() {
			var res Result
			if err := json.Unmarshal(sc.Bytes(), &res); err != nil {
				t.Fatalf("results are not valid JSON: %v", err)
			}
			r.results = append(r.results, res)
		}
		f.Close()
	}
	if data, err := os.ReadFile(sumPath); err == nil {
		if err := json.Unmarshal(data, &r.summary); err != nil {
			t.Fatalf("summary is not valid JSON: %v", err)
		}
	}
	return r
}

func errorsAs(err error, target **exec.ExitError) bool {
	ee, ok := err.(*exec.ExitError)
	if ok {
		*target = ee
	}
	return ok
}

func writeTranche(t *testing.T, rows ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "tranche.tsv")
	body := "# path\taction\n"
	if len(rows) > 0 {
		body += strings.Join(rows, "\n") + "\n"
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func write(t *testing.T, p, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// scratchCorpus builds a miniature corpus with one file per tranche-1 action.
// It is not the official corpus and makes no claim to be; it exists so a
// mutation can be applied to a known input and the driver's reaction observed.
func scratchCorpus(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	test := filepath.Join(root, "test")

	// The driver refuses to run unless the corpus carries the upstream runner it
	// reimplements, and it re-derives the seven/ten action split from that file.
	// Copy the real one so the scratch corpus is provenanced the same way the
	// official corpus is.
	sem, err := os.ReadFile(filepath.Join(realGOROOT, "src", "cmd", "internal", "testdir", "testdir_test.go"))
	if err != nil {
		t.Skipf("real GOROOT has no upstream runner to copy: %v", err)
	}
	write(t, filepath.Join(root, "src", "cmd", "internal", "testdir", "testdir_test.go"), string(sem))

	write(t, filepath.Join(test, "zbuild.go"), `// build

package main

func main() {
	_ = 1
}
`)
	write(t, filepath.Join(test, "zcompile.go"), `// compile

package p

func F() int { return 1 }
`)
	write(t, filepath.Join(test, "zcompiledir.go"), `// compiledir

package ignored
`)
	write(t, filepath.Join(test, "zcompiledir.dir", "a.go"), `package a

func A() int { return 7 }
`)
	write(t, filepath.Join(test, "zcompiledir.dir", "main.go"), `package main

import "test/a"

func main() {
	_ = a.A()
}
`)
	write(t, filepath.Join(test, "zerrorcheck.go"), `// errorcheck

package p

func F() {
	nope() // ERROR "undefined: nope"
}
`)
	write(t, filepath.Join(test, "zrun.go"), `// run

package main

func main() {
}
`)
	write(t, filepath.Join(test, "zrunout.go"), `// run

package main

func main() {
	println("silent")
}
`)
	// println writes to stderr, which runcmd folds into the captured output.
	write(t, filepath.Join(test, "zrunout.out"), "silent\n")
	write(t, filepath.Join(test, "zrundir.go"), `// rundir

package ignored
`)
	write(t, filepath.Join(test, "zrundir.dir", "a.go"), `package a

func Greet() string { return "from-a" }
`)
	write(t, filepath.Join(test, "zrundir.dir", "main.go"), `package main

import "test/a"

func main() {
	println(a.Greet())
}
`)
	write(t, filepath.Join(test, "zrundir.out"), "from-a\n")
	write(t, filepath.Join(test, "zrunoutput.go"), `// runoutput

package main

import "fmt"

func main() {
	fmt.Print("package main\n\nfunc main() {\n\tprintln(\"generated\")\n}\n")
}
`)
	write(t, filepath.Join(test, "zrunoutput.out"), "generated\n")
	return root
}

const scratchTranche = "test/zbuild.go\tbuild\n" +
	"test/zcompile.go\tcompile\n" +
	"test/zcompiledir.go\tcompiledir\n" +
	"test/zerrorcheck.go\terrorcheck\n" +
	"test/zrun.go\trun\n" +
	"test/zrundir.go\trundir\n" +
	"test/zrunout.go\trun\n" +
	"test/zrunoutput.go\trunoutput\n"

func scratchTrancheFile(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "tranche.tsv")
	write(t, p, scratchTranche)
	return p
}

func mustResult(t *testing.T, r run, path string) Result {
	t.Helper()
	for _, res := range r.results {
		if res.Path == path {
			return res
		}
	}
	t.Fatalf("no result for %s (got %d results)", path, len(r.results))
	return Result{}
}

// ---------------------------------------------------------------------------
// Integration: the whole scratch tranche, every action, really executed.
// ---------------------------------------------------------------------------

func TestScratchTrancheExecutesEveryAction(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	if r.exit != 0 {
		t.Fatalf("exit %d, want 0\nstdout: %s\nstderr: %s", r.exit, r.stdout, r.stderr)
	}
	if r.summary.Selected != 8 || r.summary.Reported != 8 || r.summary.Executed != 8 {
		t.Fatalf("selected/reported/executed = %d/%d/%d, want 8/8/8",
			r.summary.Selected, r.summary.Reported, r.summary.Executed)
	}
	if r.summary.Pass != 8 || r.summary.Fail != 0 {
		t.Fatalf("pass/fail = %d/%d, want 8/0: %s", r.summary.Pass, r.summary.Fail, r.stderr)
	}
	if r.summary.Verdict != "pass" {
		t.Fatalf("verdict %q, want pass", r.summary.Verdict)
	}
	// One record per selected file, and each record must carry the five fields
	// this slice promises: command, exit, duration, action and artifact.
	want := map[string]bool{
		"build": true, "compile": true, "compiledir": true, "errorcheck": true,
		"run": true, "rundir": true, "runoutput": true,
	}
	for _, res := range r.results {
		delete(want, res.Action)
		if len(res.Steps) == 0 {
			t.Errorf("%s: no command was spawned", res.Path)
			continue
		}
		if len(res.Command) == 0 {
			t.Errorf("%s: empty command", res.Path)
		}
		if res.DurationMS < 0 {
			t.Errorf("%s: negative duration", res.Path)
		}
		if res.Artifact == "" {
			t.Errorf("%s: no artifact recorded", res.Path)
		}
		for i, s := range res.Steps {
			if len(s.Command) == 0 {
				t.Errorf("%s step %d: empty command", res.Path, i)
			}
			if s.Dir == "" {
				t.Errorf("%s step %d: no working directory", res.Path, i)
			}
		}
	}
	if len(want) != 0 {
		t.Fatalf("actions never executed: %v", want)
	}
	if r.summary.Commands < len(r.results) {
		t.Fatalf("commands %d < results %d", r.summary.Commands, len(r.results))
	}
}

// ---------------------------------------------------------------------------
// Mutation: the toolchain. If the driver were reporting from metadata, breaking
// the compiler would change nothing.
// ---------------------------------------------------------------------------

func TestSabotagedToolchainFailsEveryFile(t *testing.T) {
	corpus := scratchCorpus(t)
	// go-refuse identifies itself normally and answers the environment probes,
	// so the only thing it breaks is the actual work. A driver that never spawns
	// a compiler would not notice. (A stub that failed the probes too would die
	// during startup and prove nothing — see internal/fakego.)
	r := invokeOpts(t, corpus, scratchTrancheFile(t), opts{gotool: fakeRefuse})

	if r.summary.Verdict != "fail" {
		t.Fatalf("verdict %q with a toolchain that always exits 3, want fail\nstderr: %s", r.summary.Verdict, r.stderr)
	}
	if r.summary.Fail != r.summary.Reported {
		t.Fatalf("fail %d of %d reported; a stub compiler must fail every file", r.summary.Fail, r.summary.Reported)
	}
	if r.summary.GoTool != fakeRefuse {
		t.Fatalf("summary go_tool is %q, want the stub %q", r.summary.GoTool, fakeRefuse)
	}
	// And the recorded evidence must point at the stub, not at a remembered
	// good result.
	for _, res := range r.results {
		if len(res.Steps) == 0 {
			t.Fatalf("%s: no step recorded", res.Path)
		}
		first := res.Steps[0]
		// Recorded commands are normalized for diffability; the summary carries
		// the real path, and it must be the stub.
		if first.Command[0] != "$GOTOOL" {
			t.Fatalf("%s: first command was %q, want the toolchain", res.Path, first.Command[0])
		}
		if first.Exit != 3 {
			t.Fatalf("%s: recorded exit %d, want the stub's 3", res.Path, first.Exit)
		}
	}
	if len(r.results) != r.summary.Reported {
		t.Fatalf("read %d result lines, summary reported %d", len(r.results), r.summary.Reported)
	}
}

// TestFakeGoProducesZeroArtifact is the regression for the compile/build/link
// artifact assertions.
//
// go-zero is the more dangerous sabotage than go-refuse: it exits 0 for every
// compile, link and build, and writes a ZERO-BYTE file where the object or the
// executable should be. Before the artifact assertions the driver had nothing to
// say about that — it recorded artifact_bytes 0 next to status "pass", because
// the measurement and the verdict were independent. Every file must now fail,
// and the failure must name the missing or empty artifact rather than something
// downstream.
func TestFakeGoProducesZeroArtifact(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invokeOpts(t, corpus, scratchTrancheFile(t), opts{gotool: fakeZero})

	if r.exit == 0 {
		t.Fatalf("exit 0 with a toolchain that produces empty artifacts\nstdout: %s", r.stdout)
	}
	if r.summary.Verdict != "fail" {
		t.Fatalf("verdict %q, want fail\nstderr: %s", r.summary.Verdict, r.stderr)
	}
	if r.summary.Pass != 0 {
		t.Fatalf("%d files passed against a toolchain that produced nothing", r.summary.Pass)
	}
	if r.summary.Fail != r.summary.Reported {
		t.Fatalf("fail %d of %d reported", r.summary.Fail, r.summary.Reported)
	}

	// The files whose actions promise an artifact must fail ON the artifact, not
	// on some later symptom.
	wantArtifactFailure := map[string]bool{
		"test/zbuild.go": true, "test/zcompile.go": true,
		"test/zcompiledir.go": true, "test/zrundir.go": true,
		"test/zrun.go": true, "test/zrunout.go": true,
	}
	for _, res := range r.results {
		if !wantArtifactFailure[res.Path] {
			continue
		}
		if res.Status != "fail" {
			t.Errorf("%s: status %q, want fail", res.Path, res.Status)
			continue
		}
		if !strings.Contains(res.Error, "artifact") {
			t.Errorf("%s: error does not blame the artifact, so the assertion never fired:\n%s",
				res.Path, res.Error)
		}
		if res.Steps[len(res.Steps)-1].Exit != 0 {
			t.Errorf("%s: the sabotage toolchain should have exited 0; the failure must come from the artifact check, not the exit code", res.Path)
		}
	}
}

// TestFakeGoOmitsArtifactEntirely is the same lie told by omission: exit 0 and
// write no file at all.
func TestFakeGoOmitsArtifactEntirely(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invokeOpts(t, corpus, writeTranche(t, "test/zcompile.go\tcompile"),
		opts{gotool: fakeZero, env: []string{"FAKEGO_OMIT_ARTIFACT=1"}})
	res := mustResult(t, r, "test/zcompile.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail: the compiler exited 0 and wrote nothing", res.Status)
	}
	if !strings.Contains(res.Error, "produced no goarchive artifact") {
		t.Fatalf("error does not name the missing artifact:\n%s", res.Error)
	}
}

// TestArtifactKindIsAsserted proves the check is about the KIND of file, not
// merely its size: a non-empty file of the wrong format must still fail.
func TestArtifactKindIsAsserted(t *testing.T) {
	if err := assertArtifact(t.TempDir(), artifactSpec{name: "nope.o", kind: artifactArchive}); err == nil {
		t.Fatal("a missing archive was accepted")
	}
	dir := t.TempDir()
	write(t, filepath.Join(dir, "empty.o"), "")
	if err := assertArtifact(dir, artifactSpec{name: "empty.o", kind: artifactArchive}); err == nil {
		t.Fatal("a zero-byte archive was accepted")
	}
	write(t, filepath.Join(dir, "text.o"), "this is not a Go object archive\n")
	err := assertArtifact(dir, artifactSpec{name: "text.o", kind: artifactArchive})
	if err == nil || !strings.Contains(err.Error(), "not a Go object archive") {
		t.Fatalf("a non-empty text file passed as a Go archive: %v", err)
	}
	write(t, filepath.Join(dir, "script"), "#!/bin/sh\necho hi\n")
	if err := os.Chmod(filepath.Join(dir, "script"), 0o755); err != nil {
		t.Fatal(err)
	}
	err = assertArtifact(dir, artifactSpec{name: "script", kind: artifactExecutable})
	if err == nil || !strings.Contains(err.Error(), "not a native executable") {
		t.Fatalf("an executable shell script passed as a linked binary: %v", err)
	}
	write(t, filepath.Join(dir, "good.a"), "!<arch>\npayload")
	if err := assertArtifact(dir, artifactSpec{name: "good.a", kind: artifactArchive}); err != nil {
		t.Fatalf("a real Go archive header was rejected: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Mutation: the sources and the expectations.
// ---------------------------------------------------------------------------

func TestBrokenSourceIsDetected(t *testing.T) {
	corpus := scratchCorpus(t)
	p := filepath.Join(corpus, "test", "zrun.go")
	body, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	write(t, p, string(body)+"\nvar _ = thisSymbolDoesNotExist\n")

	r := invoke(t, corpus, scratchTrancheFile(t))
	if r.exit != 1 {
		t.Fatalf("exit %d, want 1 (a file that no longer compiles must fail)", r.exit)
	}
	res := mustResult(t, r, "test/zrun.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail", res.Status)
	}
	if !strings.Contains(res.Error, "thisSymbolDoesNotExist") {
		t.Fatalf("error does not mention the injected symbol, so the compiler never saw the file:\n%s", res.Error)
	}
}

func TestMutatedExpectedOutputIsDetected(t *testing.T) {
	corpus := scratchCorpus(t)
	write(t, filepath.Join(corpus, "test", "zrunout.out"), "not what the program prints\n")

	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zrunout.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail: the .out file no longer matches the program", res.Status)
	}
	if !strings.Contains(res.Error, "output does not match expected") {
		t.Fatalf("unexpected error, want an output comparison failure:\n%s", res.Error)
	}
}

func TestErrorcheckAnnotationRemovalIsDetected(t *testing.T) {
	corpus := scratchCorpus(t)
	p := filepath.Join(corpus, "test", "zerrorcheck.go")
	body, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	write(t, p, strings.Replace(string(body), ` // ERROR "undefined: nope"`, "", 1))

	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zerrorcheck.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail: a real diagnostic is now unannotated", res.Status)
	}
	if !strings.Contains(res.Error, "Unmatched Errors") {
		t.Fatalf("unexpected error, want unmatched compiler diagnostics:\n%s", res.Error)
	}
}

func TestErrorcheckRequiresCompilationToFail(t *testing.T) {
	corpus := scratchCorpus(t)
	write(t, filepath.Join(corpus, "test", "zerrorcheck.go"), `// errorcheck

package p

func F() int { return 1 }
`)
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zerrorcheck.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail: an errorcheck file that compiles is a failure", res.Status)
	}
	if !strings.Contains(res.Error, "compilation succeeded unexpectedly") {
		t.Fatalf("unexpected error:\n%s", res.Error)
	}
	if res.Exit != 0 {
		t.Fatalf("recorded exit %d, want 0: the compiler really did succeed", res.Exit)
	}
}

// ---------------------------------------------------------------------------
// Upstream structure: directory grouping and generator semantics.
// ---------------------------------------------------------------------------

func TestCompiledirCompilesEachSiblingPackage(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zcompiledir.go")
	if res.Status != "pass" {
		t.Fatalf("status %q: %s", res.Status, res.Error)
	}
	if len(res.Steps) != 2 {
		t.Fatalf("%d compile steps, want one per package in the .dir", len(res.Steps))
	}
	if !strings.Contains(strings.Join(res.Steps[0].Command, " "), "zcompiledir.dir/a.go") {
		t.Fatalf("first step did not compile the dependency package first: %v", res.Steps[0].Command)
	}
	if !strings.Contains(strings.Join(res.Steps[1].Command, " "), "zcompiledir.dir/main.go") {
		t.Fatalf("second step did not compile the main package: %v", res.Steps[1].Command)
	}
	if res.Steps[0].ArtifactBytes == 0 {
		t.Fatal("the dependency package produced no archive; nothing was really compiled")
	}
}

func TestCompiledirNoticesAMissingSiblingFile(t *testing.T) {
	corpus := scratchCorpus(t)
	if err := os.Remove(filepath.Join(corpus, "test", "zcompiledir.dir", "a.go")); err != nil {
		t.Fatal(err)
	}
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zcompiledir.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail: the imported package is gone", res.Status)
	}
}

func TestRundirLinksAndRunsTheLastPackage(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zrundir.go")
	if res.Status != "pass" {
		t.Fatalf("status %q: %s", res.Status, res.Error)
	}
	// two compiles, one link, one execution
	if len(res.Steps) != 4 {
		t.Fatalf("%d steps, want 2 compiles + link + run: %v", len(res.Steps), res.Steps)
	}
	link := res.Steps[2]
	if !contains(link.Command, "link") {
		t.Fatalf("third step is not a link: %v", link.Command)
	}
	if link.ArtifactBytes == 0 {
		t.Fatal("the linker produced no executable")
	}
	exe := res.Steps[3]
	if len(exe.Command) != 1 || !strings.HasSuffix(exe.Command[0], "a.exe") {
		t.Fatalf("last step is not the linked executable: %v", exe.Command)
	}
}

func TestRundirComparesTheExpectedOutput(t *testing.T) {
	corpus := scratchCorpus(t)
	write(t, filepath.Join(corpus, "test", "zrundir.out"), "from-somewhere-else\n")
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zrundir.go")
	if res.Status != "fail" || !strings.Contains(res.Error, "output does not match expected") {
		t.Fatalf("status %q error %q, want an output comparison failure", res.Status, res.Error)
	}
}

func TestRunoutputRunsTheGeneratedProgram(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zrunoutput.go")
	if res.Status != "pass" {
		t.Fatalf("status %q: %s", res.Status, res.Error)
	}
	if len(res.Steps) != 2 {
		t.Fatalf("%d steps, want generator + generated: %v", len(res.Steps), res.Steps)
	}
	if !strings.HasSuffix(res.Steps[0].Command[len(res.Steps[0].Command)-1], "zrunoutput.go") {
		t.Fatalf("first step did not run the generator: %v", res.Steps[0].Command)
	}
	gen := res.Steps[1].Command[len(res.Steps[1].Command)-1]
	if !strings.HasSuffix(gen, "tmp__.go") {
		t.Fatalf("second step did not run the generated program: %v", res.Steps[1].Command)
	}
	if res.Artifact == "" || !strings.HasSuffix(res.Artifact, "tmp__.go") {
		t.Fatalf("artifact %q, want the generated program", res.Artifact)
	}
	if res.ArtifactBytes == 0 {
		t.Fatal("the generated program is empty; the generator never ran")
	}
}

func TestRunoutputFailsWhenTheGeneratedProgramIsBroken(t *testing.T) {
	corpus := scratchCorpus(t)
	write(t, filepath.Join(corpus, "test", "zrunoutput.go"), `// runoutput

package main

import "fmt"

func main() {
	fmt.Print("package main\n\nfunc main() { this is not go }\n")
}
`)
	r := invoke(t, corpus, scratchTrancheFile(t))
	res := mustResult(t, r, "test/zrunoutput.go")
	if res.Status != "fail" {
		t.Fatalf("status %q, want fail: the GENERATED program does not compile", res.Status)
	}
	if len(res.Steps) != 2 || res.Steps[0].Exit != 0 {
		t.Fatalf("the generator itself should have succeeded: %v", res.Steps)
	}
	if res.Steps[1].Exit == 0 {
		t.Fatal("the generated program compiled, so nothing was really generated")
	}
}

// ---------------------------------------------------------------------------
// Denominator: the run is only reportable if it covered the whole tranche.
// ---------------------------------------------------------------------------

func TestEmptyTrancheIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, writeTranche(t))
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for a tranche that selects nothing", r.exit)
	}
	if !strings.Contains(r.stderr, "selected zero files") {
		t.Fatalf("stderr does not explain the empty denominator:\n%s", r.stderr)
	}
	if r.summary.Verdict != "fatal" {
		t.Fatalf("summary verdict %q, want fatal", r.summary.Verdict)
	}
}

func TestResultCountEqualsTrancheSize(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	rows := strings.Count(strings.TrimSpace(scratchTranche), "\n") + 1
	if len(r.results) != rows {
		t.Fatalf("%d result records for %d tranche rows", len(r.results), rows)
	}
	if r.summary.Selected != rows || r.summary.Reported != rows {
		t.Fatalf("summary says %d/%d for %d rows", r.summary.Selected, r.summary.Reported, rows)
	}
}

func TestTrancheActionDriftIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, writeTranche(t, "test/zrun.go\tcompile"))
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 when the tranche and the file disagree", r.exit)
	}
	if !strings.Contains(r.stderr, "tranche declares action") {
		t.Fatalf("stderr does not name the drift:\n%s", r.stderr)
	}
}

func TestTrancheRejectsDirSubdirectories(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, writeTranche(t, "test/zrundir.dir/main.go\trun"))
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: a .dir file is an input, not a test case", r.exit)
	}
	if !strings.Contains(r.stderr, "not an upstream test directory") {
		t.Fatalf("stderr does not explain the rejection:\n%s", r.stderr)
	}
}

func TestTrancheRejectsUnsortedAndDuplicateRows(t *testing.T) {
	corpus := scratchCorpus(t)
	for name, rows := range map[string][]string{
		"unsorted":       {"test/zrun.go\trun", "test/zbuild.go\tbuild"},
		"duplicate":      {"test/zrun.go\trun", "test/zrun.go\trun"},
		"unknown-action": {"test/zrun.go\tasmcheck"},
	} {
		t.Run(name, func(t *testing.T) {
			r := invoke(t, corpus, writeTranche(t, rows...))
			if r.exit != 2 {
				t.Fatalf("exit %d, want 2\nstderr: %s", r.exit, r.stderr)
			}
		})
	}
}

func TestMissingCorpusFileIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, writeTranche(t, "test/zabsent.go\trun"))
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for a tranche row with no corpus file", r.exit)
	}
}

// ---------------------------------------------------------------------------
// Provenance gates.
// ---------------------------------------------------------------------------

func TestInventoryDigestGateRejectsAnEditedCorpus(t *testing.T) {
	corpus := scratchCorpus(t)
	inv := filepath.Join(t.TempDir(), "inventory.tsv")
	body := "# path\taction\tbytes\tsha256\n"
	for _, rel := range []string{"zrun.go"} {
		data, err := os.ReadFile(filepath.Join(corpus, "test", rel))
		if err != nil {
			t.Fatal(err)
		}
		body += fmt.Sprintf("test/%s\trun\t%d\t%s\n", rel, len(data), sha256hex(data))
	}
	write(t, inv, body)

	tranche := writeTranche(t, "test/zrun.go\trun")
	if r := invoke(t, corpus, tranche, "-inventory", inv); r.exit != 0 {
		t.Fatalf("exit %d with an unmodified corpus, want 0\nstderr: %s", r.exit, r.stderr)
	}

	p := filepath.Join(corpus, "test", "zrun.go")
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	write(t, p, string(data)+"\n// locally edited\n")

	r := invoke(t, corpus, tranche, "-inventory", inv)
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: the oracle must not execute an edited corpus", r.exit)
	}
	if !strings.Contains(r.stderr, "does not match the reviewed inventory") {
		t.Fatalf("stderr does not name the digest mismatch:\n%s", r.stderr)
	}
}

func TestSemanticsDigestGateRejectsADriftedRunner(t *testing.T) {
	corpus := scratchCorpus(t)
	write(t, filepath.Join(corpus, "src", "cmd", "internal", "testdir", "testdir_test.go"),
		"package testdir_test // a runner this driver was not written against\n")
	r := invoke(t, corpus, writeTranche(t, "test/zrun.go\trun"),
		"-semantics-sha256", strings.Repeat("0", 64))
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 when the upstream runner has drifted", r.exit)
	}
	if !strings.Contains(r.stderr, "semantics drifted") {
		t.Fatalf("stderr does not name the drift:\n%s", r.stderr)
	}
}

func TestToolchainVersionGate(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, writeTranche(t, "test/zrun.go\trun"), "-go-version", "go0.0.0")
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for the wrong toolchain release", r.exit)
	}
	if !strings.Contains(r.stderr, "expected go0.0.0") {
		t.Fatalf("stderr does not name the version mismatch:\n%s", r.stderr)
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Auxiliary provenance: the sidecars.
//
// docs/go-corpus/inventory.tsv covers test/**/*.go. Everything else the driver
// READS was unchecked, and a .out file IS the expected result — so an unchecked
// .out is an unchecked oracle. These cases mutate each auxiliary input in turn
// and demand a fatal, not a failed comparison: a tampered input must stop the
// run, because a "fail" would report a measurement taken against bytes nobody
// reviewed.
// ---------------------------------------------------------------------------

func TestSidecarOutputMutationIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zrunout.go\trun")
	// Baseline: the reviewed sidecar passes.
	if r := invoke(t, corpus, tranche); r.exit != 0 {
		t.Fatalf("exit %d with an unmutated sidecar\nstderr: %s", r.exit, r.stderr)
	}
	// Now edit the .out AFTER the inventory was taken.
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		// Pin the sidecar, then change the file on disk.
		write(t, filepath.Join(corpus, "test", "zrunout.out"), "tampered\n")
		return aux
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: an edited expected-output file must stop the run", r.exit)
	}
	if !strings.Contains(r.stderr, "does not match the reviewed digest") {
		t.Fatalf("stderr does not name the sidecar digest mismatch:\n%s", r.stderr)
	}
	if r.summary.Verdict != "fatal" {
		t.Fatalf("summary verdict %q, want fatal", r.summary.Verdict)
	}
}

func TestSidecarAppearingWhereReviewedAbsentIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zrun.go\trun")
	// zrun.go has no .out: upstream's rule is that its output must be EMPTY.
	// Creating one silently rewrites the expectation, so the absent row is a
	// real assertion and must fire.
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		write(t, filepath.Join(corpus, "test", "zrun.out"), "anything at all\n")
		return aux
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: a .out that appeared after review must stop the run", r.exit)
	}
	if !strings.Contains(r.stderr, "records it as absent") {
		t.Fatalf("stderr does not explain the appeared sidecar:\n%s", r.stderr)
	}
}

func TestSidecarDisappearingIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zrunout.go\trun")
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		if err := os.Remove(filepath.Join(corpus, "test", "zrunout.out")); err != nil {
			t.Fatal(err)
		}
		return aux
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: a deleted expected-output file must stop the run", r.exit)
	}
	if !strings.Contains(r.stderr, "is missing from the corpus") {
		t.Fatalf("stderr does not name the missing sidecar:\n%s", r.stderr)
	}
}

func TestUnpinnedSidecarIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zrunout.go\trun")
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		var kept []string
		for _, line := range strings.Split(aux, "\n") {
			if !strings.Contains(line, "zrunout.out") {
				kept = append(kept, line)
			}
		}
		return strings.Join(kept, "\n")
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: reading an unpinned sidecar must stop the run", r.exit)
	}
	if !strings.Contains(r.stderr, "has no row in") {
		t.Fatalf("stderr does not name the unpinned sidecar:\n%s", r.stderr)
	}
}

func TestDirMemberAddedIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zcompiledir.go\tcompiledir")
	// A file ADDED to a .dir changes the package grouping and the compile order.
	// It is not an edit to anything the corpus inventory lists, so only the
	// directory manifest can see it.
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		write(t, filepath.Join(corpus, "test", "zcompiledir.dir", "notes.txt"), "smuggled\n")
		return aux
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: an added .dir member must stop the run", r.exit)
	}
	if !strings.Contains(r.stderr, "does not match the reviewed manifest") {
		t.Fatalf("stderr does not name the manifest mismatch:\n%s", r.stderr)
	}
}

func TestDirMemberRemovedIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zcompiledir.go\tcompiledir")
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		if err := os.Remove(filepath.Join(corpus, "test", "zcompiledir.dir", "a.go")); err != nil {
			t.Fatal(err)
		}
		return aux
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: a deleted .dir member must stop the run", r.exit)
	}
	if !strings.Contains(r.stderr, "does not match the reviewed manifest") {
		t.Fatalf("stderr does not name the manifest mismatch:\n%s", r.stderr)
	}
}

func TestNonGoDirInputIsDigested(t *testing.T) {
	corpus := scratchCorpus(t)
	// A .s (or any non-.go) member lives outside docs/go-corpus/inventory.tsv,
	// so it needs its own dir_input row. Pin it, then tamper with it.
	write(t, filepath.Join(corpus, "test", "zcompiledir.dir", "helper.s"), "// assembly\n")
	tranche := writeTranche(t, "test/zcompiledir.go\tcompiledir")
	r := invokeOpts(t, corpus, tranche, opts{auxTweak: func(aux string) string {
		if !strings.Contains(aux, "dir_input\ttest/zcompiledir.dir/helper.s") {
			t.Fatalf("the auxiliary inventory did not pin the non-.go input:\n%s", aux)
		}
		write(t, filepath.Join(corpus, "test", "zcompiledir.dir", "helper.s"), "// tampered\n")
		return aux
	}})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: an edited non-.go directory input must stop the run", r.exit)
	}
}

// ---------------------------------------------------------------------------
// Toolchain identity. `go version` is a forgeable string; the gate must be
// stronger than it.
// ---------------------------------------------------------------------------

func TestToolchainIdentityRejectsAScriptThatPrintsAPerfectVersion(t *testing.T) {
	corpus := scratchCorpus(t)
	script := filepath.Join(t.TempDir(), "go")
	// This script answers `version` AND `env -json` perfectly, pointing at the
	// real GOROOT, so it clears the version check and every GOROOT source probe.
	// The only thing it cannot be is the reviewed distribution binary.
	write(t, script, "#!/bin/sh\n"+
		"case \"$1\" in\n"+
		"  version) echo \"go version $FAKEGO_VERSION $FAKEGO_GOOS/$FAKEGO_GOARCH\"; exit 0 ;;\n"+
		"  env) printf '{\"GOOS\":\"%s\",\"GOARCH\":\"%s\",\"GOEXPERIMENT\":\"\",\"GODEBUG\":\"\",\"CGO_ENABLED\":\"0\",\"GOROOT\":\"%s\"}\\n' \"$FAKEGO_GOOS\" \"$FAKEGO_GOARCH\" \"$FAKEGO_GOROOT\"; exit 0 ;;\n"+
		"esac\n"+
		"exit 0\n")
	if err := os.Chmod(script, 0o755); err != nil {
		t.Fatal(err)
	}
	r := invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"), opts{
		gotool: script,
		env: []string{
			"FAKEGO_VERSION=" + realVersion,
			"FAKEGO_GOOS=" + runtime.GOOS,
			"FAKEGO_GOARCH=" + runtime.GOARCH,
		},
	})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: a shell script must not pass as the pinned toolchain", r.exit)
	}
	if !strings.Contains(r.stderr, "toolchain identity") {
		t.Fatalf("stderr does not name the identity gate:\n%s", r.stderr)
	}
	if r.summary.Verdict != "fatal" {
		t.Fatalf("summary verdict %q, want fatal", r.summary.Verdict)
	}
}

func TestToolchainIdentityRejectsAWrongBinaryDigest(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"), opts{
		tcTweak: func(tc string) string {
			var out []string
			for _, line := range strings.Split(tc, "\n") {
				if strings.HasPrefix(line, "toolchain\t") {
					f := strings.Split(line, "\t")
					f[4] = strings.Repeat("a", 64)
					line = strings.Join(f, "\t")
				}
				out = append(out, line)
			}
			return strings.Join(out, "\n")
		},
	})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for a toolchain binary that is not the reviewed one", r.exit)
	}
	if !strings.Contains(r.stderr, "not the reviewed") {
		t.Fatalf("stderr does not name the digest mismatch:\n%s", r.stderr)
	}
}

func TestToolchainIdentityRejectsADriftedGOROOT(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"), opts{
		tcTweak: func(tc string) string {
			return strings.Replace(tc, "goroot_probe\tVERSION\t",
				"goroot_probe\tVERSION\t"+strings.Repeat("b", 64)+"\tIGNORED\t", 1)
		},
	})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for a GOROOT whose sources are not the pinned release", r.exit)
	}
}

func TestToolchainIdentityRejectsAnUnreviewedPlatform(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"), opts{
		tcTweak: func(tc string) string {
			var out []string
			for _, line := range strings.Split(tc, "\n") {
				if strings.HasPrefix(line, "toolchain\t") {
					f := strings.Split(line, "\t")
					f[3] = "notanarch"
					line = strings.Join(f, "\t")
				}
				out = append(out, line)
			}
			return strings.Join(out, "\n")
		},
	})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2: an unreviewed platform must be refused, not waved through", r.exit)
	}
	if !strings.Contains(r.stderr, "no reviewed") {
		t.Fatalf("stderr does not explain the unreviewed platform:\n%s", r.stderr)
	}
}

// ---------------------------------------------------------------------------
// Provenance flags are mandatory. An optional gate is off in exactly the runs
// that most need it.
// ---------------------------------------------------------------------------

func TestProvenanceFlagsAreMandatory(t *testing.T) {
	corpus := scratchCorpus(t)
	tranche := writeTranche(t, "test/zrun.go\trun")
	all := provenance(t, corpus, tranche, goToolPath(), opts{})
	for _, drop := range []string{"-inventory", "-aux-inventory", "-toolchain", "-semantics-sha256"} {
		t.Run(strings.TrimPrefix(drop, "-"), func(t *testing.T) {
			var kept []string
			for i := 0; i < len(all); i += 2 {
				if all[i] != drop {
					kept = append(kept, all[i], all[i+1])
				}
			}
			r := invokeOpts(t, corpus, tranche, opts{noProv: true, extra: kept})
			if r.exit != 2 {
				t.Fatalf("exit %d without %s, want 2", r.exit, drop)
			}
			if !strings.Contains(r.stderr, drop+" is required") {
				t.Fatalf("stderr does not demand %s:\n%s", drop, r.stderr)
			}
			if r.summary.Verdict != "fatal" {
				t.Fatalf("summary verdict %q, want fatal", r.summary.Verdict)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Every fatal path leaves machine-readable evidence.
// ---------------------------------------------------------------------------

func TestFatalPathsAlwaysEmitASummary(t *testing.T) {
	corpus := scratchCorpus(t)
	cases := map[string]func() run{
		"empty tranche": func() run { return invoke(t, corpus, writeTranche(t)) },
		"dir path":      func() run { return invoke(t, corpus, writeTranche(t, "test/zrundir.dir/main.go\trun")) },
		"missing file":  func() run { return invoke(t, corpus, writeTranche(t, "test/zabsent.go\trun")) },
		"action drift":  func() run { return invoke(t, corpus, writeTranche(t, "test/zrun.go\tcompile")) },
		"bad version": func() run {
			return invoke(t, corpus, writeTranche(t, "test/zrun.go\trun"), "-go-version", "go0.0.0")
		},
		"bad timeout scale": func() run {
			return invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"),
				opts{env: []string{"GO_TEST_TIMEOUT_SCALE=not-a-number"}})
		},
	}
	for name, fn := range cases {
		t.Run(name, func(t *testing.T) {
			r := fn()
			if r.exit != 2 {
				t.Fatalf("exit %d, want 2", r.exit)
			}
			data, err := os.ReadFile(r.sumPath)
			if err != nil {
				t.Fatalf("a fatal run left no summary: %v\nstderr: %s", err, r.stderr)
			}
			var s Summary
			if err := json.Unmarshal(data, &s); err != nil {
				t.Fatalf("the fatal summary is not valid JSON: %v", err)
			}
			if s.Verdict != "fatal" {
				t.Fatalf("verdict %q, want fatal", s.Verdict)
			}
			if s.FatalReason == "" {
				t.Fatal("the fatal summary carries no machine-readable reason")
			}
			if s.Schema != schemaID {
				t.Fatalf("schema %q, want %q", s.Schema, schemaID)
			}
			if s.Executed < 0 || s.Fail < 0 || s.Reported < 0 {
				t.Fatalf("counts are not reported: executed=%d failed=%d reported=%d", s.Executed, s.Fail, s.Reported)
			}
			// The counts must also be on stdout, as one JSON line, so a caller
			// that captured only stdout still learns how far the run got.
			var line Summary
			last := strings.TrimSpace(r.stdout)
			if last == "" {
				t.Fatal("a fatal run printed no machine-readable summary line")
			}
			if err := json.Unmarshal([]byte(last[strings.LastIndex(last, "\n")+1:]), &line); err != nil {
				t.Fatalf("the stdout summary line is not JSON: %v\n%s", err, r.stdout)
			}
			if line.Verdict != "fatal" || line.FatalReason == "" {
				t.Fatalf("the stdout summary does not carry the fatal verdict: %+v", line)
			}
		})
	}
}

func TestFatalMidRunReportsWhatAlreadyExecuted(t *testing.T) {
	corpus := scratchCorpus(t)
	// zrun.go executes cleanly; the SECOND row is a .dir path, which is fatal.
	// The summary must still say that one file ran and how many commands it took.
	tranche := writeTranche(t, "test/zrun.go\trun", "test/zrundir.dir/main.go\trun")
	r := invoke(t, corpus, tranche)
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2", r.exit)
	}
	if r.summary.Verdict != "fatal" {
		t.Fatalf("verdict %q, want fatal", r.summary.Verdict)
	}
	if r.summary.Executed != 1 {
		t.Fatalf("executed %d, want 1: the first file really did run before the fatal row", r.summary.Executed)
	}
	if r.summary.Commands == 0 {
		t.Fatal("commands 0, but a file executed")
	}
	if r.summary.Selected != 2 || r.summary.Reported != 1 {
		t.Fatalf("selected/reported = %d/%d, want 2/1", r.summary.Selected, r.summary.Reported)
	}
	if len(r.results) != 1 {
		t.Fatalf("%d result records written on the fatal path, want the 1 that completed", len(r.results))
	}
}

// ---------------------------------------------------------------------------
// The bounded seven-action tranche states its own boundary.
// ---------------------------------------------------------------------------

func TestSevenActionsPlusTenUnsupportedExhaustUpstream(t *testing.T) {
	sem, err := os.ReadFile(filepath.Join(realGOROOT, "src", "cmd", "internal", "testdir", "testdir_test.go"))
	if err != nil {
		t.Skipf("real GOROOT has no upstream runner: %v", err)
	}
	if err := checkActionCoverage(sem); err != nil {
		t.Fatalf("the action classification does not match the pinned upstream runner: %v", err)
	}
	if len(trancheActions) != 7 {
		t.Fatalf("%d supported actions, want the committed seven", len(trancheActions))
	}
	if len(unsupportedActions) != 10 {
		t.Fatalf("%d enumerated unsupported actions, want ten", len(unsupportedActions))
	}
	for a, reason := range unsupportedActions {
		if strings.TrimSpace(reason) == "" {
			t.Errorf("unsupported action %q carries no reason", a)
		}
	}
	names := make([]string, 0, len(unsupportedActions))
	for a := range unsupportedActions {
		names = append(names, a)
	}
	sort.Strings(names)
	if len(names)+len(trancheActions) != len(upstreamActions) {
		t.Fatalf("7 + %d != %d upstream actions", len(names), len(upstreamActions))
	}
}

func TestActionCoverageDriftIsCaught(t *testing.T) {
	// A runner that grew an action nobody classified must be rejected, because
	// an unclassified action is how a seven-action tranche starts being read as
	// upstream's full runner.
	fake := []byte("\tswitch action {\n\tcase \"run\", \"brandnewaction\":\n\tdefault:\n\t}\n")
	if err := checkActionCoverage(fake); err == nil {
		t.Fatal("an unclassified upstream action was accepted")
	}
}

func TestUnsupportedUpstreamActionNamesItself(t *testing.T) {
	corpus := scratchCorpus(t)
	// The FILE declares an action upstream supports and this tranche does not.
	write(t, filepath.Join(corpus, "test", "zrun.go"), `// errorcheckdir

package main

func main() {
}
`)
	r := invoke(t, corpus, writeTranche(t, "test/zrun.go\trun"))
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for an upstream action this tranche does not implement", r.exit)
	}
	if !strings.Contains(r.stderr, "bounded tranche does not implement") {
		t.Fatalf("stderr does not state the boundary:\n%s", r.stderr)
	}
	if !strings.Contains(r.stderr, "not upstream's full runner") {
		t.Fatalf("stderr does not deny being upstream's runner:\n%s", r.stderr)
	}
}

func TestSummaryPublishesTheScopeAndTheUnsupportedActions(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	if r.exit != 0 {
		t.Fatalf("exit %d\nstderr: %s", r.exit, r.stderr)
	}
	if !strings.Contains(r.summary.Scope, "NOT upstream's full runner") {
		t.Fatalf("the summary does not state its scope: %q", r.summary.Scope)
	}
	if len(r.summary.SupportedActions) != 7 {
		t.Fatalf("summary lists %d supported actions", len(r.summary.SupportedActions))
	}
	if len(r.summary.UnsupportedActions) != 10 {
		t.Fatalf("summary lists %d unsupported actions; the boundary must travel with the result",
			len(r.summary.UnsupportedActions))
	}
	for _, want := range []string{"asmcheck", "runindir", "errorcheckdir"} {
		if _, ok := r.summary.UnsupportedActions[want]; !ok {
			t.Errorf("summary does not disclaim %q", want)
		}
	}
}

// ---------------------------------------------------------------------------
// Upstream `go env` and timeout-scale semantics.
// ---------------------------------------------------------------------------

func TestGoEnvComesFromThePinnedToolchain(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, writeTranche(t, "test/zrun.go\trun"))
	if r.exit != 0 {
		t.Fatalf("exit %d\nstderr: %s", r.exit, r.stderr)
	}
	if r.summary.GoEnv == nil {
		t.Fatal("the summary records no go env; the tranche's environment is unstated")
	}
	want := strings.TrimSpace(capture(goToolPath(), "env", "GOOS"))
	if r.summary.GoEnv.GOOS != want {
		t.Fatalf("summary GOOS %q, want the toolchain's %q", r.summary.GoEnv.GOOS, want)
	}
	if r.summary.GoEnv.GOROOT == "" {
		t.Fatal("summary records no GOROOT")
	}
	if r.summary.GoEnv.TimeoutScale != 1 {
		t.Fatalf("default timeout scale %d, want 1", r.summary.GoEnv.TimeoutScale)
	}
}

func TestTimeoutScaleFollowsGoTestTimeoutScale(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"),
		opts{env: []string{"GO_TEST_TIMEOUT_SCALE=7"}})
	if r.exit != 0 {
		t.Fatalf("exit %d\nstderr: %s", r.exit, r.stderr)
	}
	if r.summary.GoEnv.TimeoutScale != 7 {
		t.Fatalf("timeout scale %d, want the 7 upstream would have applied", r.summary.GoEnv.TimeoutScale)
	}
}

func TestRecipeTimeoutIsScaled(t *testing.T) {
	env := &goEnv{TimeoutScale: 3}
	rec, err := parseRecipe("run -t 5", env)
	if err != nil {
		t.Fatal(err)
	}
	if rec.timeout != 15 {
		t.Fatalf("timeout %d, want 5*3=15 as upstream computes it", rec.timeout)
	}
}

func TestGoexperimentAndGodebugAppendToTheToolchainBase(t *testing.T) {
	// Upstream seeds both from `go env` and APPENDS the recipe's flag, comma
	// separated. Replacing instead of appending drops the toolchain's own
	// setting, which is a different environment from the one upstream runs in.
	env := &goEnv{GOEXPERIMENT: "boringcrypto", GODEBUG: "http2client=0", TimeoutScale: 1}
	rec, err := parseRecipe("run -goexperiment fieldtrack -godebug gotypesalias=1", env)
	if err != nil {
		t.Fatal(err)
	}
	if rec.goexp != "boringcrypto,fieldtrack" {
		t.Fatalf("GOEXPERIMENT %q, want the base plus the flag", rec.goexp)
	}
	if rec.godebug != "http2client=0,gotypesalias=1" {
		t.Fatalf("GODEBUG %q, want the base plus the flag", rec.godebug)
	}
	if !contains(rec.runenv, "GOEXPERIMENT=boringcrypto,fieldtrack") {
		t.Fatalf("child environment %v does not carry the merged GOEXPERIMENT", rec.runenv)
	}
	if !contains(rec.runenv, "GODEBUG=http2client=0,gotypesalias=1") {
		t.Fatalf("child environment %v does not carry the merged GODEBUG", rec.runenv)
	}
}

func TestGoexperimentDisagreementIsFatal(t *testing.T) {
	corpus := scratchCorpus(t)
	// The goexperiment.* build tags are answered from the driver's own go/build.
	// If the driver's GOEXPERIMENT differs from the toolchain's, constraints
	// would be evaluated against the wrong set — so say so rather than guess.
	r := invokeOpts(t, corpus, writeTranche(t, "test/zrun.go\trun"),
		opts{env: []string{"FAKEGO_GOEXPERIMENT=boringcrypto"}, gotool: fakeRefuse})
	if r.exit != 2 {
		t.Fatalf("exit %d, want 2 for a GOEXPERIMENT the toolchain does not report", r.exit)
	}
	if !strings.Contains(r.stderr, "GOEXPERIMENT disagreement") {
		t.Fatalf("stderr does not name the disagreement:\n%s", r.stderr)
	}
}

// ---------------------------------------------------------------------------
// Artifact evidence in the normal, green case.
// ---------------------------------------------------------------------------

func TestRecordedArtifactsCarryTheirKind(t *testing.T) {
	corpus := scratchCorpus(t)
	r := invoke(t, corpus, scratchTrancheFile(t))
	if r.exit != 0 {
		t.Fatalf("exit %d\nstderr: %s", r.exit, r.stderr)
	}
	kinds := map[string]bool{}
	for _, res := range r.results {
		for _, s := range res.Steps {
			if s.ArtifactKind == "" {
				continue
			}
			kinds[s.ArtifactKind] = true
			if s.ArtifactBytes == 0 {
				t.Errorf("%s: step claims a %s artifact of 0 bytes", res.Path, s.ArtifactKind)
			}
			if s.ArtifactSHA256 == "" {
				t.Errorf("%s: %s artifact has no digest", res.Path, s.ArtifactKind)
			}
		}
	}
	for _, want := range []string{artifactArchive, artifactExecutable, artifactGoSource} {
		if !kinds[want] {
			t.Errorf("no %s artifact was recorded anywhere in the tranche", want)
		}
	}
}
