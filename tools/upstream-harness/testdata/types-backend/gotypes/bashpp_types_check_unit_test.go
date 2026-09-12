package types_test

import (
	"go/token"
	"testing"

	. "go/types"
)

func gotypesFixture() (*token.FileSet, map[string]*token.File) {
	fset := token.NewFileSet()
	src := []byte("package p\nvar y int\nvar x int\nvar x int\n")
	file := fset.AddFile("file.go", -1, len(src))
	file.SetLinesForContent(src)
	return fset, map[string]*token.File{"file.go": file}
}

func TestBashppParseGotypesDropsSecondaryDiagnostics(t *testing.T) {
	fset, known := gotypesFixture()
	errs, unparsed := bashppParseGotypesDiagnostics(fset, known, "file.go:4:5: x redeclared in this block\nfile.go:3:5: \tother declaration of x\n")
	if unparsed != 0 {
		t.Fatalf("unparsed = %d, want 0", unparsed)
	}
	if len(errs) != 1 {
		t.Fatalf("len(errs) = %d, want 1: %v", len(errs), errs)
	}
	err := errs[0].(Error)
	if got := fset.Position(err.Pos); got.Filename != "file.go" || got.Line != 4 || got.Column != 5 {
		t.Fatalf("position = %v, want file.go:4:5", got)
	}
	if err.Msg != "x redeclared in this block" {
		t.Fatalf("Msg = %q", err.Msg)
	}
}

func TestBashppParseGotypesLeadingTabFirstIsUnparsed(t *testing.T) {
	fset, known := gotypesFixture()
	errs, unparsed := bashppParseGotypesDiagnostics(fset, known, "file.go:3:5: \tother declaration of x\n")
	if len(errs) != 0 || unparsed != 1 {
		t.Fatalf("errs, unparsed = %d, %d; want 0, 1", len(errs), unparsed)
	}
}

func TestBashppParseGotypesKeepsIndependentPrimaries(t *testing.T) {
	fset, known := gotypesFixture()
	errs, unparsed := bashppParseGotypesDiagnostics(fset, known, "file.go:3:5: first primary\nfile.go:4:5: second primary\n")
	if unparsed != 0 {
		t.Fatalf("unparsed = %d, want 0", unparsed)
	}
	if len(errs) != 2 {
		t.Fatalf("len(errs) = %d, want 2: %v", len(errs), errs)
	}
}

func TestBashppParseGotypesDropsTwoSecondaryDiagnostics(t *testing.T) {
	fset, known := gotypesFixture()
	errs, unparsed := bashppParseGotypesDiagnostics(fset, known, "file.go:4:5: x redeclared in this block\nfile.go:3:5: \tother declaration of x\nfile.go:2:5: \tprevious case\n")
	if unparsed != 0 {
		t.Fatalf("unparsed = %d, want 0", unparsed)
	}
	if len(errs) != 1 {
		t.Fatalf("len(errs) = %d, want 1: %v", len(errs), errs)
	}
}

// Sprint: #154; Story: S154.1; Story-ID: 29abb27c8659
// gc's own shape for a sub-error: a TAB-prefixed line carrying its position
// is the secondary go/types ignores — never an error, never unattributed.
func TestBashppParseGotypesDropsGcShapedContinuation(t *testing.T) {
	fset, known := gotypesFixture()
	errs, unparsed := bashppParseGotypesDiagnostics(fset, known, "file.go:4:5: x redeclared in this block\n\tfile.go:3:5: other declaration of x\n")
	if unparsed != 0 || len(errs) != 1 {
		t.Fatalf("errs, unparsed = %d, %d; want 1, 0: %v", len(errs), unparsed, errs)
	}
	if errs, unparsed := bashppParseGotypesDiagnostics(fset, known, "\tfile.go:3:5: other declaration of x\n"); len(errs) != 0 || unparsed != 1 {
		t.Fatalf("leading continuation: errs, unparsed = %d, %d; want 0, 1", len(errs), unparsed)
	}
}
