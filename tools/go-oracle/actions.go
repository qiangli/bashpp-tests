package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

var errTimeout = errors.New("command exceeded time limit")

// maxRecordedOutput caps how much of a command's combined output lands in the
// result record. Enough to diagnose, bounded enough that a runaway test cannot
// produce a gigabyte of "machine-readable" results.
const maxRecordedOutput = 8192

// ARTIFACT ASSERTIONS.
//
// A compile or link step that exits 0 has said nothing about whether it wrote
// anything. `go tool compile` with a stubbed toolchain, a full disk, or a
// mis-derived -o path can all exit 0 and leave no object behind, and the
// previous shape of this driver would have recorded artifact_bytes 0 and called
// the file a pass — the recorded measurement and the verdict were independent.
//
// So every step that is supposed to produce a file now declares what it expects,
// and the expectation is checked after the process exits: the file must exist,
// be a regular file of the right KIND, and be non-empty where non-empty is
// meaningful. TestFakeGoProducesZeroArtifact is the regression for it.
type artifactSpec struct {
	name string // path, relative to the command's working directory
	kind string // artifactArchive, artifactExecutable, artifactGoSource, or ""
}

const (
	// artifactArchive is what `go tool compile` writes for both -o x.o and
	// -o x.a: a Go object archive, which always begins "!<arch>\n".
	artifactArchive = "goarchive"
	// artifactExecutable is a linked program: a native object-file format, and
	// executable by its mode bits.
	artifactExecutable = "executable"
	// artifactGoSource is a Go program this driver generated — the runoutput
	// tmp__.go. It must exist and be non-empty; it is deliberately NOT required
	// to compile, because a generator that emits broken Go is a real finding
	// that must survive to the comparison rather than be swallowed here.
	artifactGoSource = "gosource"
)

const goArchiveMagic = "!<arch>\n"

// assertArtifact is called only when the command succeeded. A failing command
// is allowed to leave nothing behind; a successful one is not.
func assertArtifact(dir string, spec artifactSpec) error {
	if spec.name == "" || spec.kind == "" {
		return nil
	}
	p := spec.name
	if !filepath.IsAbs(p) {
		p = filepath.Join(dir, p)
	}
	info, err := os.Stat(p)
	if err != nil {
		return fmt.Errorf("the command exited 0 but produced no %s artifact %s: %v", spec.kind, spec.name, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("expected artifact %s to be a regular %s file, got mode %s", spec.name, spec.kind, info.Mode())
	}
	if info.Size() == 0 {
		return fmt.Errorf("expected artifact %s to be a non-empty %s, got 0 bytes", spec.name, spec.kind)
	}
	head := make([]byte, 8)
	f, err := os.Open(p)
	if err != nil {
		return fmt.Errorf("cannot read artifact %s: %v", spec.name, err)
	}
	n, _ := io.ReadFull(f, head)
	f.Close()
	head = head[:n]

	switch spec.kind {
	case artifactArchive:
		if string(head) != goArchiveMagic {
			return fmt.Errorf("artifact %s is %d bytes but is not a Go object archive (want %q, got %q)",
				spec.name, info.Size(), goArchiveMagic, head)
		}
	case artifactExecutable:
		if kind := nativeExecutableKind(head); kind == "" {
			return fmt.Errorf("artifact %s is %d bytes but is not a native executable (magic %x)",
				spec.name, info.Size(), head)
		}
		if info.Mode().Perm()&0o111 == 0 {
			return fmt.Errorf("artifact %s is not executable (mode %s)", spec.name, info.Mode())
		}
	case artifactGoSource:
		// size and regular-file checks above are the whole contract
	default:
		return fmt.Errorf("unknown artifact kind %q for %s", spec.kind, spec.name)
	}
	return nil
}

// execution carries the mutable per-file state of one corpus test.
type execution struct {
	drv     *driver
	res     *Result
	rec     *recipe
	dir     string // test dir relative to <corpus>/test
	goFile  string // base name, e.g. "for.go"
	tempDir string

	runInDir        string
	tempDirIsGOPATH bool
}

func (e *execution) goFileName() string { return filepath.Join(e.dir, e.goFile) }

func (e *execution) goDirName() string {
	return filepath.Join(e.dir, strings.ReplaceAll(e.goFile, ".go", ".dir"))
}

// runcmd spawns one process and records it. spec names the file the command is
// expected to produce, relative to its working directory; it is measured AND
// asserted after the command exits, so the record says what was really written
// and a successful command that wrote nothing is a failure rather than a pass
// with an empty artifact field.
func (e *execution) runcmd(spec artifactSpec, args ...string) ([]byte, error) {
	artifact := spec.name
	cmd := exec.Command(args[0], args[1:]...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	cmd.Env = append(os.Environ(), "GOENV=off", "GOFLAGS=")
	dir := e.runInDir
	if dir == "" {
		dir = e.drv.gorootTestDir
	}
	cmd.Dir = dir
	cmd.Env = append(cmd.Env, "PWD="+dir)
	if e.tempDirIsGOPATH {
		cmd.Env = append(cmd.Env, "GOPATH="+e.tempDir)
	}
	cmd.Env = append(cmd.Env, "STDLIB_IMPORTCFG="+e.drv.stdlibImportcfgFile)
	cmd.Env = append(cmd.Env, e.rec.runenv...)

	start := time.Now()
	var err error
	if e.rec.timeout != 0 {
		err = cmd.Start()
		if err == nil {
			// e.rec.timeout already carries the $GO_TEST_TIMEOUT_SCALE multiplier
			// that upstream applies when it parses the recipe's -t flag.
			timer := time.NewTimer(time.Duration(e.rec.timeout) * time.Second)
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case err = <-done:
			case <-timer.C:
				_ = cmd.Process.Kill()
				<-done
				err = errTimeout
			}
			timer.Stop()
		}
	} else {
		err = cmd.Run()
	}
	elapsed := time.Since(start)

	exit := 0
	if err != nil {
		exit = -1
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exit = ee.ExitCode()
		}
	}
	bytesOut, sum := describeArtifact(dir, artifact)
	out := buf.Bytes()
	recorded := string(out)
	if len(recorded) > maxRecordedOutput {
		recorded = recorded[:maxRecordedOutput] + "\n[truncated]"
	}
	normArgs := make([]string, len(args))
	for i, a := range args {
		normArgs[i] = e.drv.normalize(a)
	}
	e.res.Steps = append(e.res.Steps, Step{
		Command:        normArgs,
		Dir:            e.drv.normalize(dir),
		Exit:           exit,
		DurationMS:     elapsed.Milliseconds(),
		Artifact:       e.drv.normalize(artifact),
		ArtifactKind:   spec.kind,
		ArtifactBytes:  bytesOut,
		ArtifactSHA256: sum,
		Output:         e.drv.normalize(recorded),
	})
	if err != nil && !errors.Is(err, errTimeout) {
		err = fmt.Errorf("%s\n%s", err, out)
	}
	if err == nil {
		if aerr := assertArtifact(dir, spec); aerr != nil {
			return out, fmt.Errorf("%v\ncommand: %s\n%s", aerr, strings.Join(normArgs, " "), out)
		}
	}
	return out, err
}

