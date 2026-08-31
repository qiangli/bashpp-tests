// run

// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// 1:1 bash++ adaptation of ../go/test/switch.go

package main

func assert(cond bool, msg string) {
	if !cond {
		print("assertion fail: ", msg, "\n")
		panic(1)
	}
}

func main() {
	i5 := 5

	switch true {
	case i5 < 5:
		assert(false, "<")
	case i5 == 5:
		assert(true, "!")
	case i5 > 5:
		assert(false, ">")
	}

	switch {
	case i5 < 5:
		assert(false, "<")
	case i5 == 5:
		assert(true, "!")
	case i5 > 5:
		assert(false, ">")
	}

	switch x := 5; true {
	case i5 < x:
		assert(false, "<")
	case i5 == x:
		assert(true, "!")
	case i5 > x:
		assert(false, ">")
	}

	switch i5 {
	case 0, 1, 2, 3, 4:
		assert(false, "4")
	case 5:
		assert(true, "5")
	case 6, 7, 8, 9:
		assert(false, "9")
	default:
		assert(false, "default")
	}
}
