// Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func write(t *testing.T, dir, name, body string) fileInput {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(body))
	return fileInput{Path: path, Short: name, SHA256: hex.EncodeToString(sum[:])}
}

func exitCode(n int) *int { return &n }

// harness builds a complete request for one single-file fixture.
func harness(t *testing.T, src, stdout, stderr string, exit int, tolerance int) request {
	t.Helper()
	dir := t.TempDir()
	source := write(t, dir, "p.go", src)
	out := write(t, dir, "check.stdout", stdout)
	errs := write(t, dir, "check.stderr", stderr)
	out.Short, errs.Short = "", ""
	return request{
		Family: "TestCheck", Mode: "interpreted", ColumnTolerance: tolerance,
		Sources: []fileInput{source}, Stdout: out, Stderr: errs,
		Process: processInput{Spawned: true, State: "exited", Exit: exitCode(exit)},
	}
}

const blank = "package _ /* ERROR \"invalid package name\" */\n"

func TestCommentMapPositionsFollowPrecedingToken(t *testing.T) {
	// Same expectations as the upstream commentMap test: the recorded position
	// is the preceding token, and inserted semicolons never move it.
	src := "x /* ERROR \"3:1\" */\n"
	src = "/* ERROR \"0:0\" */\n" + src
	m := commentMap([]byte("/* ERROR \"0:0\" */ // ERROR \"0:0\"\nx /* ERROR \"2:1\" */\n"), errorPattern)
	if len(m[0]) != 2 {
		t.Fatalf("comments before any token must record line 0, got %#v", m)
	}
	if len(m[2]) != 1 || m[2][0].col != 1 {
		t.Fatalf("comment after x must record 2:1, got %#v", m[2])
	}
	if got := commentMap([]byte(src), errorPattern); len(got) == 0 {
		t.Fatal("expected annotations")
	}
	if commentMap([]byte("package p // note\n"), errorPattern) != nil {
		t.Fatal("non-ERROR comments must not be collected")
	}
}

func TestMatchingFixtureWithExactPositionPasses(t *testing.T) {
	req := harness(t, blank, "", "p.go:1:9: invalid package name _\n", 2, 0)
	res, err := check(req)
	if err != nil || res.Verdict != "PASS" {
		t.Fatalf("verdict=%s err=%v match=%+v", res.Verdict, err, res.Match)
	}
	if res.Match.Expected != 1 || res.Match.Matched != 1 || res.Match.Observed != 1 {
		t.Fatalf("denominators drifted: %+v", res.Match)
	}
}

func TestPositiveFixtureWithNoAnnotationsPasses(t *testing.T) {
	res, err := check(harness(t, "package p\n\nfunc f() {}\n", "", "", 0, 0))
	if err != nil || res.Verdict != "PASS" || res.WantError {
		t.Fatalf("clean fixture must pass: verdict=%s err=%v", res.Verdict, err)
	}
}

func TestCleanExitWithRequiredAnnotationsFails(t *testing.T) {
	// A frontend that silently accepts a negative fixture must never pass.
	res, err := check(harness(t, blank, "", "", 0, 0))
	if err == nil || res.Verdict == "PASS" {
		t.Fatalf("silent acceptance must fail, got %s", res.Verdict)
	}
}

func TestFailingExitWithoutAnnotationsFails(t *testing.T) {
	res, err := check(harness(t, "package p\n", "", "p.go:1:1: boom\n", 1, 0))
	if err == nil || res.Verdict == "PASS" {
		t.Fatalf("unexpected rejection of a positive fixture must fail, got %s", res.Verdict)
	}
}

func TestExtraDiagnosticFails(t *testing.T) {
	src := blank + "var _ = undef /* ERROR \"undefined\" */\n"
	stderr := "p.go:1:9: invalid package name _\np.go:2:9: undefined: undef\np.go:2:9: spurious extra message\n"
	res, err := check(harness(t, src, "", stderr, 2, 0))
	if err == nil || res.Verdict == "PASS" {
		t.Fatalf("extra diagnostics must fail, got %s", res.Verdict)
	}
	if len(res.Match.UnmatchedObserved) != 1 {
		t.Fatalf("expected exactly one unmatched diagnostic: %+v", res.Match)
	}
}

