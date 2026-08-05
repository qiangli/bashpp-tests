// run

// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// 1:1 bash++ adaptation of ../go/test/chan/select.go

package main

var counter uint
var shift uint

func GetValue() uint {
	counter++
	return 1 << shift
}

func Send(a, b chan uint) int {
	var i int

LOOP:
	for {
		select {
		case a <- GetValue():
			i++
			a = nil
		case b <- GetValue():
			i++
			b = nil
		default:
			break LOOP
		}
		shift++
	}
	return i
}

func main() {
	a := make(chan uint, 1)
	b := make(chan uint, 1)
	if Send(a, b) != 2 {
		panic("send failed")
	}
	if counter != 2 {
		panic("counter failed")
	}
	if <-a != 1 {
		panic("a failed")
	}
	if <-b != 2 {
		panic("b failed")
	}
}
