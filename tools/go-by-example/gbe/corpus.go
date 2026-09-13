// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// The shared corpus primitives this gate used to `require_relative` from
// tools/corpus/executor.rb (Corpus.capture, success?, snapshot, file_record,
// digest, authenticate_file, authenticate_candidate, native_binary?,
// valid_source_map?) and the append-only launch ledger of
// tools/corpus/process_lineage.rb, absorbed here so that tools/go-by-example/
// executes nothing but Go and Bash. executor.rb itself is untouched: other
// subsystems still require it, and the Ruby text remains the specification
// these functions were ported from.
//
// No shell, no inherited secrets, file-backed streams, bounded process-group
// lifetime. A surviving descendant is a failure even when its parent exited
// successfully.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ContractError is Corpus::ContractError: a violated primitive contract, which
// the gate records against the attempt rather than treating as a crash.
type ContractError struct{ msg string }

func (e *ContractError) Error() string { return e.msg }
func contractErr(format string, args ...any) error {
	return &ContractError{msg: fmt.Sprintf(format, args...)}
}

const lineageSchema = "corpus-process-lineage/v3"
const lineageClock = "CLOCK_MONOTONIC"
const reapGrace = 1.0

// --- clocks ------------------------------------------------------------------

var monotonicBase = time.Now()

// monotonicNS is a CLOCK_MONOTONIC-style reading: arbitrary origin, never
// steps, nanosecond units. Only differences and deadline arithmetic matter.
func monotonicNS() int64 { return int64(time.Since(monotonicBase)) + 1_000_000_000 }

func monotonicSeconds() float64 { return float64(monotonicNS()) / 1e9 }

