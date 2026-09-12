// Copyright 2026 The bashpp-tests Authors. All rights reserved.
// Sprint: #149; Story: S149.10; Story-ID: 8ae8f1041a8f
//
// Direct Go-source backend for the authenticated Go 1.27 types2 checker
// harness. Upstream still selects the files, parses the -lang / -fakeImportC
// / -goexperiment flags, applies build constraints, collects the ERROR
// comments and matches them; this hook only replaces the one type-check call
// with the Bash++ check interface on the exact same files and returns its
// positioned diagnostics as the error list upstream matches.
package types2_test

import (
	"cmd/compile/internal/syntax"
	"encoding/json"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"

	. "cmd/compile/internal/types2"
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
	known := map[string]*syntax.PosBase{}
	for _, name := range filenames {
		known[name] = syntax.NewFileBase(name)
	}
	errs, unparsed := bashppParseTypes2Diagnostics(known, string(out))
	deviations := []string{
		"the one upstream conf.Check call is replaced by the Bash++ check interface on the same files; upstream flag parsing, build constraints, ERROR-comment collection and matching are unchanged",
		"upstream parse diagnostics are not merged: the check interface reports parse and type diagnostics itself",
		"positioned secondary diagnostics whose message starts with a tab are folded into the previous types2 Error message to mirror upstream's multi-part diagnostic rendering",
		"the check interface is passed --go-test-builtins to mirror upstream's in-process types.DefPredeclaredTestFuncs setup",
		"the check interface is passed --go-checker-branch-errors (this runner parses without syntax.CheckBranches and leaves Config.IgnoreBranchErrors false, so label/goto/break errors are the checker's) and --go-check-after-syntax-errors (this runner type-checks the partial AST after parse errors and expects both)",
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

func bashppParseTypes2Diagnostics(known map[string]*syntax.PosBase, out string) ([]error, int) {
	var errs []error
	unparsed := 0
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		// A TAB-prefixed line is gc's continuation of the previous error
		// (the sub-error of a multi-part diagnostic, rendered as
		// "\t<pos>: <msg>"); upstream errorCheck joins it the same way
		// (cmd/internal/testdir/testdir_test.go:1169), and types2 itself
		// carries the part inside one message joined by "\n\t".
		if strings.HasPrefix(line, "\t") {
			if n := len(errs); n > 0 {
				prev := errs[n-1].(Error)
				prev.Msg += "\n" + line
				errs[n-1] = prev
			} else {
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
		if strings.HasPrefix(m[4], "\t") {
			if n := len(errs); n > 0 {
				prev := errs[n-1].(Error)
				prev.Msg += "\n\t" + m[1] + ":" + m[2] + ":" + m[3] + ": " + strings.TrimPrefix(m[4], "\t")
				errs[n-1] = prev
			} else {
				unparsed++
			}
			continue
		}
		base, ok := known[m[1]]
		if !ok {
			unparsed++
			continue
		}
		ln, _ := strconv.Atoi(m[2])
		col, _ := strconv.Atoi(m[3])
		errs = append(errs, Error{Pos: syntax.MakePos(base, uint(ln), uint(col)), Msg: m[4]})
	}
	return errs, unparsed
}
