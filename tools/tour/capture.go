// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// The shared capture primitive, ported from tools/corpus/executor.rb
// (`Corpus.capture`, W2 / Story-ID e29305614139) and its durable launch
// receipt tools/corpus/process_lineage.rb (`ProcessLineage.run`, Sprint 148):
// argv with no shell, an explicit environment and nothing inherited,
// /dev/null stdin, file-backed raw streams, a monotonic deadline, its own
// process group, a swept group, a surviving-descendant check, and an
// append-only lineage record per launch.
//
// This file IS the capture implementation the tour ledger binds
// (`capture_implementation` / `capture_library_sha256`): every subprocess the
// tour executor runs goes through Capture, and the offline gate rejects a
// ledger that claims any other path.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	lineageSchema    = "corpus-process-lineage/v3"
	lineageClock     = "CLOCK_MONOTONIC"
	reapGraceSeconds = 1.0
)

// captureImplementation names this file and entry point; the gate binds the
// digest of the file itself alongside it.
const captureImplementation = "tools/tour/capture.go:Capture"

type ContractError struct{ msg string }

func (e *ContractError) Error() string { return e.msg }

func contractError(format string, args ...any) error {
	return &ContractError{msg: fmt.Sprintf(format, args...)}
}

var monotonicBase = time.Now()

func monotonicNS() int64 {
	return int64(time.Since(monotonicBase)) + 1 // never zero, strictly increasing
}

func wallTime() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z07:00")
}

func newLaunchID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

func groupAlive(pgid int) bool {
	if pgid <= 0 {
		return false
	}
	err := syscall.Kill(-pgid, 0)
	if err == nil {
		return true
	}
	if errors.Is(err, syscall.ESRCH) {
		return false
	}
	return true // EPERM: something in the group is still there
}

func signalGroup(pgid int, events *[]any, reason string) bool {
	var errName any
	delivered := true
	err := syscall.Kill(-pgid, syscall.SIGKILL)
	if err != nil {
		delivered = false
		if !errors.Is(err, syscall.ESRCH) {
			errName = "Errno::EPERM"
		}
	}
	*events = append(*events, map[string]any{
		"signal": "KILL", "target_pgid": int64(pgid), "reason": reason,
		"delivered": delivered, "error": errName,
		"monotonic_ns": monotonicNS(), "wall": wallTime(),
	})
	return delivered
}