func wallTime() string { return time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z07:00") }

func uuid4() string {
	var b [16]byte
	if _, err := io.ReadFull(rand.Reader, b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// --- files -------------------------------------------------------------------

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// sha256File is Digest::SHA256.file: follows symlinks, reads the whole file.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// expandPath is File.expand_path relative to the working directory.
func expandPath(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return abs
}

// realPath is File.realpath: every symlink resolved, error if absent.
func realPath(path string) (string, error) {
	abs := expandPath(path)
	return filepath.EvalSymlinks(abs)
}

func isRegularFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

func isSymlink(path string) bool {
	st, err := os.Lstat(path)
	return err == nil && st.Mode()&os.ModeSymlink != 0
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

// isExecutable is File.executable?: an access(X_OK) probe for this process.
func isExecutable(path string) bool {
	return syscall.Access(path, 1) == nil
}

func fileSize(path string) int64 {
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return st.Size()
}

// digest is Corpus.digest: SHA-256 of a regular, non-symlink file.
func digest(path string) (string, error) {
	if !isRegularFile(path) || isSymlink(path) {
		return "", contractErr("not a regular file: %s", path)
	}
	return sha256File(path)
}

// fileRecord is Corpus.file_record: {"path","sha256","bytes"}.
func fileRecord(path string) (*Object, error) {
	sum, err := digest(path)
	if err != nil {
		return nil, err
	}
	return Obj("path", expandPath(path), "sha256", sum, "bytes", Int(fileSize(path))), nil
}

func mustFileRecord(path string) *Object {
	r, err := fileRecord(path)
	if err != nil {
		panic(err)
	}
	return r
}

// nativeBinary is Corpus.native_binary?: an executable regular file whose
// header is ELF, Mach-O or PE.
func nativeBinary(path string) bool {
	if !isRegularFile(path) || isSymlink(path) || !isExecutable(path) {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	header := make([]byte, 64)
	n, _ := io.ReadFull(f, header)
	header = header[:n]
	if len(header) >= 52 && strings.HasPrefix(string(header), "\x7fELF") && (header[4] == 1 || header[4] == 2) {
		return true
	}
	if len(header) == 64 {
		magic := hex.EncodeToString(header[:4])
		switch magic {
		case "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca":
			return true
		}
		if strings.HasPrefix(string(header), "MZ") {
			offset := int64(uint32(header[60]) | uint32(header[61])<<8 | uint32(header[62])<<16 | uint32(header[63])<<24)
			sig := make([]byte, 4)
			if _, err := f.ReadAt(sig, offset); err == nil && string(sig) == "PE\x00\x00" {
				return true
			}
		}
	}
	return false
}

// --- source maps ---------------------------------------------------------------

// rubyStrip is String#strip: leading whitespace and trailing whitespace/NULs.
func rubyStrip(s string) string {
	s = strings.TrimLeft(s, "\t\n\v\f\r ")
	return strings.TrimRight(s, "\t\n\v\f\r \x00")
}

var lowerMarker = regexp.MustCompile(`\A// lower:\d+\z`)

func intField(o *Object, key string) (int64, bool) {
	if o == nil {
		return 0, false
	}
	return o.Int(key)
}

// validSourceMap is Corpus.valid_source_map?: the transpile map must bind the
// exact generated bytes and the exact original inputs, and every emitted
// `// lower:` marker position must be mapped.
func validSourceMap(mapping *Object, generatedRecord *Object, sourceRecords *Object) (ok bool) {
	defer func() {
		if r := recover(); r != nil {
			ok = false
		}
	}()
	if mapping == nil || mapping.Str("schema_version") != "bashy-transpile-map-v1" {
		return false
	}
	origin, isStr := mapping.Get("origin").(string)
	if !isStr || origin == "" {
		return false
	}
	if generatedRecord == nil || sourceRecords == nil || sourceRecords.Len() == 0 {
		return false
	}
	actualGenerated, err := fileRecord(generatedRecord.Str("path"))
	if err != nil {
		return false
	}
	for _, key := range []string{"sha256", "bytes"} {
		if !deepEqual(generatedRecord.Get(key), actualGenerated.Get(key)) {
			return false
		}
	}
	if mapping.Str("go_digest") != "sha256:"+actualGenerated.Str("sha256") {
		return false
	}
	mappings, isArr := mapping.Get("mappings").([]any)
	if !isArr {
		return false
	}
	if mapping.Str("source_kind") != "go" || mapping.Str("front_end") != "gosource-v1" {
		return false
	}
	sources, isArr := mapping.Get("sources").([]any)
	if !isArr {
		return false
	}
	generatedBytes, err := os.ReadFile(generatedRecord.Str("path"))
	if err != nil {
		return false
	}
	generatedLines := strings.Split(string(generatedBytes), "\n")

	// 2. unique exact source-name set
	var mappedNames []string
	for _, src := range sources {
		o, isObj := src.(*Object)
		if !isObj {
			return false
		}
		name, isStr := o.Get("name").(string)
		if !isStr {
			return false
		}
		mappedNames = append(mappedNames, name)
	}
	recordKeys := sourceRecords.Keys()
	sort.Strings(recordKeys)
	if strings.Join(mappedNames, "\x00") != strings.Join(recordKeys, "\x00") || len(mappedNames) != len(recordKeys) {
		return false
	}

	content := map[string][]byte{}
	bases := map[string]int64{}
	var currentBase int64
	for _, src := range sources {
		o := src.(*Object)
		name := o.Str("name")
		rec := sourceRecords.Obj(name)
		if rec == nil {
			return false
		}
		actualSource, err := fileRecord(rec.Str("path"))
		if err != nil {
			return false
		}
		for _, key := range []string{"sha256", "bytes"} {
			if !deepEqual(rec.Get(key), actualSource.Get(key)) {
				return false
			}
		}
		if o.Str("sha256") != actualSource.Str("sha256") {
			return false
		}
		if !deepEqual(o.Get("size"), actualSource.Get("bytes")) {
			return false
		}
		// 3. Base must equal ordered file concatenation actual go source contract
		base, okBase := intField(o, "base")
		size, okSize := intField(o, "size")
		if !okBase || !okSize || base != currentBase {
			return false
		}
		data, err := os.ReadFile(rec.Str("path"))
		if err != nil {
			return false
		}
		content[name] = data
		bases[name] = base
		currentBase += size + 1
	}

	// Match the lowerer's next-nonempty-line marker contract. Checking every
	// emitted position prevents a nonempty but truncated map from certifying.
	type pos struct{ line, col int64 }
	var expected []pos
	pending := false
	for index, line := range generatedLines {
		stripped := rubyStrip(line)
		if strings.HasPrefix(stripped, "// lower:") {
			if !lowerMarker.MatchString(stripped) {
				return false
			}
			pending = true
		} else if pending && stripped != "" {
			indent := len(line) - len(strings.TrimLeft(line, "\t "))
			expected = append(expected, pos{int64(index + 1), int64(indent + 1)})
			pending = false
		}
	}
	if pending {
		return false
	}
	if len(mappings) != len(expected) {
		return false
	}
	for i, entry := range mappings {
		o, isObj := entry.(*Object)
		if !isObj {
			return false
		}
		goLine, ok1 := intField(o, "go_line")
		goCol, ok2 := intField(o, "go_col")
		if !ok1 || !ok2 || goLine != expected[i].line || goCol != expected[i].col {
			return false
		}
	}
	for _, entry := range mappings {
		o := entry.(*Object)
		for _, key := range []string{"go_line", "go_col", "source_line", "source_col"} {
			v, ok := intField(o, key)
			if !ok || v <= 0 {
				return false
			}
		}
		sourceOffset, ok := intField(o, "source_offset")
		if !ok || sourceOffset < 0 {
			return false
		}
		node, isStr := o.Get("node").(string)
		if !isStr || node == "" {
			return false
		}
		sourceFile, isStr := o.Get("source_file").(string)
		fileOffset, okOffset := intField(o, "source_file_offset")
		if !isStr || !okOffset {
			return false
		}
		if !sourceRecords.Has(sourceFile) {
			return false
		}
		base, known := bases[sourceFile]
		if !known {
			return false
		}
		// 4. source_file_offset + source.base == source_offset
		if fileOffset+base != sourceOffset {
			return false
		}
		data := content[sourceFile]
		if fileOffset < 0 || fileOffset > int64(len(data)) {
			return false
		}
		prefix := data[:fileOffset]
		expectedLine := int64(strings.Count(string(prefix), "\n") + 1)
		lineStart := int64(0)
		if idx := strings.LastIndexByte(string(prefix), '\n'); idx >= 0 {
			lineStart = int64(idx + 1)
		}
		expectedCol := fileOffset - lineStart + 1
		sourceLine, _ := intField(o, "source_line")
		sourceCol, _ := intField(o, "source_col")
		if sourceLine != expectedLine || sourceCol != expectedCol {
			return false
		}
		goLine, _ := intField(o, "go_line")
		goCol, _ := intField(o, "go_col")
		if goLine > int64(len(generatedLines)) {
			return false
		}
		if goCol > int64(len(generatedLines[goLine-1]))+1 {
			return false
		}
	}
	return true
}

// --- snapshots -----------------------------------------------------------------

// snapshot is Corpus.snapshot: every entry under root (dotfiles included),
// keyed by relative path, with symlinks reported by target and never followed.
func snapshot(root string) (map[string]*Object, error) {
	entries := map[string]*Object{}
	var walkErr error
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if path == root {
			if err != nil {
				return err
			}
			return nil
		}
		if err != nil {
			return nil // Find.find skips entries it cannot stat
		}
		relative := strings.TrimPrefix(path, root+"/")
		st, lerr := os.Lstat(path)
		if lerr != nil {
			return nil
		}
		switch {
		case st.Mode()&os.ModeSymlink != 0:
			target, _ := os.Readlink(path)
			entries[relative] = Obj("kind", "symlink", "target", target)
			return nil
		case st.Mode().IsRegular():
			sum, derr := digest(path)
			if derr != nil {
				walkErr = derr
				return derr
			}
			entries[relative] = Obj("kind", "file", "sha256", sum, "bytes", Int(st.Size()))
		case st.IsDir():
			entries[relative] = Obj("kind", "directory")
		default:
			entries[relative] = Obj("kind", "special")
		}
		return nil
	})
	if walkErr != nil {
		return nil, walkErr
	}
	return entries, nil
}

func snapshotEqual(a, b *Object) bool { return deepEqual(a, b) }

// --- capture ---------------------------------------------------------------

func envList(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, k+"="+env[k])
	}
	return out
}

func envObject(env map[string]string) *Object {
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	o := NewObject()
	for _, k := range keys {
		o.Set(k, env[k])
	}
	return o
}

func environmentRecord(env map[string]string) *Object {
	sorted := envObject(env)
	keys := make([]any, 0, sorted.Len())
	for _, k := range sorted.Keys() {
		keys = append(keys, k)
	}
	return Obj("allowlisted_keys", keys, "sha256", sha256Hex([]byte(Canonical(sorted))))
}

func groupAlive(pgid int) bool {
	if pgid <= 0 {
		return false
	}
	err := syscall.Kill(-pgid, 0)
	if err == nil {
		return true
	}
	return err == syscall.EPERM
}

func signalGroup(sig syscall.Signal, name string, pgid int, events *[]any, reason string) bool {
	var errName any
	delivered := false
	err := syscall.Kill(-pgid, sig)
	switch {
	case err == nil:
		delivered = true
	case err == syscall.ESRCH:
	case err == syscall.EPERM:
		errName = "Errno::EPERM"
	}
	*events = append(*events, Obj("signal", name, "target_pgid", Int(int64(pgid)), "reason", reason,
		"delivered", delivered, "error", errName, "monotonic_ns", Int(monotonicNS()), "wall", wallTime()))
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

func errnoClass(err error) (string, any) {
	var errno syscall.Errno
	if pe, ok := err.(*os.PathError); ok {
		if e, ok := pe.Err.(syscall.Errno); ok {
			errno = e
		}
	} else if e, ok := err.(syscall.Errno); ok {
		errno = e
	}
	if errno == 0 {
		return "SystemCallError", nil
	}
	names := map[syscall.Errno]string{
		syscall.ENOENT: "Errno::ENOENT", syscall.EACCES: "Errno::EACCES", syscall.ENOEXEC: "Errno::ENOEXEC",
		syscall.ENOTDIR: "Errno::ENOTDIR", syscall.EPERM: "Errno::EPERM", syscall.E2BIG: "Errno::E2BIG",
		syscall.EISDIR: "Errno::EISDIR", syscall.ELOOP: "Errno::ELOOP", syscall.ENAMETOOLONG: "Errno::ENAMETOOLONG",
	}
	name, ok := names[errno]
	if !ok {
		name = "SystemCallError"
	}
	return name, Int(int64(errno))
}

func lineageArtifact(path string, producer string) (*Object, error) {
	expanded := expandPath(path)
	if !isRegularFile(expanded) || isSymlink(expanded) {
		return nil, contractErr("lineage artifact is not a regular file: %s", expanded)
	}
	sum, err := sha256File(expanded)
	if err != nil {
		return nil, err
	}
	return Obj("path", expanded, "bytes", Int(fileSize(expanded)), "sha256", sum,
		"producer_launch_id", producer, "parent_artifact", nil), nil
}

func appendLineage(path string, envelope *Object) error {
	f, err := os.OpenFile(expandPath(path), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	if _, err := f.WriteString(Canonical(envelope) + "\n"); err != nil {
		return err
	}
	return f.Sync()
}

// capture is Corpus.capture: spawn argv in its own process group with exactly
// the given environment, file-backed stdout/stderr, a monotonic deadline and a
// KILL sweep of the group, then record the launch in the lineage ledger. The
// returned record is the one the gate embeds in evidence, field for field.
func capture(argv []string, cwd string, logPrefix string, env map[string]string, timeout Number, stdin string) (*Object, error) {
	if len(argv) == 0 {
		return nil, contractErr("lineage argv must be a nonempty string array")
	}
	if !isDir(cwd) {
		return nil, contractErr("lineage cwd must be a directory")
	}
	timeoutSeconds := timeout.AsFloat()
	if !(timeoutSeconds > 0) || timeoutSeconds > 1e15 {
		return nil, contractErr("lineage deadline must be finite and positive")
	}
	if logPrefix == "" {
		return nil, contractErr("lineage paths must be strings")
	}
	lineagePath := logPrefix + ".lineage.jsonl"
	rootID := "standalone:" + sha256Hex([]byte(expandPath(logPrefix)))[:16]
	stageID := filepath.Base(logPrefix)
	if err := os.MkdirAll(filepath.Dir(expandPath(lineagePath)), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(expandPath(logPrefix)), 0o755); err != nil {
		return nil, err
	}
	stdoutPath := expandPath(logPrefix + ".stdout")
	stderrPath := expandPath(logPrefix + ".stderr")
	launchID := uuid4()
	parentPid := os.Getpid()
	startedNS := monotonicNS()
	startedWall := wallTime()
	var timeoutNS int64
	if timeout.Float {
		timeoutNS = int64(timeout.F * 1e9)
	} else {
		timeoutNS = timeout.Int * 1_000_000_000
	}
	expiresNS := startedNS + timeoutNS
	pid := 0
	state := "launch_failure"
	var exitCode, signalNo any
	var launchError any
	descendantObserved := false
	killEvents := []any{}
	reapEvents := []any{}

	stdoutFile, err := os.OpenFile(stdoutPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return nil, err
	}
	stderrFile, err := os.OpenFile(stderrPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		stdoutFile.Close()
		return nil, err
	}
	stdinFile, err := os.Open(stdin)
	if err != nil {
		stdoutFile.Close()
		stderrFile.Close()
		return nil, err
	}

	reapEvent := func(waited int, reason string) {
		reapEvents = append(reapEvents, Obj("waited_pid", Int(int64(waited)), "exit", exitCode, "signal", signalNo,
			"reason", reason, "monotonic_ns", Int(monotonicNS()), "wall", wallTime()))
	}
	cmd := exec.Command(argv[0])
	cmd.Path = argv[0]
	cmd.Args = argv
	cmd.Dir = cwd
	cmd.Env = envList(env)
	cmd.Stdin = stdinFile
	cmd.Stdout = stdoutFile
	cmd.Stderr = stderrFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		class, errno := errnoClass(err)
		message := err.Error()
		launchError = Obj("class", class, "message", message, "errno", errno)
		fmt.Fprintf(stderrFile, "%s: %s\n", class, message)
	} else {
		pid = cmd.Process.Pid
		state = "exited"
		done := make(chan struct{})
		go func() {
			cmd.Wait()
			close(done)
		}()
		record := func() {
			if ps := cmd.ProcessState; ps != nil {
				if ws, ok := ps.Sys().(syscall.WaitStatus); ok {
					if ws.Signaled() {
						signalNo = Int(int64(ws.Signal()))
					} else {
						exitCode = Int(int64(ws.ExitStatus()))
					}
				}
			}
		}
		for {
			exited := false
			select {
			case <-done:
				exited = true
			default:
			}
			if exited {
				record()
				reapEvent(pid, "leader_wait")
				break
			}
			if monotonicNS() >= expiresNS {
				state = "deadline"
				signalGroup(syscall.SIGKILL, "KILL", pid, &killEvents, "deadline")
				<-done
				record()
				reapEvent(pid, "leader_wait_after_deadline")
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		descendantObserved = groupAlive(pid)
		if descendantObserved {
			if state == "exited" {
				state = "process_leak"
			}
			signalGroup(syscall.SIGKILL, "KILL", pid, &killEvents, "descendant_sweep")
		}
		if groupAlive(pid) {
			signalGroup(syscall.SIGKILL, "KILL", pid, &killEvents, "ensure_sweep")
		}
	}
	stdinFile.Close()
	stdoutFile.Close()
	stderrFile.Close()

	groupEmpty := pid == 0 || waitGroupEmpty(pid, reapGrace)
	finishedNS := monotonicNS()
	stdoutArtifact, err := lineageArtifact(stdoutPath, launchID)
	if err != nil {
		return nil, err
	}
	stderrArtifact, err := lineageArtifact(stderrPath, launchID)
	if err != nil {
		return nil, err
	}
	artifacts := Obj("stdout", stdoutArtifact, "stderr", stderrArtifact)
	cwdReal, err := realPath(cwd)
	if err != nil {
		cwdReal = expandPath(cwd)
	}
	var pidValue, pgidValue any
	if pid != 0 {
		pidValue = Int(int64(pid))
		pgidValue = Int(int64(pid))
	}
	argvValues := make([]any, len(argv))
	for i, a := range argv {
		argvValues[i] = a
	}
	payload := Obj(
		"schema", lineageSchema, "root_id", rootID, "stage_id", stageID, "launch_id", launchID,
		"output_mode", "separate-nonordering",
		"parent_launch_id", nil,
		"launch", Obj("argv", argvValues, "cwd", cwdReal, "environment", environmentRecord(env),
			"pid", pidValue, "parent_pid", Int(int64(parentPid)), "pgid", pgidValue,
			"monotonic_started_ns", Int(startedNS), "wall_started", startedWall,
			"launch_failure", launchError),
		"deadline", Obj("clock", lineageClock, "timeout_ns", Int(timeoutNS), "monotonic_expires_ns", Int(expiresNS)),
		"artifacts", artifacts, "kill_events", killEvents, "reap_events", reapEvents,
		"terminal", Obj("monotonic_finished_ns", Int(finishedNS), "wall_finished", wallTime(),
			"state", state, "exit", exitCode, "signal", signalNo,
			"descendant_observed", descendantObserved, "descendants_survived", !groupEmpty),
	)
	payloadSHA := sha256Hex([]byte(Canonical(payload)))
	if err := appendLineage(lineagePath, Obj("payload", payload, "payload_sha256", payloadSHA)); err != nil {
		return nil, err
	}
	result := Obj(
		"argv", argvValues, "cwd", cwd,
		"environment", envObject(env), "timeout_seconds", timeout,
		"spawned", pid != 0, "state", state,
		"exit", exitCode, "signal", signalNo,
		"descendants_survived", descendantObserved,
		"duration_seconds", Flt(float64(finishedNS-startedNS)/1_000_000_000.0),
		"lineage", Obj("path", expandPath(lineagePath), "root_id", rootID, "stage_id", stageID,
			"launch_id", launchID, "parent_launch_id", nil, "payload_sha256", payloadSHA),
		"stdout", Obj("path", stdoutArtifact.Get("path"), "sha256", stdoutArtifact.Get("sha256"), "bytes", stdoutArtifact.Get("bytes")),
		"stderr", Obj("path", stderrArtifact.Get("path"), "sha256", stderrArtifact.Get("sha256"), "bytes", stderrArtifact.Get("bytes")),
	)
	return result, nil
}

// success is Corpus.success?: spawned, exited normally with status 0.
func success(stage *Object) bool {
	if stage == nil || !stage.Bool("spawned") || stage.Str("state") != "exited" {
		return false
	}
	exit, ok := stage.Int("exit")
	return ok && exit == 0 && stage.Get("signal") == nil
}

// authenticateFile is Corpus.authenticate_file.
func authenticateFile(path, expected string) (*Object, error) {
	real, err := realPath(path)
	if err != nil {
		return nil, contractErr("not a regular file: %s", path)
	}
	record, err := fileRecord(real)
	if err != nil {
		return nil, err
	}
	if record.Str("sha256") != expected {
		return nil, contractErr("digest mismatch: %s", path)
	}
	return record, nil
}

func gitOutput(dir string, args ...string) (string, bool) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	return string(out), err == nil
}

// authenticateCandidate is Corpus.authenticate_candidate: launcher and payload
// by digest, every declared repository at its clean exact revision, untracked
// files included.
func authenticateCandidate(bashy string, candidate *Object) (*Object, error) {
	for _, key := range []string{"launcher_sha256", "payload_sha256", "frontend_version", "build_recipe", "repositories"} {
		v := candidate.Get(key)
		empty := v == nil
		switch x := v.(type) {
		case string:
			empty = x == ""
		case []any:
			empty = len(x) == 0
		case *Object:
			empty = x.Len() == 0
		}
		if empty {
			return nil, contractErr("candidate missing %s", key)
		}
	}
	launcher, err := authenticateFile(bashy, candidate.Str("launcher_sha256"))
	if err != nil {
		return nil, err
	}
	payload, err := authenticateFile(bashy+".real", candidate.Str("payload_sha256"))
	if err != nil {
		return nil, err
	}
	repos, _ := candidate.Get("repositories").([]any)
	for _, r := range repos {
		repo, _ := r.(*Object)
		if repo == nil || !repo.Has("path") || !repo.Has("commit") {
			return nil, contractErr("candidate repository entry is malformed")
		}
		path := repo.Str("path")
		revision, ok := gitOutput(path, "rev-parse", "HEAD")
		if !ok || strings.TrimSpace(revision) != repo.Str("commit") {
			return nil, contractErr("candidate revision mismatch: %s", path)
		}
		dirt, ok := gitOutput(path, "status", "--porcelain", "--untracked-files=all")
		if !ok || dirt != "" {
			return nil, contractErr("candidate repository is dirty: %s", path)
		}
	}
	out := deepCopy(candidate).(*Object)
	out.Set("launcher", launcher)
	out.Set("payload", payload)
	return out, nil
}

// statIdentity returns (device, inode) of a path (File.stat dev/ino).
func statIdentity(path string) (int64, int64, error) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, 0, err
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, fmt.Errorf("no stat identity for %s", path)
	}
	return int64(sys.Dev), int64(sys.Ino), nil
}

// readTSV reads a TSV table: blank lines and lines starting with # skipped,
// every remaining line split on tabs with trailing empties preserved.
func readTSV(path string) ([][]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, line := range rubyLinesChomp(string(data)) {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		rows = append(rows, strings.Split(line, "\t"))
	}
	return rows, nil
}

// rubyLinesChomp is File.readlines(path, chomp: true): lines without their
// terminators, a final unterminated line included.
func rubyLinesChomp(s string) []string {
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if strings.HasSuffix(s, "\n") {
		lines = lines[:len(lines)-1]
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

// rubyLines is String#lines: each line keeps its "\n"; an unterminated tail
// is its own element; "" has no lines.
func rubyLines(s string) []string {
	var out []string
	for len(s) > 0 {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			out = append(out, s)
			break
		}
		out = append(out, s[:i+1])
		s = s[i+1:]
	}
	return out
}

func itoa(i int) string { return strconv.Itoa(i) }
