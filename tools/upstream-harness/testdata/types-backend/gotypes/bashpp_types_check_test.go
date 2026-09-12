// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #149; Story: S149.10; Story-ID: 8ae8f1041a8f
//
// Direct Go-source backend for the authenticated Go 1.27 go/types checker
// harness. Upstream still selects the files, parses the -lang / -fakeImportC
// / -goexperiment flags, applies build constraints, collects the ERROR
// comments and matches them; this hook only replaces the one type-check call
// with the Bash++ check interface on the exact same files and returns its
// positioned diagnostics as the error list upstream matches.
package types_test

import (
	"encoding/json"
	"go/token"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"

	. "go/types"
)

func bashppTypesBackend() bool { return os.Getenv("BASHPP_TYPES_BACKEND") != "" }

var bashppTypesEventsMu sync.Mutex

func bashppTypesEmit(record map[string]any) {
	path := os.Getenv("BASHPP_TYPES_EVENTS")
	if path == "" {
		return
	}
	bashppTypesEventsMu.Lock()
	defer bashppTypesEventsMu.Unlock()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	json.NewEncoder(f).Encode(record)
}

var bashppDiagRx = regexp.MustCompile(`^(.+?):(\d+):(\d+): (.*)$`)

// bashppTypesCheck runs the Bash++ check interface on the upstream-selected
// files with the upstream-parsed language version and returns one Error per
// positioned diagnostic. Upstream's own parse diagnostics are not merged in:
// the check interface reports parse and type diagnostics itself, and the
// deviation is recorded on the event.
func bashppTypesCheck(t *testing.T, filenames []string, srcs [][]byte, lang string, fakeImportC bool, goexperiment string) []error {
	tool := os.Getenv("BASHPP_TYPES_TOOL")
	if tool == "" {
		t.Fatal("Bash++ types backend requires BASHPP_TYPES_TOOL")
	}
	args := []string{"--bashpp", "--source=go", "--check"}
	if lang != "" {
		args = append(args, "--go-version", lang)
	}
	args = append(args, "--go-test-builtins", "--go-checker-branch-errors", "--go-check-after-syntax-errors")
	for _, name := range filenames {
		args = append(args, "--go-file", name)
	}
	cmd := exec.Command(tool, args...)
	env := os.Environ()
	if goexperiment != "" {
		env = append(env, "GOEXPERIMENT="+goexperiment)
	}
	cmd.Env = env
	out, runErr := cmd.CombinedOutput()
	exit := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			exit = ee.ExitCode()
		} else {
			t.Fatalf("Bash++ types backend: launch %s: %v", tool, runErr)
		}
	}
	// Upstream already registered every file in the package fset while
	// parsing; positions are minted inside those files.
	known := map[string]*token.File{}
	fset.Iterate(func(f *token.File) bool {
		for _, name := range filenames {
			if f.Name() == name {
				known[name] = f
			}
		}
		return true
	})
	errs, unparsed := bashppParseGotypesDiagnostics(fset, known, string(out))
	deviations := []string{
		"the one upstream conf.Check call is replaced by the Bash++ check interface on the same files; upstream flag parsing, build constraints, ERROR-comment collection and matching are unchanged",
		"upstream parse diagnostics are not merged: the check interface reports parse and type diagnostics itself",
		"secondary go/types diagnostics are filtered with upstream's own `if !strings.Contains(err.Error(), \": \\t\")` rule after Bash++ diagnostic reconstruction",
		"the check interface is passed --go-test-builtins to mirror upstream's in-process types.DefPredeclaredTestFuncs setup",
		"the check interface is passed --go-checker-branch-errors (this runner's parser runs no branch checks, so label/goto/break errors are go/types') and --go-check-after-syntax-errors (this runner type-checks the partial AST after parse errors and expects both)",
	}
	if fakeImportC {
		deviations = append(deviations, "the check interface has no -fakeImportC; import \"C\" is checked as an ordinary import and any resulting mismatch is a retained product difference")
	}
	bashppTypesEmit(map[string]any{
		"kind":          "types-backend",
		"test":          t.Name(),
		"tool":          map[string]string{"path": tool, "version": os.Getenv("BASHPP_TYPES_VERSION")},
		"files":         filenames,
		"lang":          lang,
		"fake_import_c": fakeImportC,
		"goexperiment":  goexperiment,
		"argv":          append([]string{tool}, args...),
		"exit":          exit,
		"diagnostics":   len(errs),
		"unparsed":      unparsed,
		"deviations":    deviations,
	})
	return errs
}

func bashppParseGotypesDiagnostics(fset *token.FileSet, known map[string]*token.File, out string) ([]error, int) {
	var errs []error
	unparsed := 0
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		// A TAB-prefixed line is gc's continuation of the previous error
		// (the sub-error of a multi-part diagnostic, rendered as
		// "\t<pos>: <msg>"; upstream errorCheck joins it, testdir_test.go:1169).
		// go/types reports that part as a separate secondary Error that
		// upstream check_test.go ignores (`": \t"`), so it is neither an
		// error nor unattributed here.
		if strings.HasPrefix(line, "\t") {
			if len(errs) == 0 {
				unparsed++
			}
			continue
		}
		m := bashppDiagRx.FindStringSubmatch(line)
		if m == nil {
			// A multi-line diagnostic continues the previous one (the
			// importer's own explanation, say); only a line with no
			// diagnostic to belong to is unattributed.
			if n := len(errs); n > 0 {
				prev := errs[n-1].(Error)
				prev.Msg += "\n" + line
				errs[n-1] = prev
			} else {
				unparsed++
			}
			continue
		}
		file, ok := known[m[1]]
		if !ok {
			unparsed++
			continue
		}
		if strings.HasPrefix(m[4], "\t") && len(errs) == 0 {
			unparsed++
			continue
		}
		ln, _ := strconv.Atoi(m[2])
		col, _ := strconv.Atoi(m[3])
		if ln < 1 || ln > file.LineCount() {
			unparsed++
			continue
		}
		pos := file.LineStart(ln) + token.Pos(col-1)
		if col < 1 || int(pos) > file.Base()+file.Size() {
			pos = file.LineStart(ln)
		}
		err := Error{Fset: fset, Pos: pos, Msg: m[4]}
		// Upstream check_test.go: `if !strings.Contains(err.Error(), ": \t")`.
		if !strings.Contains(err.Error(), ": \t") {
			errs = append(errs, err)
		}
	}
	return errs, unparsed
}