func (e *execution) goGcflags() string {
	return "-gcflags=all=" + os.Getenv("GO_GCFLAGS")
}

func (e *execution) goGcflagsIsEmpty() bool { return os.Getenv("GO_GCFLAGS") == "" }

// checkExpectedOutput compares against the sibling "<name>.out" file. A missing
// .out file means the program must print nothing.
//
// The .out bytes ARE the expected result, so they go through the auxiliary
// provenance gate before they are believed: verifyExpectedOutput fatals on an
// edited .out, on a missing one the inventory reviewed as present, and on one
// that appeared where the inventory reviewed it as absent.
func (e *execution) checkExpectedOutput(got []byte) error {
	rel := filepath.ToSlash(filepath.Join(e.dir, e.goFile))
	name := strings.TrimSuffix(rel, ".go") + ".out"
	want := e.drv.verifyExpectedOutput(rel)
	g := strings.ReplaceAll(string(got), "\r\n", "\n")
	if g != string(want) {
		if want != nil {
			return fmt.Errorf("output does not match expected in %s. Instead saw\n%s", name, g)
		}
		return fmt.Errorf("output should be empty when (optional) expected-output file %s is not present. Instead saw\n%s", name, g)
	}
	return nil
}

func (e *execution) compileFile(long string) ([]byte, error) {
	cmd := []string{e.drv.goTool, "tool", "compile", "-e", "-p=p", "-importcfg=" + e.drv.stdlibImportcfgFile}
	cmd = append(cmd, e.rec.flags...)
	cmd = append(cmd, long)
	artifact := strings.TrimSuffix(filepath.Base(long), ".go") + ".o"
	return e.runcmd(artifactSpec{name: artifact, kind: artifactArchive}, cmd...)
}

func (e *execution) compileInDir(dir string, importcfg, pkgname string, names ...string) ([]byte, error) {
	if importcfg == "" {
		importcfg = e.drv.stdlibImportcfgFile
	}
	cmd := []string{e.drv.goTool, "tool", "compile", "-e", "-D", "test", "-importcfg=" + importcfg}
	var artifact string
	if pkgname == "main" {
		cmd = append(cmd, "-p=main")
		artifact = strings.TrimSuffix(names[0], ".go") + ".o"
	} else {
		pkgpath := path.Join("test", strings.TrimSuffix(names[0], ".go"))
		cmd = append(cmd, "-o", pkgpath+".a", "-p", pkgpath)
		artifact = pkgpath + ".a"
	}
	cmd = append(cmd, e.rec.flags...)
	for _, name := range names {
		cmd = append(cmd, filepath.Join(dir, name))
	}
	return e.runcmd(artifactSpec{name: artifact, kind: artifactArchive}, cmd...)
}