func TestUnreportedAnnotationFails(t *testing.T) {
	src := blank + "var _ = undef /* ERROR \"undefined\" */\n"
	res, err := check(harness(t, src, "", "p.go:1:9: invalid package name _\n", 2, 0))
	if err == nil || res.Verdict == "PASS" {
		t.Fatalf("missing diagnostics must fail, got %s", res.Verdict)
	}
	if len(res.Match.UnmatchedExpected) != 1 || res.Match.UnmatchedExpected[0].Line != 2 {
		t.Fatalf("expected the line 2 annotation to be reported unmet: %+v", res.Match)
	}
}

func TestColumnToleranceIsEnforced(t *testing.T) {
	// go/types roots carry tolerance 0; types2 roots carry the family delta.
	req := harness(t, blank, "", "p.go:1:14: invalid package name _\n", 2, 0)
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("column drift must fail at tolerance 0, got %s", res.Verdict)
	}
	req = harness(t, blank, "", "p.go:1:14: invalid package name _\n", 2, 100)
	if res, err := check(req); err != nil || res.Verdict != "PASS" {
		t.Fatalf("column drift within tolerance must pass: %v %+v", err, res.Match)
	}
}

func TestERRORxIsARegularExpression(t *testing.T) {
	src := "package p\nvar _ = x /* ERRORx \"undefined: [a-z]+\" */\n"
	if res, err := check(harness(t, src, "", "p.go:2:9: undefined: x\n", 2, 0)); err != nil || res.Verdict != "PASS" {
		t.Fatalf("ERRORx must match as a regexp: %v %+v", err, res.Match)
	}
	src = "package p\nvar _ = x /* ERRORx \"undefined: [0-9]+\" */\n"
	if res, _ := check(harness(t, src, "", "p.go:2:9: undefined: x\n", 2, 0)); res.Verdict == "PASS" {
		t.Fatal("a non-matching ERRORx regexp must fail")
	}
}

func TestSecondaryDetailLinesAttachToTheirDiagnostic(t *testing.T) {
	src := "package p\nvar _ = x /* ERROR \"does not implement\" */\n"
	stderr := "p.go:2:9: I does not implement J\n\t\thave m()\n\t\twant m(int)\n"
	res, err := check(harness(t, src, "", stderr, 2, 0))
	if err != nil || res.Verdict != "PASS" {
		t.Fatalf("tab-indented clarifications must not count as diagnostics: %v %+v", err, res)
	}
	if len(res.Match.UnmatchedObserved) != 0 || res.Match.Observed != 1 {
		t.Fatalf("clarifications must fold into their primary: %+v", res.Match)
	}
}

func TestUnpositionedOutputFails(t *testing.T) {
	res, err := check(harness(t, blank, "", "p.go:1:9: invalid package name _\npanic: frontend crashed\n", 2, 0))
	if err == nil || res.Verdict == "PASS" {
		t.Fatalf("unexplained output must fail, got %s", res.Verdict)
	}
	if len(res.Unparsed) != 1 || !strings.Contains(res.Unparsed[0], "panic") {
		t.Fatalf("unexplained output must be retained: %+v", res.Unparsed)
	}
}

func TestForeignFileDiagnosticIsNotCredited(t *testing.T) {
	res, _ := check(harness(t, blank, "", "other.go:1:9: invalid package name _\n", 2, 0))
	if res.Verdict == "PASS" {
		t.Fatal("a diagnostic about a file outside the fixture must not be credited")
	}
}

func TestTamperedFixtureIsRejected(t *testing.T) {
	req := harness(t, blank, "", "p.go:1:9: invalid package name _\n", 2, 0)
	if err := os.WriteFile(req.Sources[0].Path, []byte("package q\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("a rewritten fixture must be rejected, got %s", res.Verdict)
	}
}

func TestTamperedStreamIsRejected(t *testing.T) {
	req := harness(t, blank, "", "p.go:1:9: invalid package name _\n", 2, 0)
	if err := os.WriteFile(req.Stderr.Path, []byte("p.go:1:9: invalid package name _\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	req.Stderr.SHA256 = strings.Repeat("0", 64)
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("a stream that does not authenticate must be rejected, got %s", res.Verdict)
	}
}

func TestAbnormalTerminationIsNeverAPass(t *testing.T) {
	for _, state := range []string{"deadline", "process_leak", "launch_failure"} {
		req := harness(t, blank, "", "p.go:1:9: invalid package name _\n", 2, 0)
		req.Process.State = state
		if res, err := check(req); err == nil || res.Verdict == "PASS" {
			t.Fatalf("state %s must fail, got %s", state, res.Verdict)
		}
	}
	req := harness(t, blank, "", "p.go:1:9: invalid package name _\n", 2, 0)
	sig := 9
	req.Process.Signal = &sig
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("a signalled check must fail, got %s", res.Verdict)
	}
}

func TestUnsafeSelectorIsRejected(t *testing.T) {
	req := harness(t, blank, "", "", 2, 0)
	req.Sources[0].Short = "../escape.go"
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("an escaping selector must be rejected, got %s", res.Verdict)
	}
}

