// Sprint: #118; Story: #3; Story-ID: fa07603b71dc
//
// Corpus-owned launcher for one run stage. It exists so this corpus's row
// adapters can be layered ABOVE Corpus.capture instead of reimplementing
// spawning next to it. Corpus.capture takes argv, a cwd, an env, a deadline and
// a stdin path, and it owns the process group, the reap and the teardown. Two
// things this corpus needs are not expressible through that signature, and both
// are obtained here without a second process, a second timer or a second reaper:
//
//	liveness  the FIFO is opened WITHOUT close-on-exec, so the descriptor
//	          survives the exec and is inherited by every descendant. The gate's
//	          read end reaches EOF exactly when the last one is gone -- including
//	          a descendant that called setsid() and is therefore invisible to
//	          Corpus.capture's kill(0, -pgid).
//	pid       signal_injector and loopback_server must reach the program under
//	          test once it has reported readiness. syscall.Exec keeps this pid
//	          and this process group, so the published pid is the program's.
//
// It is a Go program, built by the same pinned SDK as the oracle, because a run
// stage's PATH is deliberately empty: an interpreter that shells out to `uname`
// at startup cannot run there, and giving one a PATH would change what
// examples/environment-variables and the process_exec rows observe.
//
// There is no fork and no wait here: this process BECOMES the program.
package main

import (
	"fmt"
	"os"
	"syscall"
)

func main() {
	argv := os.Args[1:]
	if len(argv) < 4 || argv[2] != "--" {
		fmt.Fprintln(os.Stderr, "usage: gbe-launch LIVENESS_FIFO PIDFILE -- PROGRAM [ARG...]")
		os.Exit(2)
	}
	fifo, pidfile, command := argv[0], argv[1], argv[3:]

	// Non-blocking because the gate opened the read end before spawning; a
	// blocking open would otherwise hang the stage until its deadline. No
	// O_CLOEXEC: the inherited descriptor is the whole point.
	if _, err := syscall.Open(fifo, syscall.O_WRONLY|syscall.O_NONBLOCK, 0); err != nil {
		fmt.Fprintf(os.Stderr, "gbe-launch: cannot hold liveness descriptor %s: %v\n", fifo, err)
		os.Exit(2)
	}

	if err := os.WriteFile(pidfile+".tmp", []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "gbe-launch: cannot publish pid: %v\n", err)
		os.Exit(2)
	}
	if err := os.Rename(pidfile+".tmp", pidfile); err != nil {
		fmt.Fprintf(os.Stderr, "gbe-launch: cannot publish pid: %v\n", err)
		os.Exit(2)
	}

	if err := syscall.Exec(command[0], command, os.Environ()); err != nil {
		// Distinct from any status the corpus programs use, so an unrunnable
		// command is diagnosed rather than mistaken for a program result.
		fmt.Fprintf(os.Stderr, "gbe-launch: cannot execute %s: %v\n", command[0], err)
		os.Exit(127)
	}
}