func (e *execution) linkFile(outfile, infile, importcfg string, ldflags []string) error {
	if importcfg == "" {
		importcfg = e.drv.stdlibImportcfgFile
	}
	if strings.HasSuffix(infile, ".go") {
		infile = strings.TrimSuffix(infile, ".go") + ".o"
	}
	cmd := []string{e.drv.goTool, "tool", "link", "-s", "-w", "-buildid=test", "-o", outfile, "-importcfg=" + importcfg}
	cmd = append(cmd, ldflags...)
	cmd = append(cmd, infile)
	_, err := e.runcmd(artifactSpec{name: outfile, kind: artifactExecutable}, cmd...)
	return err
}

type goDirPkg struct {
	name  string
	files []string
}

var packageRE = regexp.MustCompile(`(?m)^package ([\p{Lu}\p{Ll}\w]+)`)

// goDirPackages groups the .go files of a "<name>.dir" directory into packages
// by their declared package name, in directory (lexicographic) order. This
// grouping IS the upstream contract for compiledir/rundir: the files are a
// dependency-ordered package sequence, not an unordered set.
func (e *execution) goDirPackages(dir string, singlefilepkgs bool) ([]*goDirPkg, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var pkgs []*goDirPkg
	m := make(map[string]*goDirPkg)
	for _, entry := range entries {
		name := entry.Name()
		if filepath.Ext(name) != ".go" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		match := packageRE.FindStringSubmatch(string(data))
		if match == nil {
			return nil, fmt.Errorf("cannot find package name in %s", filepath.Join(dir, name))
		}
		e.drv.verify(filepath.Join(e.goDirName(), name), data)
		p, ok := m[match[1]]
		if singlefilepkgs || !ok {
			p = &goDirPkg{name: match[1]}
			pkgs = append(pkgs, p)
			m[match[1]] = p
		}
		p.files = append(p.files, name)
	}
	if len(pkgs) == 0 {
		return nil, fmt.Errorf("no .go files in %s", dir)
	}
	return pkgs, nil
}

// importcfgFor writes the importcfg used by a directory test: the stdlib map
// plus one packagefile line per package the directory itself builds.
func (e *execution) importcfgFor(pkgs []*goDirPkg) (string, error) {
	cfg := e.drv.stdlibImportcfg
	for _, pkg := range pkgs {
		pkgpath := path.Join("test", strings.TrimSuffix(pkg.files[0], ".go"))
		cfg += "\npackagefile " + pkgpath + "=" + filepath.Join(e.tempDir, pkgpath+".a")
	}
	name := filepath.Join(e.tempDir, "importcfg")
	if err := os.WriteFile(name, []byte(cfg), 0o644); err != nil {
		return "", err
	}
	return name, nil
}

