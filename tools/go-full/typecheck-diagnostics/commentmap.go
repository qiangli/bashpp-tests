// Copyright 2022 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
// Port of src/go/types/commentMap_test.go from the pinned official Go SDK.
// The ERROR/ERRORx position is the position of the token immediately preceding
// the comment; automatically inserted semicolons never move that position.
// Reimplementing this in the driver language was rejected: the expected
// positions depend on the real Go scanner, including literal boundaries and
// automatic semicolon insertion.
package main

import (
	"go/scanner"
	"go/token"
	"regexp"
)

type comment struct {
	line, col int    // comment position
	text      string // comment text, excluding "//", "/*", or "*/"
}

// commentMap collects all comments in src whose text matches rx, indexed by the
// line of the preceding token. Same-line comments stay in source order.
func commentMap(src []byte, rx *regexp.Regexp) (res map[int][]comment) {
	fset := token.NewFileSet()
	file := fset.AddFile("", -1, len(src))

	var s scanner.Scanner
	s.Init(file, src, nil, scanner.ScanComments)
	var prev token.Pos // position of last non-comment, non-semicolon token

	for {
		pos, tok, lit := s.Scan()
		switch tok {
		case token.EOF:
			return
		case token.COMMENT:
			if lit[1] == '*' {
				lit = lit[:len(lit)-2] // strip trailing */
			}
			lit = lit[2:] // strip leading // or /*
			if rx.MatchString(lit) {
				p := fset.Position(prev)
				err := comment{p.Line, p.Column, lit}
				if res == nil {
					res = make(map[int][]comment)
				}
				res[p.Line] = append(res[p.Line], err)
			}
		case token.SEMICOLON:
			// ignore automatically inserted semicolon
			if lit == "\n" {
				continue
			}
			fallthrough
		default:
			prev = pos
		}
	}
}

// errorPattern is the exact selector used by the official check_test.go harness.
var errorPattern = regexp.MustCompile("^ ERRORx? ")
