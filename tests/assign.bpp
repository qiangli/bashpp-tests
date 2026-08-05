// errorcheck

// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// 1:1 bash++ adaptation of ../go/test/assign.go
// Verify assignment errors are caught by the compiler.

package main

import (
	"sync"
	"time"
)

type T struct {
	int
	sync.Mutex
}

func main() {
	{
		var x, y sync.Mutex
		x = y // ok
		_ = x
	}
	{
		var x, y T
		x = y // ok
		_ = x
	}
	{
		x := time.Time{0, 0, nil} // ERROR "assignment.*Time"
		_ = x
	}
	{
		x := sync.Mutex{key: 0} // ERROR "(unknown|assignment).*Mutex"
		_ = x
	}
	{
		x := &sync.Mutex{} // ok
		var y sync.Mutex   // ok
		y = *x             // ok
		*x = y             // ok
		_ = x
		_ = y
	}
}