// perform dispatches on the action. Every branch spawns at least one process.
func (e *execution) perform() error {
	long := filepath.Join(e.drv.gorootTestDir, e.goFileName())
	switch e.rec.action {
	case "errorcheck":
		cmdline := []string{e.drv.goTool, "tool", "compile", "-p=p", "-d=panic", "-C", "-e",
			"-importcfg=" + e.drv.stdlibImportcfgFile, "-o", "a.o"}
		cmdline = append(cmdline, e.rec.flags...)
		cmdline = append(cmdline, long)
		// No artifact spec: an errorcheck file is REQUIRED to fail compilation,
		// so demanding an object here would assert the opposite of the contract.
		out, err := e.runcmd(artifactSpec{name: "a.o"}, cmdline...)
		if e.rec.wantError {
			if err == nil {
				return fmt.Errorf("compilation succeeded unexpectedly\n%s", out)
			}
			if errors.Is(err, errTimeout) {
				return fmt.Errorf("compilation timed out")
			}
		} else if err != nil {
			return err
		}
		return errorCheck(string(out), e.rec.wantAuto, long, e.goFile)

	case "compile":
		_, err := e.compileFile(long)
		return err

	case "compiledir":
		e.drv.verifyDirManifest(filepath.ToSlash(e.goDirName()))
		longdir := filepath.Join(e.drv.gorootTestDir, e.goDirName())
		pkgs, err := e.goDirPackages(longdir, e.rec.singlefilepkgs)
		if err != nil {
			return err
		}
		importcfgfile, err := e.importcfgFor(pkgs)
		if err != nil {
			return err
		}
		for _, pkg := range pkgs {
			if _, err := e.compileInDir(longdir, importcfgfile, pkg.name, pkg.files...); err != nil {
				return err
			}
		}
		return nil

	case "rundir":
		e.drv.verifyDirManifest(filepath.ToSlash(e.goDirName()))
		longdir := filepath.Join(e.drv.gorootTestDir, e.goDirName())
		pkgs, err := e.goDirPackages(longdir, e.rec.singlefilepkgs)
		if err != nil {
			return err
		}
		var ldflags []string
		flags := e.rec.flags
		for i, fl := range flags {
			if fl == "-ldflags" {
				ldflags = flags[i+1:]
				e.rec.flags = flags[:i]
				break
			}
		}
		importcfgfile, err := e.importcfgFor(pkgs)
		if err != nil {
			return err
		}
		for i, pkg := range pkgs {
			if _, err := e.compileInDir(longdir, importcfgfile, pkg.name, pkg.files...); err != nil {
				return err
			}
			if i != len(pkgs)-1 {
				continue
			}
			if err := e.linkFile("a.exe", pkg.files[0], importcfgfile, ldflags); err != nil {
				return err
			}
			cmd := append([]string{filepath.Join(e.tempDir, "a.exe")}, e.rec.args...)
			out, err := e.runcmd(artifactSpec{name: "a.exe", kind: artifactExecutable}, cmd...)
			if err != nil {
				return err
			}
			return e.checkExpectedOutput(out)
		}
		return nil

	case "build":
		cmd := []string{e.drv.goTool, "build", e.goGcflags()}
		cmd = append(cmd, e.rec.flags...)
		cmd = append(cmd, "-o", "a.exe", long)
		_, err := e.runcmd(artifactSpec{name: "a.exe", kind: artifactExecutable}, cmd...)
		return err

	case "run":
		e.runInDir = ""
		var out []byte
		var err error
		// Upstream takes the fast path only when nothing in play could make the
		// go command's own machinery matter: no special flags, and the
		// toolchain's GOOS/GOARCH/GOEXPERIMENT/GODEBUG all still equal what this
		// process and this recipe would otherwise have to impose on a child.
		// Dropping those four conditions, as an earlier draft of this driver did,
		// silently runs a -goexperiment or -godebug test WITHOUT its environment.
		env := e.drv.env
		sameEnv := env.GOOS == runtime.GOOS && env.GOARCH == runtime.GOARCH &&
			e.rec.goexp == env.GOEXPERIMENT && e.rec.godebug == env.GODEBUG
		if len(e.rec.flags)+len(e.rec.args) == 0 && e.goGcflagsIsEmpty() && sameEnv {
			// Skip the go command entirely when no special flags are in play,
			// exactly as upstream does; these programs are tiny and the go
			// command's up-to-date checking would dominate the measurement.
			pkg := filepath.Join(e.tempDir, "pkg.a")
			if _, err := e.runcmd(artifactSpec{name: pkg, kind: artifactArchive},
				e.drv.goTool, "tool", "compile", "-p=main",
				"-importcfg="+e.drv.stdlibImportcfgFile, "-o", pkg, e.goFileName()); err != nil {
				return err
			}
			exe := filepath.Join(e.tempDir, "test.exe")
			if err := e.linkFile(exe, pkg, e.drv.stdlibImportcfgFile, nil); err != nil {
				return err
			}
			out, err = e.runcmd(artifactSpec{name: exe, kind: artifactExecutable},
				append([]string{exe}, e.rec.args...)...)
		} else {
			cmd := []string{e.drv.goTool, "run", e.goGcflags()}
			cmd = append(cmd, e.rec.flags...)
			cmd = append(cmd, e.goFileName())
			out, err = e.runcmd(artifactSpec{}, append(cmd, e.rec.args...)...)
		}
		if err != nil {
			return err
		}
		return e.checkExpectedOutput(out)

	case "runoutput":
		// Generator semantics: the corpus file PRINTS a Go program; that program
		// is what gets compiled and run, and its output is what is compared.
		e.runInDir = ""
		cmd := []string{e.drv.goTool, "run", e.goGcflags(), e.goFileName()}
		out, err := e.runcmd(artifactSpec{}, append(cmd, e.rec.args...)...)
		if err != nil {
			return err
		}
		tfile := filepath.Join(e.tempDir, "tmp__.go")
		if err := os.WriteFile(tfile, out, 0o666); err != nil {
			return err
		}
		out, err = e.runcmd(artifactSpec{name: tfile, kind: artifactGoSource},
			e.drv.goTool, "run", e.goGcflags(), tfile)
		if err != nil {
			return err
		}
		return e.checkExpectedOutput(out)
	}
	return fmt.Errorf("unimplemented action %q", e.rec.action)
}
