// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Real launch/deadline/process-tree probes for the tour-evidence capture
// primitive — the port of tools/tour/evidence-selftests.rb. The Ruby probes
// spawned `ruby -e` children; these spawn `tour probe ...` children of the
// same binary.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// cmdProbe is the child side of the subprocess probes.
func cmdProbe(args []string) int {
	if len(args) == 0 {
		return 2
	}
	switch args[0] {
	case "exit":
		os.Stdout.WriteString("out\r\n")
		os.Stderr.WriteString("err\n")
		return 7
	case "signal":
		syscall.Kill(os.Getpid(), syscall.SIGTERM)
		time.Sleep(5 * time.Second)
		return 0
	case "sleep":
		time.Sleep(20 * time.Second)
		return 0
	case "tree":
		exe, _ := os.Executable()
		child := exec.Command(exe, "probe", "sleep")
		if err := child.Start(); err != nil {
			return 1
		}
		os.WriteFile(args[1], []byte(strconv.Itoa(child.Process.Pid)), 0o644)
		time.Sleep(20 * time.Second)
		return 0
	}
	return 2
}

func cmdEvidenceSelftests(root string) int {
	passed := 0
	check := func(name string, condition bool) bool {
		if !condition {
			fmt.Fprintf(os.Stderr, "FAIL %s\n", name)
			return false
		}
		passed++
		fmt.Printf("PASS %s\n", name)
		return true
	}
	dir, err := os.MkdirTemp("", "tour-evidence-selftest")
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	defer os.RemoveAll(dir)
	exe, _ := os.Executable()
	env := map[string]string{}

	missing := evidenceCapture([]string{filepath.Join(dir, "does-not-exist")}, dir, 1, env)
	if !check("actual launch failure is explicit", !missing.Spawned && missing.State == "launch_failure" && missing.Exit == nil) {
		return 1
	}

	captured := evidenceCapture([]string{exe, "probe", "exit"}, dir, 1, env)
	if !check("actual exit and raw streams are retained",
		captured.Spawned && captured.State == "exited" && jsonEqual(captured.Exit, int64(7)) &&
			string(captured.Stdout) == "out\r\n" && string(captured.Stderr) == "err\n") {
		return 1
	}

	signaled := evidenceCapture([]string{exe, "probe", "signal"}, dir, 1, env)
	if !check("actual signal exit is mapped deterministically",
		signaled.Spawned && signaled.State == "exited" && jsonEqual(signaled.Exit, int64(143))) {
		return 1
	}

	deadline := evidenceCapture([]string{exe, "probe", "sleep"}, dir, 1, env)
	if !check("actual deadline is bounded", deadline.Spawned && deadline.State == "deadline" && deadline.Exit == nil) {
		return 1
	}

	pidfile := filepath.Join(dir, "descendant.pid")
	tree := evidenceCapture([]string{exe, "probe", "tree", pidfile}, dir, 1, env)
	pidText, _ := os.ReadFile(pidfile)
	child, _ := strconv.Atoi(strings.TrimSpace(string(pidText)))
	time.Sleep(100 * time.Millisecond)
	alive := child > 0 && !errors.Is(syscall.Kill(child, 0), syscall.ESRCH)
	if !check("deadline kills descendant process group", tree.State == "deadline" && !alive) {
		return 1
	}

	baselineRaw := [][]byte{[]byte("same\n"), []byte{}}
	changedRaw := [][]byte{[]byte("changed\n"), []byte{}}
	baseline := map[string]any{"spawned": true, "state": "exited", "exit": int64(0), "normalized": evidenceDerived(baselineRaw[0], baselineRaw[1])}
	same := map[string]any{"spawned": true, "state": "exited", "exit": int64(0), "normalized": evidenceDerived(baselineRaw[0], baselineRaw[1])}
	changed := map[string]any{"spawned": true, "state": "exited", "exit": int64(0), "normalized": evidenceDerived(changedRaw[0], changedRaw[1])}
	if !check("comparator accepts independently captured equality", evidenceOutcome(same, baseline) == "PASS") {
		return 1
	}
	if !check("comparator change becomes mismatch", evidenceOutcome(changed, baseline) == "FAIL:mismatch") {
		return 1
	}

	normalized := evidenceNormalize([]byte("pointer=0xDeAdBeef\r\nshort=0x2a\n"))
	decoded, _ := strictB64(toS(normalized["base64"]))
	if !check("normalizer applies only declared canonicalization",
		truthy(normalized["valid_utf8"]) && string(decoded) == "pointer=0xADDR\nshort=0x2a\n") {
		return 1
	}

	invalid := evidenceNormalize([]byte{0xff})
	invalidAttempt := map[string]any{"spawned": true, "state": "exited", "exit": int64(0),
		"normalized": map[string]any{"stdout": invalid, "stderr": evidenceNormalize([]byte{})}}
	if !check("invalid UTF-8 is rejected without replacement",
		jsonEqual(invalid, map[string]any{"valid_utf8": false, "bytes": nil, "sha256": nil, "base64": nil}) &&
			evidenceOutcome(invalidAttempt, nil) == "FAIL:invalid_utf8") {
		return 1
	}

	// Keep the generated artifact directory outside the module: proves that go
	// build is deliberately run from the supplied module root.
	mod := filepath.Join(dir, "compiled-module")
	out := filepath.Join(dir, "compiled-output")
	os.MkdirAll(filepath.Join(mod, "helper"), 0o755)
	os.MkdirAll(out, 0o755)
	os.WriteFile(filepath.Join(mod, "go.mod"), []byte("module example.local/context\n\ngo 1.23\n"), 0o644)
	os.WriteFile(filepath.Join(mod, "helper", "helper.go"), []byte("package helper\nfunc Value() string { return \"module-context\" }\n"), 0o644)
	sourcePath := filepath.Join(mod, "main.go")
	os.WriteFile(sourcePath, []byte("package main\nimport (\"fmt\"; \"example.local/context/helper\")\nfunc main() { fmt.Println(helper.Value()) }\n"), 0o644)
	transpiler := filepath.Join(dir, "copy-transpiler")
	os.WriteFile(transpiler, []byte("#!/bin/sh\nset -eu\n[ \"$1\" = transpile ]\n[ \"$3\" = -o ]\ncp \"$2\" \"$4\"\n"), 0o755)
	goBin := filepath.Join(shellOutput(nil, "go", "env", "GOROOT"), "bin", "go")
	pipeline := evidenceCompiledPipeline(transpiler, goBin, sourcePath, mod, out, 15,
		map[string]string{"GOTOOLCHAIN": "local", "BASHY_HINTS": "off"})
	if !check("compiled pipeline builds from the supplied module context",
		pipeline.Stage == "run" && jsonEqual(pipeline.Raw.Exit, int64(0)) && string(pipeline.Raw.Stdout) == "module-context\n") {
		fmt.Fprintf(os.Stderr, "  stage=%s exit=%v stderr=%s\n", pipeline.Stage, pipeline.Raw.Exit, pipeline.Raw.Stderr)
		return 1
	}

	fmt.Printf("Tour evidence subprocess self-tests OK: %d/10\n", passed)
	return 0
}
