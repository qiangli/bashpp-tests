// run

// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// 1:1 bash++ adaptation of ../go/test/chan/fifo.go

package main

const N = 10

func Asend(c chan int) {
	for i := 0; i < N; i++ {
		c <- i
	}
}

func Arecv(c chan int) {
	for i := 0; i < N; i++ {
		if <-c != i {
			panic("fifo mismatch")
		}
	}
}

func main() {
	c := make(chan int, N)
	Asend(c)
	Arecv(c)
}