func waitGroupEmpty(pgid int, seconds float64) bool {
	stop := monotonicNS() + int64(seconds*1e9)
	for {
		if !groupAlive(pgid) {
			return true
		}
		if monotonicNS() >= stop {
			return false
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func fileRecord(path string) (map[string]any, error) {
	abs, _ := filepath.Abs(path)
	st, err := os.Lstat(abs)
	if err != nil || !st.Mode().IsRegular() {
		return nil, contractError("not a regular file: %s", path)
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		return nil, contractError("not a regular file: %s", path)
	}
	return map[string]any{"path": abs, "sha256": sha256hex(data), "bytes": int64(len(data))}, nil
}

func lineageArtifact(path string, producer string) (map[string]any, error) {
	record, err := fileRecord(path)
	if err != nil {
		return nil, contractError("lineage artifact is not a regular file: %s", path)
	}
	record["producer_launch_id"] = producer
	record["parent_artifact"] = nil
	return record, nil
}

func environmentRecord(env map[string]string) map[string]any {
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	sorted := map[string]any{}
	for _, key := range keys {
		sorted[key] = env[key]
	}
	return map[string]any{"allowlisted_keys": anyList(keys), "sha256": sha256hex([]byte(canonical(sorted)))}
}

func envSlice(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := make([]string, 0, len(keys))
	for _, key := range keys {
		out = append(out, key+"="+env[key])
	}
	return out
}

// CaptureResult is the record Corpus.capture returned: the process facts plus
// file-backed stream records.
type CaptureResult map[string]any

// Capture runs argv with no shell in its own process group, bounded by
// `timeout` seconds on the monotonic clock, with stdout/stderr written to
// `<logPrefix>.stdout` / `.stderr`, and appends the authenticated launch
// receipt to `<logPrefix>.lineage.jsonl`.
func Capture(argv []string, cwd string, logPrefix string, env map[string]string, timeout float64) (CaptureResult, error) {
	if len(argv) == 0 {
		return nil, contractError("lineage argv must be a nonempty string array")
	}
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		return nil, contractError("lineage cwd must be a directory")
	}
	if !(timeout > 0) {
		return nil, contractError("lineage deadline must be finite and positive")
	}
	if logPrefix == "" {
		return nil, contractError("lineage paths must be strings")
	}
	absPrefix, _ := filepath.Abs(logPrefix)
	lineagePath := absPrefix + ".lineage.jsonl"
	rootID := "standalone:" + sha256hex([]byte(absPrefix))[:16]
	stageID := filepath.Base(absPrefix)
	if err := os.MkdirAll(filepath.Dir(absPrefix), 0o755); err != nil {
		return nil, err
	}
	stdoutPath := absPrefix + ".stdout"
	stderrPath := absPrefix + ".stderr"
	launchID := newLaunchID()
	parentPID := os.Getpid()
	startedNS := monotonicNS()
	startedWall := wallTime()
	timeoutNS := int64(timeout * 1e9)
	expiresNS := startedNS + timeoutNS

	stdout, err := os.OpenFile(stdoutPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, err
	}
	stderr, err := os.OpenFile(stderrPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		stdout.Close()
		return nil, err
	}
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		stdout.Close()
		stderr.Close()
		return nil, err
	}

	state := "launch_failure"
	var pid any
	var pgid any
	var exitStatus, signal any
	var launchError any
	descendantObserved := false
	killEvents := []any{}
	reapEvents := []any{}
	var leader int

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Path = argv[0]
	cmd.Dir = cwd
	cmd.Env = envSlice(env)
	cmd.Stdin = devnull
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		launchError = map[string]any{"class": "Errno::ENOENT", "message": err.Error(), "errno": nil}
		fmt.Fprintf(stderr, "Errno::ENOENT: %s\n", err.Error())
	} else {
		leader = cmd.Process.Pid
		pid = int64(leader)
		pgid = int64(leader)
		state = "exited"
		done := make(chan struct{})
		go func() {
			cmd.Wait()
			close(done)
		}()
		waited := false
		for !waited {
			select {
			case <-done:
				waited = true
				reapEvents = append(reapEvents, reapEvent(leader, cmd.ProcessState, "leader_wait"))
			default:
				if monotonicNS() >= expiresNS {
					state = "deadline"
					signalGroup(leader, &killEvents, "deadline")
					<-done
					waited = true
					reapEvents = append(reapEvents, reapEvent(leader, cmd.ProcessState, "leader_wait_after_deadline"))
				} else {
					time.Sleep(5 * time.Millisecond)
				}
			}
		}
		ws, _ := cmd.ProcessState.Sys().(syscall.WaitStatus)
		if ws.Exited() {
			exitStatus = int64(ws.ExitStatus())
		} else if ws.Signaled() {
			signal = int64(ws.Signal())
		}
		descendantObserved = groupAlive(leader)
		if descendantObserved {
			if state == "exited" {
				state = "process_leak"
			}
			signalGroup(leader, &killEvents, "descendant_sweep")
		}
		if groupAlive(leader) {
			signalGroup(leader, &killEvents, "ensure_sweep")
		}
	}
	stdout.Close()
	stderr.Close()
	devnull.Close()

	groupEmpty := leader == 0 || waitGroupEmpty(leader, reapGraceSeconds)
	finishedNS := monotonicNS()
	outRecord, err := lineageArtifact(stdoutPath, launchID)
	if err != nil {
		return nil, err
	}
	errRecord, err := lineageArtifact(stderrPath, launchID)
	if err != nil {
		return nil, err
	}
	realCwd, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		realCwd, _ = filepath.Abs(cwd)
	} else {
		realCwd, _ = filepath.Abs(realCwd)
	}
	argvAny := anyList(argv)
	payload := map[string]any{
		"schema": lineageSchema, "root_id": rootID, "stage_id": stageID, "launch_id": launchID,
		"output_mode":      "separate-nonordering",
		"parent_launch_id": nil,
		"launch": map[string]any{
			"argv": argvAny, "cwd": realCwd, "environment": environmentRecord(env),
			"pid": pid, "parent_pid": int64(parentPID), "pgid": pgid,
			"monotonic_started_ns": startedNS, "wall_started": startedWall,
			"launch_failure": launchError,
		},
		"deadline":    map[string]any{"clock": lineageClock, "timeout_ns": timeoutNS, "monotonic_expires_ns": expiresNS},
		"artifacts":   map[string]any{"stdout": outRecord, "stderr": errRecord},
		"kill_events": killEvents, "reap_events": reapEvents,
		"terminal": map[string]any{
			"monotonic_finished_ns": finishedNS, "wall_finished": wallTime(),
			"state": state, "exit": exitStatus, "signal": signal,
			"descendant_observed": descendantObserved, "descendants_survived": !groupEmpty,
		},
	}
	envelope := map[string]any{"payload": payload, "payload_sha256": sha256hex([]byte(canonical(payload)))}
	if err := appendLineage(lineagePath, envelope); err != nil {
		return nil, err
	}
	sortedEnv := map[string]any{}
	for key, value := range env {
		sortedEnv[key] = value
	}
	result := CaptureResult{
		"argv": argvAny, "cwd": cwd, "environment": sortedEnv, "timeout_seconds": timeout,
		"spawned": pid != nil, "state": state, "exit": exitStatus, "signal": signal,
		"descendants_survived": descendantObserved,
		"duration_seconds":     float64(finishedNS-startedNS) / 1e9,
		"lineage": map[string]any{"path": lineagePath, "root_id": rootID, "stage_id": stageID, "launch_id": launchID,
			"parent_launch_id": nil, "payload_sha256": envelope["payload_sha256"]},
		"stdout": map[string]any{"path": outRecord["path"], "sha256": outRecord["sha256"], "bytes": outRecord["bytes"]},
		"stderr": map[string]any{"path": errRecord["path"], "sha256": errRecord["sha256"], "bytes": errRecord["bytes"]},
	}
	return result, nil
}