func TestUnknownModeIsRejected(t *testing.T) {
	req := harness(t, blank, "", "p.go:1:9: invalid package name _\n", 2, 0)
	req.Mode = "native"
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("only the product checking phases may be adjudicated, got %s", res.Verdict)
	}
}

func TestClosestColumnConsumesOneAnnotationEach(t *testing.T) {
	// Two annotations on one line must be consumed by two distinct diagnostics.
	src := "package p\nvar _ = a /* ERROR \"undefined: a\" */ + b /* ERROR \"undefined: b\" */\n"
	stderr := "p.go:2:9: undefined: a\np.go:2:40: undefined: b\n"
	if res, err := check(harness(t, src, "", stderr, 2, 100)); err != nil || res.Verdict != "PASS" {
		t.Fatalf("both annotations must be consumed: %v %+v", err, res.Match)
	}
	single := "p.go:2:9: undefined: a\n"
	if res, _ := check(harness(t, src, "", single, 2, 100)); res.Verdict == "PASS" {
		t.Fatal("one diagnostic must not satisfy two annotations")
	}
}

func TestParseDiagnosticsKeepsStreamAttribution(t *testing.T) {
	known := map[string]bool{"p.go": true}
	got, bad := parseDiagnostics("stderr", "p.go:1:2: a\n", known)
	if len(bad) != 0 || len(got) != 1 || got[0].Stream != "stderr" || got[0].Line != 1 || got[0].Col != 2 {
		t.Fatalf("unexpected parse: %+v %+v", got, bad)
	}
}

func TestErrorPatternSelectorMatchesUpstream(t *testing.T) {
	for _, text := range []string{" ERROR \"x\"", " ERRORx \"x\""} {
		if !errorPattern.MatchString(text) {
			t.Fatalf("selector must accept %q", text)
		}
	}
	for _, text := range []string{"ERROR \"x\"", " ERRORS \"x\"", " error \"x\""} {
		if errorPattern.MatchString(text) {
			t.Fatalf("selector must reject %q", text)
		}
	}
	if regexp.MustCompile("^ ERRORx? ").String() != errorPattern.String() {
		t.Fatal("selector drifted from the harness")
	}
}

func TestPositionedSecondaryMessagesAreNotDiagnostics(t *testing.T) {
	// go/types reports "T3 refers to T4" style clarifications as separate,
	// positioned errors; Config.Error drops every message containing ": \t".
	src := "package p\ntype T3 T4 /* ERROR \"invalid recursive type\" */\n"
	stderr := "p.go:2:6: invalid recursive type T3\np.go:2:6: \tT3 refers to T4\np.go:2:6: \tT4 refers to T3\n"
	res, err := check(harness(t, src, "", stderr, 2, 100))
	if err != nil || res.Verdict != "PASS" {
		t.Fatalf("clarifications must not be unexpected diagnostics: %v %+v", err, res)
	}
	if res.Match.Observed != 1 || len(res.Match.UnmatchedObserved) != 0 {
		t.Fatalf("only the primary error may be matched: %+v", res.Match)
	}
	if len(res.Unparsed) != 0 {
		t.Fatalf("clarifications must not be unparsed output: %+v", res.Unparsed)
	}
}

func TestLeadingSecondaryWithoutPrimaryIsUnexplained(t *testing.T) {
	res, err := check(harness(t, blank, "", "p.go:1:9: \tdangling clarification\n", 2, 0))
	if err == nil || res.Verdict == "PASS" {
		t.Fatalf("a clarification with no primary must fail, got %s", res.Verdict)
	}
}
