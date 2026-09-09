// Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
// Positioned matcher for the official go/types + types2 check harnesses.
// This file never type-checks anything: it only compares diagnostics that the
// product already emitted against the immutable ERROR/ERRORx annotations that
// are present in the original, byte-identical fixture sources.
package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// diagnostic is one product-reported message with its source position.
type diagnostic struct {
	File      string   `json:"file"`
	Line      int      `json:"line"`
	Col       int      `json:"column"`
	Msg       string   `json:"message"`
	Stream    string   `json:"stream"`
	Secondary []string `json:"secondary,omitempty"`
}

func (d diagnostic) String() string { return fmt.Sprintf("%s:%d:%d: %s", d.File, d.Line, d.Col, d.Msg) }

// positionRx matches a leading "file:line:col: " diagnostic prefix. Windows
// volume names cannot appear in this corpus, so ":" is unambiguous here.
var positionRx = regexp.MustCompile(`^(.*?):(\d+):(\d+): (.*)$`)

// secondaryMarker is the exact test the upstream harness applies in
// Config.Error to drop clarifying messages: they are never matched against
// ERROR annotations, and they are never counted as unexpected diagnostics.
const secondaryMarker = ": \t"

// parseDiagnostics splits one captured stream into positioned diagnostics.
// A line starting with a tab continues the previous Error.Msg, including its
// newline and indentation. A positioned line whose message itself begins with
// a tab is a separate upstream secondary error; it and its continuations are
// retained but never joined into a matchable primary message. Any other line
// that is not a positioned diagnostic for a known
// fixture file is reported as unparsed: the caller must never treat unexplained
// output as a pass.
func parseDiagnostics(stream, text string, known map[string]bool) (found []diagnostic, unparsed []string) {
	positionedSecondary := false
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSuffix(raw, "\r")
		if strings.HasPrefix(line, "\t") {
			if len(found) == 0 {
				unparsed = append(unparsed, line)
				continue
			}
			found[len(found)-1].Secondary = append(found[len(found)-1].Secondary, line)
			if !positionedSecondary {
				// An unpositioned continuation belongs to the same Error.Msg.
				// Upstream unpackError returns that complete message, including
				// literal newlines and tabs used by ERROR/ERRORx annotations.
				found[len(found)-1].Msg += "\n" + line
			}
			continue
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		m := positionRx.FindStringSubmatch(line)
		if m == nil || !known[filepath.Clean(m[1])] {
			unparsed = append(unparsed, line)
			continue
		}
		row, err1 := strconv.Atoi(m[2])
		col, err2 := strconv.Atoi(m[3])
		if err1 != nil || err2 != nil {
			unparsed = append(unparsed, line)
			continue
		}
		if strings.Contains(line, secondaryMarker) {
			// Secondary clarification for the preceding primary error.
			if len(found) == 0 {
				unparsed = append(unparsed, line)
				continue
			}
			found[len(found)-1].Secondary = append(found[len(found)-1].Secondary, line)
			positionedSecondary = true
			continue
		}
		found = append(found, diagnostic{File: filepath.Clean(m[1]), Line: row, Col: col, Msg: m[4], Stream: stream})
		positionedSecondary = false
	}
	return found, unparsed
}

// absDiff returns the absolute difference between x and y (upstream helper).
func absDiff(x, y int) int {
	if x < y {
		return y - x
	}
	return x - y
}

type expectation struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Col  int    `json:"column"`
	Text string `json:"text"`
}

type mismatch struct {
	Diagnostic diagnostic `json:"diagnostic"`
	GotCol     int        `json:"got_column"`
	WantCol    int        `json:"want_column"`
	Tolerance  int        `json:"column_tolerance"`
}

type matchResult struct {
	Expected          int           `json:"expected_diagnostics"`
	Observed          int           `json:"observed_diagnostics"`
	Matched           int           `json:"matched_diagnostics"`
	UnmatchedObserved []diagnostic  `json:"unmatched_observed"`
	UnmatchedExpected []expectation `json:"unmatched_expected"`
	ColumnMismatches  []mismatch    `json:"column_mismatches"`
	InvalidPatterns   []string      `json:"invalid_patterns"`
}

// matchOne reports whether gotMsg satisfies one ERROR/ERRORx annotation.
// ERROR is a substring test; ERRORx is a regular expression, as documented in
// the harness. An unquotable or uncompilable pattern is a hard failure, never a
// silently skipped obligation.
func matchOne(want comment, gotMsg string) (ok bool, invalid string) {
	pattern, substr := strings.CutPrefix(want.text, " ERROR ")
	if !substr {
		var found bool
		pattern, found = strings.CutPrefix(want.text, " ERRORx ")
		if !found {
			return false, fmt.Sprintf("annotation is neither ERROR nor ERRORx: %q", want.text)
		}
	}
	unquoted, err := strconv.Unquote(strings.TrimSpace(pattern))
	if err != nil {
		return false, fmt.Sprintf("invalid ERROR pattern (cannot unquote %s)", pattern)
	}
	if substr {
		return strings.Contains(gotMsg, unquoted), ""
	}
	rx, err := regexp.Compile(unquoted)
	if err != nil {
		return false, fmt.Sprintf("invalid ERRORx pattern %s: %v", pattern, err)
	}
	return rx.MatchString(gotMsg), ""
}

// match implements the upstream comparison loop: every observed diagnostic must
// consume exactly one annotation on its own line, the closest remaining column
// must be within colDelta, and no annotation may be left unreported.
func match(errmap map[string]map[int][]comment, got []diagnostic, colDelta int) matchResult {
	res := matchResult{Observed: len(got)}
	for _, filemap := range errmap {
		for _, list := range filemap {
			res.Expected += len(list)
		}
	}

	var indices []int
	for _, d := range got {
		filemap := errmap[d.File]
		var errList []comment
		if filemap != nil {
			errList = filemap[d.Line]
		}

		indices = indices[:0]
		for i, want := range errList {
			ok, invalid := matchOne(want, d.Msg)
			if invalid != "" {
				res.InvalidPatterns = append(res.InvalidPatterns, fmt.Sprintf("%s:%d:%d: %s", d.File, d.Line, want.col, invalid))
				continue
			}
			if ok {
				indices = append(indices, i)
			}
		}
		if len(indices) == 0 {
			res.UnmatchedObserved = append(res.UnmatchedObserved, d)
			continue
		}

		// Multiple candidates: take the closest column, as upstream does.
		index, delta := -1, 0
		for _, i := range indices {
			if dd := absDiff(d.Col, errList[i].col); index < 0 || dd < delta {
				index, delta = i, dd
			}
		}
		if delta > colDelta {
			res.ColumnMismatches = append(res.ColumnMismatches, mismatch{Diagnostic: d, GotCol: d.Col, WantCol: errList[index].col, Tolerance: colDelta})
		}
		res.Matched++

		if n := len(errList) - 1; n > 0 {
			copy(errList[index:], errList[index+1:])
			filemap[d.Line] = errList[:n]
		} else {
			delete(filemap, d.Line)
		}
		if len(filemap) == 0 {
			delete(errmap, d.File)
		}
	}

	for file, filemap := range errmap {
		for line, errList := range filemap {
			for _, want := range errList {
				res.UnmatchedExpected = append(res.UnmatchedExpected, expectation{File: file, Line: line, Col: want.col, Text: want.text})
			}
		}
	}
	return res
}

func (r matchResult) complete() bool {
	return len(r.UnmatchedObserved) == 0 && len(r.UnmatchedExpected) == 0 &&
		len(r.ColumnMismatches) == 0 && len(r.InvalidPatterns) == 0
}