func reapEvent(pid int, state *os.ProcessState, reason string) map[string]any {
	var exitStatus, signal any
	if state != nil {
		if ws, ok := state.Sys().(syscall.WaitStatus); ok {
			if ws.Exited() {
				exitStatus = int64(ws.ExitStatus())
			} else if ws.Signaled() {
				signal = int64(ws.Signal())
			}
		}
	}
	return map[string]any{"waited_pid": int64(pid), "exit": exitStatus, "signal": signal, "reason": reason,
		"monotonic_ns": monotonicNS(), "wall": wallTime()}
}

func appendLineage(path string, envelope map[string]any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	if _, err := f.WriteString(canonical(envelope) + "\n"); err != nil {
		return err
	}
	return f.Sync()
}

// ------------------------------------------------------------- candidate

func authenticateFile(path string, expected string) (map[string]any, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, contractError("not a regular file: %s", path)
	}
	record, err := fileRecord(real)
	if err != nil {
		return nil, err
	}
	if record["sha256"] != expected {
		return nil, contractError("digest mismatch: %s", path)
	}
	return record, nil
}

func gitOutput(dir string, args ...string) (string, bool) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}

// AuthenticateCandidate verifies the manager-supplied manifest verbatim: the
// launcher digest, the adjacent `.real` payload digest, and that every listed
// repository is at the stated revision with a clean tree including untracked
// files. It returns the manifest merged with the launcher/payload records.
func AuthenticateCandidate(bashy string, candidate map[string]any) (map[string]any, error) {
	for _, key := range []string{"launcher_sha256", "payload_sha256", "frontend_version", "build_recipe", "repositories"} {
		value, present := candidate[key]
		empty := !present || value == nil
		if s, ok := value.(string); ok && s == "" {
			empty = true
		}
		if l, ok := value.([]any); ok && len(l) == 0 {
			empty = true
		}
		if empty {
			return nil, contractError("candidate missing %s", key)
		}
	}
	launcher, err := authenticateFile(bashy, asString(candidate["launcher_sha256"]))
	if err != nil {
		return nil, err
	}
	payload, err := authenticateFile(bashy+".real", asString(candidate["payload_sha256"]))
	if err != nil {
		return nil, err
	}
	for _, item := range asList(candidate["repositories"]) {
		repo := asMap(item)
		path := asString(repo["path"])
		revision, ok := gitOutput(path, "rev-parse", "HEAD")
		if !ok || strings.TrimSpace(revision) != asString(repo["commit"]) {
			return nil, contractError("candidate revision mismatch: %s", path)
		}
		dirt, ok := gitOutput(path, "status", "--porcelain", "--untracked-files=all")
		if !ok || dirt != "" {
			return nil, contractError("candidate repository is dirty: %s", path)
		}
	}
	out := map[string]any{}
	for key, value := range candidate {
		out[key] = value
	}
	out["launcher"] = launcher
	out["payload"] = payload
	return out, nil
}
