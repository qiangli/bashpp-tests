package types2_test

import (
	"cmd/compile/internal/syntax"
	"testing"

	. "cmd/compile/internal/types2"
)

func types2Fixture() map[string]*syntax.PosBase {
	return map[string]*syntax.PosBase{"file.go": syntax.NewFileBase("file.go")}
}

func TestBashppTypes2JoinsSecondaryDiagnostics(t *testing.T) {
	errs, unparsed := bashppParseTypes2Diagnostics(types2Fixture(), "file.go:4:5: x redeclared in this block\nfile.go:3:5: \tother declaration of x\n")
	if unparsed != 0 {
		t.Fatalf("unparsed = %d, want 0", unparsed)
	}
	if len(errs) != 1 {
		t.Fatalf("len(errs) = %d, want 1: %v", len(errs), errs)
	}
	err := errs[0].(Error)
	if got := err.Pos.String(); got != "file.go:4:5" {
		t.Fatalf("position = %s, want file.go:4:5", got)
	}
	want := "x redeclared in this block\n\tfile.go:3:5: other declaration of x"
	if err.Msg != want {
		t.Fatalf("Msg = %q, want %q", err.Msg, want)
	}
}

func TestBashppTypes2LeadingTabFirstIsUnparsed(t *testing.T) {
	errs, unparsed := bashppParseTypes2Diagnostics(types2Fixture(), "file.go:3:5: \tother declaration of x\n")
	if len(errs) != 0 || unparsed != 1 {
		t.Fatalf("errs, unparsed = %d, %d; want 0, 1", len(errs), unparsed)
	}
}

func TestBashppTypes2KeepsIndependentPrimaries(t *testing.T) {
	errs, unparsed := bashppParseTypes2Diagnostics(types2Fixture(), "file.go:3:5: first primary\nfile.go:4:5: second primary\n")
	if unparsed != 0 {
		t.Fatalf("unparsed = %d, want 0", unparsed)
	}
	if len(errs) != 2 {
		t.Fatalf("len(errs) = %d, want 2: %v", len(errs), errs)
	}
}

func TestBashppTypes2JoinsTwoSecondaryDiagnostics(t *testing.T) {
	errs, unparsed := bashppParseTypes2Diagnostics(types2Fixture(), "file.go:4:5: x redeclared in this block\nfile.go:3:5: \tother declaration of x\nfile.go:2:5: \tprevious case\n")
	if unparsed != 0 {
		t.Fatalf("unparsed = %d, want 0", unparsed)
	}
	if len(errs) != 1 {
		t.Fatalf("len(errs) = %d, want 1: %v", len(errs), errs)
	}
	want := "x redeclared in this block\n\tfile.go:3:5: other declaration of x\n\tfile.go:2:5: previous case"
	if got := errs[0].(Error).Msg; got != want {
		t.Fatalf("Msg = %q, want %q", got, want)
	}
}
