// run

// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// 1:1 bash++ adaptation of ../go/test/defer.go

package main

import "fmt"

var result string

func addInt(i int) { result += fmt.Sprint(i) }

func test1helper() {
	for i := 0; i < 10; i++ {
		defer addInt(i)
	}
}

func test1() {
	result = ""
	test1helper()
	if result != "9876543210" {
		fmt.Printf("test1: bad defer result (should be 9876543210): %q\n", result)
		panic("defer")
	}
}

func main() {
	test1()
}
