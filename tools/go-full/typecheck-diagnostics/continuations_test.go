// Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestMultilineDiagnosticMessageMatchesWithoutWeakening(t *testing.T) {
	want := "primary\n\thave X\n\twant Y"
	src := "package p\nvar _ = x /* ERROR " + strconv.Quote(want) + " */\n"
	good := "p.go:2:9: " + want + "\n"
	for _, tc := range []struct {
		name, stdout, stderr string
		pass                 bool
	}{
		{"complete", "", good, true},
		{"missing", "", "p.go:2:9: primary\n", false},
		{"wrong-detail", "", strings.Replace(good, "have X", "have Z", 1), false},
		{"spaces-are-not-tabs", "", strings.ReplaceAll(good, "\t", "  "), false},
		{"extra-primary", "", good + "p.go:2:9: unexplained\n", false},
		{"orphan", "", "\thave X\n" + good, false},
		{"split-streams", "p.go:2:9: primary\n", "\thave X\n\twant Y\n", false},
		{"positioned-secondary", "", "p.go:2:9: primary\np.go:2:9: \thave X\n\twant Y\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, err := check(harness(t, src, tc.stdout, tc.stderr, 2, 0))
			if got := err == nil && res.Verdict == "PASS"; got != tc.pass {
				t.Fatalf("pass=%v want=%v err=%v result=%+v", got, tc.pass, err, res)
			}
		})
	}
}

func TestPositionedSecondaryCannotSatisfyMultilinePrimary(t *testing.T) {
	known := map[string]bool{"p.go": true}
	text := "p.go:2:9: first\np.go:2:9: \tsecondary\n\tsecondary continuation\np.go:3:9: second\n\tprimary continuation\n"
	got, bad := parseDiagnostics("stderr", text, known)
	if len(bad) != 0 || len(got) != 2 || got[0].Msg != "first" || got[1].Msg != "second\n\tprimary continuation" {
		t.Fatalf("positioned secondary leaked or primary continuation lost: %+v %+v", got, bad)
	}
}

func TestMultilineERRORxMatchesCompleteMessage(t *testing.T) {
	for _, tc := range []struct {
		pattern, message string
		pass             bool
	}{
		{"^primary\n\tdetail$", "primary\n\tdetail", true},
		{"^primary\n\tdetail$", "primary", false},
		{"^primary\n\tdetail$", "primary\n\twrong", false},
		{"^primary$", "primary\n\tdetail", false},
	} {
		src := "package p\nvar _ = x /* ERRORx " + strconv.Quote(tc.pattern) + " */\n"
		res, err := check(harness(t, src, "", "p.go:2:9: "+tc.message+"\n", 2, 0))
		if got := err == nil && res.Verdict == "PASS"; got != tc.pass {
			t.Fatalf("pattern=%q message=%q pass=%v want=%v err=%v", tc.pattern, tc.message, got, tc.pass, err)
		}
	}
}

func TestMultilineStreamTamperRejected(t *testing.T) {
	src := "package p\nvar _ = x /* ERROR \"primary\\n\\tdetail\" */\n"
	req := harness(t, src, "", "p.go:2:9: primary\n\tdetail\n", 2, 0)
	if err := os.WriteFile(req.Stderr.Path, []byte("p.go:2:9: primary\n\tchanged\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if res, err := check(req); err == nil || res.Verdict == "PASS" {
		t.Fatalf("changed continuation bytes must fail authentication: %v %+v", err, res)
	}
}

func TestPinnedOriginalMultilineDiagnostics(t *testing.T) {
	// Exact Go1.27 source and candidate006 captured stderr. No source or stream
	// substitution, native checker invocation, or fixture body execution occurs.
	for _, tc := range []struct{ name, sourceSHA, stderrSHA string }{
		{"issue49005", "c4ffb5cf92d7628eeb6b2558db434ec1a8ddda45daf9e62b89cdcf2a3120faae", "0f03a01d3d8c13748ec1e92633865ef24eae0e058dfc45d28de26b7da1232250"},
		{"issue70150", "efdcb6e8f301d254b0c38860d20a9ec8d5c67486af3fb5a789b2d91aefe4782e", "916182c9bf6549330bf4f75a014b9fb1ecde7766f7a57c3a222ff80926b4d32b"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			read := func(suffix, expected string) string {
				data, err := os.ReadFile(filepath.Join("testdata", "continuations", tc.name+suffix))
				if err != nil {
					t.Fatal(err)
				}
				sum := sha256.Sum256(data)
				if hex.EncodeToString(sum[:]) != expected {
					t.Fatal("pinned original fixture bytes changed: " + suffix)
				}
				return string(data)
			}
			src, stderr := read(".go.txt", tc.sourceSHA), read(".stderr", tc.stderrSHA)
			for _, mode := range []string{"interpreted", "compiled"} {
				req := harness(t, src, "", stderr, 2, 0)
				req.Mode = mode
				req.Sources[0].Short = "src/internal/types/testdata/fixedbugs/" + tc.name + ".go"
				if res, err := check(req); err != nil || res.Verdict != "PASS" || res.Match.Expected != res.Match.Matched {
					t.Fatalf("%s exact upstream diagnostics: %v %+v", mode, err, res)
				}
			}
		})
	}
}
