// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Differential gate for the pinned Go by Example corpus, ported from
// tools/go-by-example/gate.rb.
//
// Three observations of the SAME unchanged upstream bytes per program row:
//
//	oracle       pinned Go 1.27 `go build` (or `go test -c`) -> run the native
//	             binary directly.  Never `go run`: its wrapper reports a child
//	             `os.Exit(3)` as its own exit 1 plus an "exit status 3" line on
//	             stderr, which conflates deliberate statuses with panics.
//	interpreted  bashy --bashpp --source=go <original .go> [argv...], or
//	             bashy --bashpp --source=go --go-file A --go-file B for an
//	             explicit multi-file package.
//	compiled     bashy transpile --bashpp --source=go <inputs> -o gen.go
//	             --map gen.go.map, then pinned `go build` of the generated Go,
//	             then run the resulting native artifact.
//
// `--source=go` EXISTS in the tag-enabled candidate, so this gate drives the
// real front end rather than documenting a missing flag.  Multi-file input uses
// the product's own `--go-file` contract, repeated once per file; a second
// source file is never passed as a program argument, because the CLI would hand
// it to the program as argv.  The removed `--bashpp --compile -o` spelling never
// existed in any shipped CLI.
//
// Spawning, deadlines, process-group teardown and surviving-descendant checks
// are NOT reimplemented here.  They are the corpus primitives absorbed into
// corpus.go (capture, success, snapshot, fileRecord, and the candidate/SDK
// provenance primitives).  This file owns only what is specific to this
// corpus: per-row behaviour adapters, the recipes, and the narrow declared
// comparators layered above those primitives.
//
// Every stage is recorded separately, so a transpile that succeeded can never
// be read as an artifact that ran.  Each mode gets its own freshly constructed
// execution root and its own copy of the source tree at the ORIGINAL relative
// asset paths (embed-directive resolves `folder/single_file.txt` relative to
// the source file, so a basename-flattened copy silently changes the program).
// Roots are snapshotted before and after, and the resulting filesystem effects
// are compared across modes alongside status, stdout and stderr.
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
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

const evidenceSchema = 8
const story = "Sprint118/Story3/fa07603b71dc"

var MODES = []string{"oracle", "interpreted", "compiled"}

// All three modes get the SAME environment block, with no exemption for the
// interpreter. examples/environment-variables prints every key it can see, so
// any extra key given to one mode is a guaranteed disagreement that the
// env_listing comparator cannot honestly absorb.
//
// The W1 contract question this file used to defer is answered by
// measurement: the product's runtime import helper resolves stdlib and module
// imports through GOROOT and GOMODCACHE, and without them `--source=go` refuses
// every program with `could not import fmt ... ($GOROOT not set)`. Both keys are
// therefore part of the COMMON block -- granted to the oracle and to the
// compiled artifact exactly as they are granted to the interpreter -- so they
// are the same observation in examples/environment-variables in all three modes
// and the divergence list stays empty. Granting them to one side only is what
// would have been dishonest.
var declaredEnvDivergence = []string{}

// Every adapter here is a construction this file actually performs. A name that
// describes a control the gate cannot exercise does not belong in the registry.
var ADAPTERS = []string{"none", "argv_fixture", "fixed_env", "hermetic_cwd", "tmpdir", "input_file_fixture", "stdin_fixture", "local_http_origin", "loopback_server", "signal_injector", "exit_status_capture", "bounded_wait", "go_test_runner"}

// Effects are compared after ONLY the row's declared tmp_path normalization,
// which is the sole reviewed transformation that describes a path. Nothing else
// in the registry may rewrite an effect listing.
var effectNormalizations = []string{"tmp_path"}

// The generated Go depends on the lowering runtime, provisioned from the
// mvdan.cc/sh/v3 repository the AUTHENTICATED candidate declares.
const goModOracle = "module gbe.oracle\n\ngo 1.27\n"

var (
	rowLimit       float64
	transpileLimit float64
	buildLimit     float64
	runLimit       float64
	cleanupLimit   float64
)

func envFloat(name string, fallback string) float64 {
	v := os.Getenv(name)
	if v == "" {
		v = fallback
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil {
		fatal("invalid value for Float(): " + rubyInspect(v))
	}
	return f
}

func toks(value string) []string {
	if value == "none" {
		return []string{}
	}
	return strings.Split(value, ",")
}

func left(deadline float64) float64 { return deadline - monotonicSeconds() }

func sha(path string) string {
	sum, err := sha256File(path)
	if err != nil {
		fatal(err.Error())
	}
	return sum
}

// --- process control ------------------------------------------------------

// sig signals the program's process group; a vanished group is not an error.
func sig(signal syscall.Signal, pgid int) {
	err := syscall.Kill(-pgid, signal)
	if err != nil && err != syscall.ESRCH && err != syscall.EPERM {
		return
	}
}

// sentinelHeld reports whether the liveness FIFO still has a writer after the
// budget: EOF means the last descendant is gone; anything else means one is
// still holding the inherited descriptor.
func sentinelHeld(fifo *os.File, budget float64) bool {
	deadline := monotonicSeconds() + budget
	buf := make([]byte, 4096)
	for {
		remaining := deadline - monotonicSeconds()
		if remaining <= 0 {
			return true
		}
		fifo.SetReadDeadline(time.Now().Add(time.Duration(remaining * float64(time.Second))))
		n, err := fifo.Read(buf)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return false
			}
			if errors.Is(err, os.ErrDeadlineExceeded) {
				return true
			}
			var pe *os.PathError
			if errors.As(err, &pe) && (pe.Err == syscall.EAGAIN || pe.Err == syscall.EWOULDBLOCK) {
				time.Sleep(5 * time.Millisecond)
				continue
			}
			return false
		}
		if n == 0 {
			return false
		}
	}
}

// drive: a loopback client for the network_server rows. `stop` is set the
// moment the stage ends. A program that exited before the adapter could drive
// it is not an adapter failure -- its own status and streams are the
// observation, and turning that into `adapter_error` would hide the real
// result behind an incomplete one. A deadline reached while the program is
// still running is a genuine adapter failure and still raises.
func drive(path string, deadline float64, stop *stopFlag) error {
	var socket net.Conn
	for socket == nil {
		if stop.get() {
			return nil
		}
		if !(left(deadline) > 0) {
			return errors.New("RuntimeError: server adapter deadline")
		}
		c, err := net.DialTimeout("tcp", "127.0.0.1:8090", 100*time.Millisecond)
		if err == nil {
			socket = c
		} else {
			wait := 0.02
			if l := left(deadline); l < wait {
				wait = l
			}
			if wait > 0 {
				time.Sleep(time.Duration(wait * float64(time.Second)))
			}
		}
	}
	defer socket.Close()
	socket.SetDeadline(time.Now().Add(time.Duration(left(deadline) * float64(time.Second))))
	if strings.Contains(path, "tcp-server") {
		if _, err := socket.Write([]byte("hello adapter\n")); err != nil {
			return fmt.Errorf("%s: %v", ioErrorClass(err), err)
		}
		line, err := bufio.NewReader(socket).ReadString('\n')
		if err != nil && line == "" {
			return fmt.Errorf("%s: %v", ioErrorClass(err), err)
		}
		if line != "ACK: HELLO ADAPTER\n" {
			return errors.New("RuntimeError: bad TCP response")
		}
		return nil
	}
	if _, err := socket.Write([]byte("GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")); err != nil {
		return fmt.Errorf("%s: %v", ioErrorClass(err), err)
	}
	if strings.Contains(path, "context/") {
		return nil
	}
	body, err := io.ReadAll(socket)
	if err != nil {
		return fmt.Errorf("%s: %v", ioErrorClass(err), err)
	}
	if !strings.Contains(string(body), "hello") {
		return errors.New("RuntimeError: bad HTTP response")
	}
	return nil
}

func ioErrorClass(err error) string {
	if errors.Is(err, syscall.ECONNRESET) {
		return "Errno::ECONNRESET"
	}
	if errors.Is(err, syscall.EPIPE) {
		return "Errno::EPIPE"
	}
	if errors.Is(err, io.EOF) {
		return "EOFError"
	}
	return "IOError"
}

type stopFlag struct {
	ch chan struct{}
}

func newStopFlag() *stopFlag { return &stopFlag{ch: make(chan struct{})} }
func (s *stopFlag) set() {
	select {
	case <-s.ch:
	default:
		close(s.ch)
	}
}
func (s *stopFlag) get() bool {
	select {
	case <-s.ch:
		return true
	default:
		return false
	}
}

// Loopback origin standing in for gobyexample.com so the network_client row is
// hermetic without editing the pinned program's URL.
type origin struct {
	url      string
	ca       string
	deadline float64
	listener net.Listener
	done     chan struct{}
	err      error
	client   net.Conn
}

func newOrigin(deadline float64, dir string) (*origin, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "gobyexample.com"},
		NotBefore:             time.Unix(0, 0).UTC(),
		NotAfter:              time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC),
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              []string{"gobyexample.com"},
		SignatureAlgorithm:    x509.SHA256WithRSA,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	ca := dir + "/hermetic-ca.pem"
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return nil, err
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	o := &origin{ca: ca, deadline: deadline, listener: listener, done: make(chan struct{})}
	o.url = "http://127.0.0.1:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	go func() {
		defer close(o.done)
		client, err := listener.Accept()
		if err != nil {
			o.err = err
			return
		}
		o.client = client
		defer client.Close()
		reader := bufio.NewReader(client)
		line, err := reader.ReadString('\n')
		if !strings.HasPrefix(line, "CONNECT gobyexample.com:443 ") {
			if err != nil && line == "" {
				o.err = err
			} else {
				o.err = errors.New("RuntimeError: expected CONNECT gobyexample.com:443")
			}
			return
		}
		for {
			header, err := reader.ReadString('\n')
			if header == "\r\n" {
				break
			}
			if err != nil {
				o.err = err
				return
			}
		}
		if _, err := client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
			o.err = err
			return
		}
		ssl := tls.Server(&bufferedConn{Conn: client, reader: reader}, &tls.Config{Certificates: []tls.Certificate{cert}})
		if err := ssl.Handshake(); err != nil {
			o.err = fmt.Errorf("OpenSSL::SSL::SSLError: %v", err)
			return
		}
		buf := make([]byte, 4096)
		if _, err := ssl.Read(buf); err != nil {
			o.err = err
			return
		}
		body := "<!doctype html>\n<html>\n<head><title>Go by Example</title></head>\n<body>\n<h1>Go by Example</h1>\n"
		if _, err := ssl.Write([]byte(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body))); err != nil {
			o.err = err
			return
		}
		ssl.Close()
	}()
	return o, nil
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }

func (o *origin) apply(env map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range env {
		out[k] = v
	}
	out["HTTPS_PROXY"] = o.url
	out["https_proxy"] = o.url
	out["SSL_CERT_FILE"] = o.ca
	return out
}

// close joins the origin within the row's remaining budget. A join failure is
// reported as false; an error the client caused (not the listener's own
// closing) is returned so the run records it against the attempt.
func (o *origin) close() (bool, error) {
	o.listener.Close()
	budget := left(o.deadline)
	if cleanupLimit < budget {
		budget = cleanupLimit
	}
	joined := false
	if budget > 0 {
		select {
		case <-o.done:
			joined = true
		case <-time.After(time.Duration(budget * float64(time.Second))):
		}
	}
	if !joined {
		if o.client != nil {
			o.client.Close()
		}
		select {
		case <-o.done:
		case <-time.After(time.Duration(cleanupLimit * float64(time.Second))):
		}
	}
	if o.err != nil && !ignorableOriginError(o.err) {
		return joined, o.err
	}
	return joined, nil
}

func ignorableOriginError(err error) bool {
	return errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, syscall.EBADF)
}

// --- one run/build stage ------------------------------------------------

// runResult is the per-stage record `run` builds before it is folded into a
// stage record: the capture, the mapped state, the raw streams and any
// adapter diagnosis.
type runResult struct {
	exit       any // nil or Number
	state      string
	spawned    bool
	stdout     []byte
	stderr     []byte
	command    []string
	detail     string
	hasDetail  bool
	capture    *Object
	launchArgv []string
	corpusSt   string
	duration   any
}

func (r *runResult) addDetail(msg string) {
	if r.hasDetail {
		r.detail = r.detail + "; " + msg
	} else {
		r.detail = msg
		r.hasDetail = true
	}
}

func (r *runResult) setDetail(msg string) {
	r.detail = msg
	r.hasDetail = true
}

func enforceRun(result *runResult, bindings []*InputBinding, scopes []string) {
	probe := NewObject()
	enforceBindings(probe, bindings, scopes)
	if probe.Has("state") {
		result.state = probe.Str("state")
		result.setDetail(probe.Str("detail"))
	}
}

func stageOK(result *runResult) bool {
	if result.state != "complete" {
		return false
	}
	n, ok := result.exit.(Number)
	return ok && !n.Float && n.Int == 0
}

func readStream(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		return []byte{}
	}
	return data
}

// publishedPid: the pid the corpus-owned launcher published for itself before
// exec. Adapters wait for it rather than assuming one exists.
func publishedPid(pidfile string, deadline float64, stop *stopFlag) (int, error) {
	for {
		if stop.get() {
			return 0, nil
		}
		if !(left(deadline) > 0) {
			return 0, errors.New("RuntimeError: adapter: the program never published its pid")
		}
		data, err := os.ReadFile(pidfile)
		if err == nil && strings.TrimSpace(string(data)) != "" {
			pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
			if err != nil {
				return 0, fmt.Errorf("ArgumentError: invalid value for Integer(): %s", rubyInspect(strings.TrimSpace(string(data))))
			}
			return pid, nil
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func awaitOutput(stream string, deadline float64, stop *stopFlag) (bool, error) {
	for {
		if stop.get() {
			return false, nil
		}
		if !(left(deadline) > 0) {
			return false, errors.New("RuntimeError: signal adapter: program never reported readiness")
		}
		if fileSize(stream) > 0 {
			return true, nil
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type gateContext struct {
	launcher string // the corpus run launcher binary, once built
}

// run is one run/build stage. Spawning, the monotonic deadline, the process
// group, the reap, the teardown and the raw stream capture belong to capture;
// this wrapper only layers the corpus-specific behaviour adapters above it and
// maps the corpus stage vocabulary onto the gate's.
//
// `launch` routes a RUN stage through the corpus-owned tools/go-by-example/
// launch.go, which exec()s the program after publishing its pid and opening a
// liveness FIFO that every descendant inherits. That is what lets an adapter
// signal the program at a readiness line it observed, and what keeps a
// descendant that escaped into its own session -- invisible to capture's
// kill(0, -pgid) -- reported as a leak rather than a clean exit. Neither needs
// a second spawn or timer. An adapter failure is surfaced deterministically at
// join; the interpreter's own stderr dump would only add unattributed noise to
// the replay log.
func (g *gateContext) run(cmd []string, cwd string, env map[string]string, input string, outer float64, childLimit float64, path string, adapters []string, adapterDir string, logPrefix string, launch bool) *runResult {
	result := &runResult{state: "unspawned", stdout: []byte{}, stderr: []byte{}, command: cmd}
	budget := left(outer)
	if childLimit < budget {
		budget = childLimit
	}
	if !(budget > 0) {
		result.setDetail("child deadline expired before spawn")
		return result
	}
	// Adapters observe the SAME deadline capture enforces, not the looser row
	// deadline: an adapter still waiting for a readiness line after the child
	// has already been killed would otherwise spin until the row budget expired
	// and be reported as a cleanup failure instead of the timeout it is.
	deadline := monotonicSeconds() + budget
	if len(cmd) == 0 || !isRegularFile(cmd[0]) || !isExecutable(cmd[0]) {
		name := ""
		if len(cmd) > 0 {
			name = cmd[0]
		}
		result.setDetail("command is not an executable file: " + name)
		return result
	}
	os.MkdirAll(adapterDir, 0o755)
	os.MkdirAll(filepath.Dir(logPrefix), 0o755)
	stdinPath := adapterDir + "/stdin"
	if err := os.WriteFile(stdinPath, []byte(input), 0o644); err != nil {
		result.setDetail("Errno::" + err.Error())
		return result
	}
	pidfile := adapterDir + "/program.pid"
	fifo := adapterDir + "/liveness.fifo"
	var org *origin
	var liveness *os.File
	type joinable struct {
		done chan error
	}
	var threads []joinable
	argv := cmd
	var stage *Object
	// Shared with the adapter goroutines; see drive/publishedPid/awaitOutput.
	stop := newStopFlag()
	spawnThread := func(body func() error) {
		done := make(chan error, 1)
		go func() { done <- body() }()
		threads = append(threads, joinable{done: done})
	}
	func() {
		var err error
		if contains(adapters, "local_http_origin") {
			org, err = newOrigin(deadline, adapterDir)
			if err != nil {
				result.state = "adapter_error"
				result.setDetail("StandardError: " + err.Error())
				return
			}
			env = org.apply(env)
		}
		if launch {
			os.Remove(fifo)
			if err := syscall.Mkfifo(fifo, 0o600); err != nil {
				result.setDetail("Errno::" + err.Error())
				return
			}
			// Opened before the spawn so the launcher's non-blocking write-open finds
			// a reader; the descriptor is what descendants inherit across exec.
			liveness, err = os.OpenFile(fifo, os.O_RDONLY|syscall.O_NONBLOCK, 0)
			if err != nil {
				result.setDetail("Errno::" + err.Error())
				return
			}
			argv = append([]string{g.launcher, fifo, pidfile, "--"}, cmd...)
			result.launchArgv = argv
		}
		if contains(adapters, "loopback_server") {
			spawnThread(func() error {
				pid, err := publishedPid(pidfile, deadline, stop)
				if err != nil || pid == 0 {
					return err
				}
				if err := drive(path, deadline, stop); err != nil {
					return err
				}
				if !stop.get() {
					sig(syscall.SIGTERM, pid)
				}
				return nil
			})
		}
		if contains(adapters, "signal_injector") {
			// "deliver the declared signal once the program has reported readiness":
			// signals.go prints its readiness line only after signal.Notify is armed.
			// A blind sleep raced it and killed the process under the DEFAULT SIGINT
			// disposition, so both sides produced empty output and the example's
			// actual behaviour was never observed. The readiness line is read from the
			// durable stdout log capture is writing.
			spawnThread(func() error {
				pid, err := publishedPid(pidfile, deadline, stop)
				if err != nil || pid == 0 {
					return err
				}
				ready, err := awaitOutput(logPrefix+".stdout", deadline, stop)
				if err != nil {
					return err
				}
				if ready {
					sig(syscall.SIGINT, pid)
				}
				return nil
			})
		}
		stage, err = capture(argv, cwd, logPrefix, env, Flt(budget), stdinPath)
		if err != nil {
			var ce *ContractError
			if errors.As(err, &ce) {
				result.setDetail("Corpus::ContractError: " + ce.msg)
			} else if pe := new(os.PathError); errors.As(err, &pe) {
				class, _ := errnoClass(err)
				result.setDetail(class + ": " + err.Error())
			} else {
				result.state = "adapter_error"
				result.setDetail("StandardError: " + err.Error())
			}
		}
	}()
	stop.set()
	for _, thread := range threads {
		// The join surfaces whatever the adapter raised, so a fixture that failed
		// -- a peer resetting the connection, a bad response line -- is recorded
		// against the one attempt it describes instead of aborting the replay.
		select {
		case err := <-thread.done:
			if err != nil {
				result.state = "adapter_error"
				result.addDetail(err.Error())
			}
		case <-time.After(time.Duration(cleanupLimit * float64(time.Second))):
			result.state = "cleanup_error"
			result.addDetail("adapter thread did not join within cleanup bound")
			select {
			case <-thread.done:
			case <-time.After(time.Duration(cleanupLimit * float64(time.Second))):
			}
		}
	}
	if org != nil {
		joined, err := org.close()
		if err != nil {
			result.state = "adapter_error"
			result.addDetail(err.Error())
		} else if !joined {
			result.state = "cleanup_error"
			result.addDetail("origin thread did not join by row deadline")
		}
	}

	if stage != nil {
		result.capture = stage
		result.spawned = stage.Bool("spawned")
		result.stdout = readStream(logPrefix + ".stdout")
		result.stderr = readStream(logPrefix + ".stderr")
		result.corpusSt = stage.Str("state")
		result.duration = stage.Get("duration_seconds")
		mapped := "unspawned"
		switch stage.Str("state") {
		case "exited":
			mapped = "complete"
		case "deadline":
			mapped = "timeout"
		case "process_leak":
			mapped = "leak"
		}
		// An adapter/cleanup diagnosis already recorded is the more precise one and
		// is not overwritten by the generic mapping.
		if result.state != "adapter_error" && result.state != "cleanup_error" {
			result.state = mapped
		}
		if mapped != "timeout" {
			if exit := stage.Get("exit"); exit != nil {
				result.exit = exit
			} else if signal, ok := stage.Int("signal"); ok {
				result.exit = Int(128 + signal)
			}
		}
		if stage.Str("state") == "process_leak" {
			result.addDetail("a descendant survived process-group termination")
		}
		// The FIFO end is still held by any descendant that inherited it, including
		// one that called setsid() and is therefore invisible to kill(0, -pgid).
		if liveness != nil && result.spawned && sentinelHeld(liveness, cleanupLimit) {
			result.state = "leak"
			result.addDetail("descendant survived process-group termination still holding the inherited liveness descriptor")
		}
	}
	if liveness != nil {
		liveness.Close()
	}
	os.Remove(fifo)
	return result
}

// --- filesystem effects -----------------------------------------------------

// snapshotListing: sorted `relative-path<TAB>content-digest` listing of an
// execution root, walked by snapshot so the entry vocabulary is the shared
// one. Every entry under the root is covered, including HOME, TMPDIR and
// dotfiles.
func snapshotListing(root string) string {
	entries, err := snapshot(root)
	if err != nil {
		fatal(err.Error())
	}
	keys := make([]string, 0, len(entries))
	for k := range entries {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	lines := make([]string, 0, len(keys))
	for _, rel := range keys {
		entry := entries[rel]
		var kind string
		switch entry.Str("kind") {
		case "file":
			kind = "file:" + entry.Str("sha256")
		case "symlink":
			kind = "symlink:" + entry.Str("target")
		case "directory":
			kind = "dir"
		default:
			kind = "other"
		}
		lines = append(lines, rel+"\t"+kind)
	}
	return strings.Join(lines, "\n")
}

// rubySplitNewline is String#split("\n"): trailing empty fields dropped.
func rubySplitNewline(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, "\n")
	for len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

func arrayDifference(a, b []string) []string {
	remove := map[string]bool{}
	for _, x := range b {
		remove[x] = true
	}
	var out []string
	for _, x := range a {
		if !remove[x] {
			out = append(out, x)
		}
	}
	return out
}

func effectDigest(before, after string, normalizations []string) (*Object, error) {
	b := rubySplitNewline(before)
	a := rubySplitNewline(after)
	var delta []string
	for _, l := range arrayDifference(a, b) {
		delta = append(delta, "+"+l)
	}
	for _, l := range arrayDifference(b, a) {
		delta = append(delta, "-"+l)
	}
	sort.Strings(delta)
	text := strings.Join(delta, "\n")
	licensed := []string{}
	for _, n := range normalizations {
		if contains(effectNormalizations, n) {
			licensed = append(licensed, n)
		}
	}
	if len(licensed) > 0 {
		normalized, err := Normalize([]byte(text), licensed, "stdout")
		if err != nil {
			return nil, err
		}
		text = normalized
	}
	return Obj("delta", text, "sha256", sha256Hex([]byte(text)), "normalizations", licensed), nil
}

// --- recipe construction ----------------------------------------------------

var testFunction = regexp.MustCompile(`(?m)^func\s+((?:Test|Benchmark)[A-Za-z0-9_]*)\s*\(`)

// testDriver: the generated driver is a SEPARATE artifact beside the unchanged
// _test.go bytes; it never edits them. Verified against the upstream recipe:
// for the pinned testing-and-benchmarking row, `go build` of (unchanged bytes
// + this driver) run with -test.v produces byte-identical output and status to
// `go test -c` of the same bytes.
func testDriver(source []byte, label string) (string, error) {
	var tests, benchmarks []string
	for _, m := range testFunction.FindAllSubmatch(source, -1) {
		name := string(m[1])
		if strings.HasPrefix(name, "Test") {
			tests = append(tests, name)
		} else {
			benchmarks = append(benchmarks, name)
		}
	}
	if len(tests) == 0 {
		return "", fmt.Errorf("no Test functions found in %s", label)
	}
	entries := func(names []string) string {
		lines := make([]string, len(names))
		for i, n := range names {
			lines[i] = "\t\t\t{Name: " + rubyInspect(n) + ", F: " + n + "},"
		}
		return strings.Join(lines, "\n")
	}
	return "// GENERATED by tools/go-by-example/gbe/gate.go for " + label + ".\n" +
		"// Not upstream bytes: a driver only, so the unchanged _test.go really runs\n" +
		"// its assertions in every mode instead of being treated as a script.\n" +
		"package main\n\n" +
		"import (\n\t\"regexp\"\n\t\"testing\"\n)\n\n" +
		"func gbeMatchString(pat, str string) (bool, error) { return regexp.MatchString(pat, str) }\n\n" +
		"func main() {\n\ttesting.Main(gbeMatchString,\n\t\t[]testing.InternalTest{\n" +
		entries(tests) + "\n\t\t},\n\t\t[]testing.InternalBenchmark{\n" +
		entries(benchmarks) + "\n\t\t},\n\t\tnil,\n\t)\n}\n", nil
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	st, err := os.Stat(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, st.Mode().Perm())
}

// stageAssets places every declared runtime asset AT ITS ORIGINAL PATH
// RELATIVE TO THE PROGRAM. Copying by basename would break
// `//go:embed folder/single_file.txt`, which the Go compiler resolves against
// the directory holding the source file.
func stageAssets(dir string, row []string) string {
	os.MkdirAll(dir, 0o755)
	exampleDir := filepath.Dir(row[0])
	for _, asset := range toks(row[5]) {
		if !strings.HasPrefix(asset, exampleDir+"/") {
			fatal(fmt.Sprintf("asset %s is not inside %s", asset, exampleDir))
		}
		target := filepath.Join(dir, asset[len(exampleDir)+1:])
		os.MkdirAll(filepath.Dir(target), 0o755)
		if err := copyFile(ROOT+"/"+asset, target); err != nil {
			fatal(err.Error())
		}
	}
	return dir
}

func stageSources(dir string, row []string, name string) string {
	stageAssets(dir, row)
	if err := copyFile(ROOT+"/"+row[0], filepath.Join(dir, name)); err != nil {
		fatal(err.Error())
	}
	return dir
}

// stageRoot: a fresh, identically shaped execution root per mode: nothing but
// the runtime layout and the declared assets, so a filesystem comparison stays
// meaningful.
func stageRoot(dir string, row []string, adapters []string) string {
	stageAssets(dir, row)
	os.MkdirAll(dir+"/home", 0o755)
	os.MkdirAll(dir+"/tmp", 0o755)
	// input_file_fixture: the pinned bytes the program reads, created before the
	// baseline snapshot so it is an input and never counted as an effect.
	if contains(adapters, "input_file_fixture") {
		os.WriteFile(dir+"/tmp/dat", []byte("hello\ngo\n"), 0o644)
	}
	return dir
}

// --- environments -------------------------------------------------------

type toolchainContext struct {
	goroot     string
	goBinary   string
	gomodcache string
	runGocache string
	shModule   string
}

func buildEnv(tc *toolchainContext, gocache, gomodcache, gohome, gotmp string) map[string]string {
	return map[string]string{
		"LC_ALL": "C.UTF-8", "LANG": "C.UTF-8", "TZ": "UTC",
		"HOME": gohome, "TMPDIR": gotmp, "GOTMPDIR": gotmp,
		"GOROOT": tc.goroot, "PATH": filepath.Dir(tc.goBinary), "GOTOOLCHAIN": "local",
		"GOCACHE": gocache, "GOMODCACHE": gomodcache,
		"GOFLAGS": "-mod=mod -p=2", "GOPROXY": "off", "GOSUMDB": "off",
		"GOWORK": "off", "CGO_ENABLED": "0",
	}
}

// runEnv: run environment, identical in all three modes apart from the
// per-mode root prefix. PATH is provisioned only for the rows whose declared
// behavior is to execute another program; everything else runs with an empty
// PATH so a stray host tool cannot supply a result.
//
// GOROOT and GOMODCACHE are in the COMMON block. They are what the product's
// runtime import helper reads to resolve `import "fmt"` and module imports, and
// they are granted identically to the oracle binary and to the compiled
// artifact, which ignore them. examples/environment-variables therefore observes
// the same keys in all three modes -- the only way this harness may satisfy a
// product runtime need.
//
// GOCACHE is in that block for a measured reason of its own: the interpreted
// mode invokes the pinned toolchain AT RUN TIME, and with no explicit cache it
// falls back to $HOME -- which this harness deliberately places INSIDE the
// compared execution root, so several thousand build-cache entries were being
// recorded as program effects. Pointing all three modes at one cache outside the
// roots is environment construction, not normalization: it makes the effect
// channel measure the program rather than the toolchain. It does not hide the
// run-time toolchain use itself, which prerequisites.md records. Supported
// telemetry opt-outs are configured identically before each effect baseline.
//
// Note what none of this is: an empty PATH is command-lookup isolation, not an
// OS-level denial of the SDK or of the source tree, and the evidence says so
// rather than claiming a sandbox it does not build.
func runEnv(tc *toolchainContext, root string, behaviors []string) map[string]string {
	path := ""
	if contains(behaviors, "process_exec") {
		path = "/usr/bin:/bin"
	}
	return map[string]string{
		"PATH": path,
		"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC",
		"HOME": root + "/home", "TMPDIR": root + "/tmp", "PWD": root,
		"BAR":    "",
		"GOROOT": tc.goroot, "GOMODCACHE": tc.gomodcache, "GOCACHE": tc.runGocache,
		"GOTOOLCHAIN": "local", "GOPROXY": "off", "GOSUMDB": "off",
		"BASHY_HINTS": "off", "OTEL_TRACES_EXPORTER": "none",
	}
}

// envProfile: root-independent form, so the three environments are actually
// comparable.
func envProfile(env map[string]string, root string) [][2]string {
	var out [][2]string
	for k, v := range env {
		out = append(out, [2]string{k, strings.ReplaceAll(v, root, "${ROOT}")})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i][0] != out[j][0] {
			return out[i][0] < out[j][0]
		}
		return out[i][1] < out[j][1]
	})
	return out
}

type replacement struct{ from, to string }

func relativize(value string, replacements []replacement) string {
	for _, r := range replacements {
		if r.from == "" {
			continue
		}
		value = strings.ReplaceAll(value, r.from, r.to)
	}
	return value
}

func relativizeAll(values []string, replacements []replacement) []any {
	out := make([]any, len(values))
	for i, v := range values {
		out[i] = relativize(v, replacements)
	}
	return out
}

func stageRecord(name string, result *runResult, replacements []replacement, extra *Object) *Object {
	var launchArgv any
	if result.launchArgv != nil {
		launchArgv = relativizeAll(result.launchArgv, replacements)
	}
	var detail any
	if result.hasDetail {
		detail = relativize(result.detail, replacements)
	}
	head := result.stderr
	if len(head) > 512 {
		head = head[:512]
	}
	record := Obj(
		"stage", name,
		"capture", captureValue(result.capture),
		"argv", relativizeAll(result.command, replacements),
		// What capture was actually handed, when the corpus-owned launcher was
		// interposed. Recorded so `argv` is never read as the whole truth about
		// how the stage was started.
		"launch_argv", launchArgv,
		"spawned", result.spawned, "state", result.state, "exit", result.exit,
		"detail", detail,
		"stdout_sha256", sha256Hex(result.stdout),
		"stderr_sha256", sha256Hex(result.stderr),
		"stderr_head", relativize(string(head), replacements),
	)
	if extra != nil {
		record.Merge(extra)
	}
	return record.Compact()
}

func captureValue(c *Object) any {
	if c == nil {
		return nil
	}
	return c
}

// --- evidence ---------------------------------------------------------------

func attemptRecord(fields *Object) *Object {
	record := fields.Compact()
	record.Set("evidence_sha256", sha256Hex([]byte(Generate(record))))
	return record
}

func b64(data []byte) string { return base64.StdEncoding.EncodeToString(data) }

// --- the gate -------------------------------------------------------------

func gateMain(args []string) {
	inventoryPath := envOr("GBE_INVENTORY", DOCS+"/inventory.tsv")
	schemaPath := envOr("GBE_SCHEMA", DOCS+"/behavior-schema.tsv")
	classificationPath := DOCS + "/classification.tsv"
	candidatesPath := DOCS + "/candidates.tsv"
	launcherSource := ROOT + "/tools/go-by-example/launch.go"

	// --- CLI arg contract ---
	// `--candidate MANIFEST` selects WHICH reviewed candidate to drive and
	// `--bashy` names its launcher. There is no default candidate: a gate that
	// silently ran whatever binary happened to be on PATH would be reporting on
	// an unidentified product. The manifest cannot introduce a candidate either
	// -- every field of it has to equal a reviewed row of candidates.tsv.
	candidateArg, bashyArg, resultsArg := "", "", ""
	for i := 0; i < len(args); i++ {
		flag := args[i]
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch {
		case flag == "--candidate":
			candidateArg = next()
		case flag == "--bashy":
			bashyArg = next()
		case flag == "--evidence":
			resultsArg = next()
		case strings.HasPrefix(flag, "--candidate="):
			candidateArg = flag[len("--candidate="):]
		case strings.HasPrefix(flag, "--bashy="):
			bashyArg = flag[len("--bashy="):]
		case strings.HasPrefix(flag, "--evidence="):
			resultsArg = flag[len("--evidence="):]
		default:
			fatal("unknown argument: " + flag)
		}
	}
	results := resultsArg
	if results == "" {
		results = envOr("GBE_RESULTS", ROOT+"/.cache/go-by-example/results.jsonl")
	}
	bashyValue := bashyArg
	if bashyValue == "" {
		bashyValue = os.Getenv("BASHY_BIN")
	}
	BASHY := expandPath(bashyValue)

	rowLimit = envFloat("GBE_ROW_TIMEOUT", "240")
	transpileLimit = envFloat("GBE_TRANSPILE_TIMEOUT", "60")
	buildLimit = envFloat("GBE_BUILD_TIMEOUT", "120")
	runLimit = envFloat("GBE_RUN_TIMEOUT", "20")
	cleanupLimit = envFloat("GBE_CLEANUP_TIMEOUT", "2")

	// --- authenticated inputs ---
	if os.Getenv("GBE_SKIP_INTEGRITY") != "1" {
		if validateMain(nil, os.Stdout) != 0 {
			fatal("corpus integrity gate failed")
		}
	}

	// The candidate is authenticated before anything is staged, and it is
	// authenticated through the shared corpus primitives: authenticateFile for
	// the launcher, its adjacent `.real` payload and the SDK, and
	// authenticateCandidate for every declared repository at its clean exact
	// revision, untracked files included. The gate adds only the repository
	// anchor: the supplied manifest must equal a reviewed row of
	// candidates.tsv, so a caller selects a candidate but can never introduce one.
	toolpin, err := toolchainPin(DOCS + "/toolchain.tsv")
	if err != nil {
		fatal(err.Error())
	}
	candidateManifest, err := manifestPath(candidateArg)
	if err != nil {
		fatal(err.Error())
	}
	manifestSHA, err := digest(candidateManifest)
	if err != nil {
		fatal(err.Error())
	}
	reviewed, err := reviewedCandidate(candidatesPath, manifestSHA)
	if err != nil {
		fatal(err.Error())
	}
	CANDIDATE, err := authenticateManifest(candidateManifest, BASHY, reviewed, toolpin, DOCS)
	if err != nil {
		if _, isJSON := err.(*jsonParseError); isJSON {
			fatal("candidate manifest is not valid JSON")
		}
		fatal(err.Error())
	}

	tc := resolveToolchain(toolpin)
	// The SDK the modules were fetched into is part of the same runtime context
	// the product's import helper reads; it is supplied to every mode identically.

	// The generated Go depends on the lowering runtime. It is not provisioned
	// out of band through GBE_SH_MODULE, which was an unauthenticated
	// environment path: it is the mvdan.cc/sh/v3 repository the AUTHENTICATED
	// candidate declares, already proved to be at its clean reviewed commit.
	tc.shModule = CANDIDATE.Obj("sh_module").Str("path")
	realBashy := CANDIDATE.Obj("launcher").Str("path")
	bashySHA := CANDIDATE.Str("launcher_sha256")
	payloadSHA := CANDIDATE.Str("payload_sha256")
	goModLowered := "module gbelowered\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.0.0\n\nreplace mvdan.cc/sh/v3 => " + tc.shModule + "\n"
	versionCmd := exec.Command(BASHY, "--version")
	bashyVersion, err := versionCmd.CombinedOutput()
	if err != nil || len(bashyVersion) == 0 {
		fatal("Bash++ identity command failed")
	}

	schemaRows, err := os.ReadFile(schemaPath)
	if err != nil {
		fatal(err.Error())
	}
	var schemaAdapters, schemaNorms []string
	for _, line := range rubyLinesChomp(string(schemaRows)) {
		fields := strings.Split(line, "\t")
		if len(fields) > 1 && fields[0] == "adapter" {
			schemaAdapters = append(schemaAdapters, fields[1])
		}
		if len(fields) > 1 && fields[0] == "normalization" {
			schemaNorms = append(schemaNorms, fields[1])
		}
	}
	if !sameSet(schemaAdapters, ADAPTERS) {
		fatal("adapter registry differs from schema")
	}
	if !sameSet(schemaNorms, NormalizerNames) {
		fatal("normalizer registry differs from schema")
	}

	inventory, err := readTSV(inventoryPath)
	if err != nil {
		fatal(err.Error())
	}
	var rows [][]string
	for _, r := range inventory {
		if len(r) > 1 && (r[1] == "program" || r[1] == "test_program") {
			rows = append(rows, r)
		}
	}
	if len(rows) != 85 {
		fatal(fmt.Sprintf("expected exactly 85 program rows, got %d", len(rows)))
	}
	for _, r := range rows {
		path := ROOT + "/" + r[0]
		if !isRegularFile(path) || strconv.FormatInt(fileSize(path), 10) != r[6] || sha(path) != r[7] {
			fatal("source changed during gate: " + r[0])
		}
	}
	denominator := len(rows) * len(MODES)

	launcherStat := mustStat(realBashy)
	payloadStat := mustStat(realBashy + ".real")
	// The whole candidate, not one artifact digest: launcher AND payload, the
	// exact clean revision of every repository the candidate links (its
	// lowering runtime and every other replaced module), the asserted build
	// recipe, the front-end version and the SDK identity. `build_recipe` is
	// bound, never inferred -- this repository can prove these bytes and these
	// revisions, and it does not claim to have observed the build that produced
	// them.
	var repoRecords []*Object
	for _, r := range CANDIDATE.Arr("repositories") {
		repo := r.(*Object)
		repoRecords = append(repoRecords, Obj("name", filepath.Base(repo.Str("path")), "commit", repo.Get("commit")))
	}
	sort.SliceStable(repoRecords, func(i, j int) bool { return repoRecords[i].Str("name") < repoRecords[j].Str("name") })
	repoValues := make([]any, len(repoRecords))
	for i, r := range repoRecords {
		repoValues[i] = r
	}
	candidate := Obj(
		"manifest_path", candidateManifest, "manifest_sha256", CANDIDATE.Obj("manifest").Str("sha256"),
		"candidates_sha256", CANDIDATE.Str("candidates_sha256"),
		"launcher_path", realBashy, "launcher_sha256", bashySHA,
		"payload_path", CANDIDATE.Obj("payload").Str("path"), "payload_sha256", payloadSHA,
		"frontend_version", CANDIDATE.Get("frontend_version"),
		"build_recipe", CANDIDATE.Get("build_recipe"),
		"go_identity", CANDIDATE.Get("go_identity"),
		"repositories", repoValues,
		"sh_module_commit", CANDIDATE.Obj("sh_module").Get("commit"),
		"version_sha256", sha256Hex(bashyVersion),
		"device", Int(launcherStat[0]), "inode", Int(launcherStat[1]),
		"payload_device", Int(payloadStat[0]), "payload_inode", Int(payloadStat[1]),
	)
	var corpusRootText strings.Builder
	for _, r := range rows {
		corpusRootText.WriteString(r[0] + "\x00" + r[7] + "\n")
	}
	corpusRoot := sha256Hex([]byte(corpusRootText.String()))
	gbeDir := ROOT + "/tools/go-by-example/gbe"
	manifest := Obj(
		"type", "manifest", "schema", Int(evidenceSchema), "story", story,
		"corpus_sha256", sha(inventoryPath), "corpus_root_sha256", corpusRoot,
		"behavior_schema_sha256", sha(schemaPath), "classification_sha256", sha(classificationPath),
		"normalizer_version", Int(NormalizerVersion), "normalizer_sha256", sha(gbeDir+"/normalizer.go"),
		"toolchain_sha256", sha(DOCS+"/toolchain.tsv"), "go_sha256", toolpin.GoSHA256,
		"candidate", candidate,
		"denominator", Obj("rows", Int(int64(len(rows))), "modes_per_row", Int(int64(len(MODES))), "attempts", Int(int64(denominator))),
		"modes", MODES,
		"recipe", Obj(
			"oracle", "pinned go build (go test -c for test_program) then run the native binary",
			"interpreted", "bashy --bashpp --source=go <source> [argv...]; explicit multi-file uses repeated --go-file",
			"compiled", "bashy transpile --bashpp --source=go <source|--go-file...> -o gen.go --map gen.go.map; pinned go build; run the artifact",
			"multi_file_input", "--go-file",
			"multi_file_program_arguments", "-- separator before program argv",
			"declared_env_divergence", declaredEnvDivergence,
			"common_runtime_go_env", []string{"GOROOT", "GOMODCACHE", "GOCACHE"},
			"effect_normalizations", effectNormalizations,
			"process_primitives", "tools/go-by-example/gbe/corpus.go Corpus.capture/success?/snapshot/file_record/authenticate_candidate (absorbed from tools/corpus/executor.rb)",
			"corpus_executor_sha256", sha(gbeDir+"/corpus.go"),
			"input_binding_sha256", sha(gbeDir+"/inputs.go"),
			"runtime_config_sha256", sha(gbeDir+"/runtimeconfig.go"),
			"runtime_telemetry", Obj("OTEL_TRACES_EXPORTER", "none", "Go", "pinned go telemetry off in each isolated HOME before effect baseline"),
			"launcher_source_sha256", sha(launcherSource),
			"source_absence", "compilation inputs are absent from the run cwd and PATH is empty for every row that does not declare process_exec; this is cwd and command-lookup isolation, NOT an OS-level denial of the SDK or of the source tree",
			"source_layout", "per mode, original program plus declared assets at their original relative paths",
		),
	)
	binding := sha256Hex([]byte(Generate(manifest)))
	records := []*Object{manifest}
	incomplete := false

	os.MkdirAll(filepath.Dir(results), 0o755)
	journal, err := os.OpenFile(results+".progress.jsonl", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		fatal("Errno::EEXIST: File exists @ rb_sysopen - " + results + ".progress.jsonl")
	}
	journal.WriteString(Generate(manifest) + "\n")
	base := expandPath(envOr("GBE_WORK_ROOT", results+".work"))
	if _, err := os.Lstat(base); err == nil {
		fatal("refusing to overwrite retained work: " + base)
	}
	os.MkdirAll(base, 0o755)

	gocache := base + "/gocache"
	gomodcache := tc.gomodcache
	gohome := base + "/gohome"
	gotmp := base + "/gotmp"
	for _, d := range []string{gocache, gomodcache, gohome, gotmp} {
		os.MkdirAll(d, 0o755)
	}
	benv := buildEnv(tc, gocache, gomodcache, gohome, gotmp)
	g := &gateContext{}

	// The corpus-owned run launcher is compiled once, by the same pinned SDK as
	// the oracle, before any row is attempted. It is a native binary because a
	// run stage's PATH is deliberately empty: an interpreter that shells out at
	// startup could not run there, and granting one a PATH would change what
	// examples/environment-variables and the process_exec rows observe.
	launcherSrc := base + "/launcher"
	os.MkdirAll(launcherSrc, 0o755)
	if err := copyFile(launcherSource, launcherSrc+"/launch.go"); err != nil {
		fatal(err.Error())
	}
	os.WriteFile(launcherSrc+"/go.mod", []byte("module gbelaunch\n\ngo 1.27\n"), 0o644)
	LAUNCHER := base + "/bin/gbe-launch"
	os.MkdirAll(base+"/bin", 0o755)
	launcherBuild := g.run([]string{tc.goBinary, "build", "-o", LAUNCHER, "."}, launcherSrc, benv, "",
		monotonicSeconds()+buildLimit, buildLimit, "tools/go-by-example/launch.go", nil, base+"/stage/launcher", base+"/logs/launcher", false)
	if !stageOK(launcherBuild) || !nativeBinary(LAUNCHER) {
		reason := launcherBuild.detail
		if !launcherBuild.hasDetail {
			reason = string(launcherBuild.stderr)
			if len(reason) > 400 {
				reason = reason[:400]
			}
		}
		fatal("cannot build the corpus run launcher: " + reason)
	}
	g.launcher = LAUNCHER
	// One run-time toolchain cache, outside every execution root, shared by all
	// three modes exactly like GOROOT and GOMODCACHE.
	tc.runGocache = gocache
	os.MkdirAll(tc.runGocache, 0o755)
	replacements := []replacement{{base, "${WORK}"}, {ROOT, "${ROOT}"}, {tc.goroot, "${GOROOT}"}, {tc.shModule, "${SH_MODULE}"}}

	for index, row := range rows {
		deadline := monotonicSeconds() + rowLimit
		path, kind := row[0], row[1]
		behaviors := toks(row[2])
		normalizations := toks(row[3])
		adapters := toks(row[4])
		testRow := kind == "test_program"
		name := filepath.Base(path)
		work := base + fmt.Sprintf("/%03d", index)
		os.MkdirAll(work, 0o755)

		args := []string{}
		if contains(adapters, "argv_fixture") {
			args = []string{"foo", "bar", "baz"}
		}
		if testRow {
			args = []string{"-test.v"}
		}
		input := ""
		if contains(adapters, "stdin_fixture") {
			input = "hello\nworld\n"
		}
		// Adapters that drive or signal the process under test apply to the run
		// stage only; a build must never be terminated by a client fixture, so the
		// build stages below are given an empty adapter list.
		runAdapters := adapters

		stages := map[string][]*Object{"oracle": {}, "interpreted": {}, "compiled": {}}
		binaries := map[string]string{}
		// The pinned corpus directory and work/bin are read by every mode; each
		// staging tree below is handed to exactly one mode and is scoped to it.
		bindings := []*InputBinding{newInputBinding(filepath.Dir(ROOT+"/"+path), false, "shared")}

		// -- oracle: build the pinned bytes natively, then run the binary.
		oracleSrc := work + "/src/oracle"
		oracleName := name
		if testRow {
			oracleName = "main_test.go"
		}
		stageSources(oracleSrc, row, oracleName)
		os.WriteFile(oracleSrc+"/go.mod", []byte(goModOracle), 0o644)
		bindings = append(bindings, newInputBinding(oracleSrc, true, "oracle"))
		oracleBin := work + "/bin/oracle"
		os.MkdirAll(work+"/bin", 0o755)
		oracleCmd := []string{tc.goBinary, "build", "-o", oracleBin, "."}
		if testRow {
			oracleCmd = []string{tc.goBinary, "test", "-c", "-o", oracleBin, "."}
		}
		oracleBuild := g.run(oracleCmd, oracleSrc, benv, "", deadline, buildLimit, path, nil, work+"/stage/oracle-build", work+"/logs/oracle-build", false)
		enforceRun(oracleBuild, bindings, []string{"shared", "oracle"})
		oracleStage := "oracle-build"
		if testRow {
			oracleStage = "oracle-test-build"
		}
		stages["oracle"] = append(stages["oracle"], stageRecord(oracleStage, oracleBuild, replacements, Obj("source_sha256", row[7])))
		if stageOK(oracleBuild) && isRegularFile(oracleBin) && isExecutable(oracleBin) && nativeBinary(oracleBin) {
			binaries["oracle"] = oracleBin
			last(stages["oracle"]).Set("native_file", mustFileRecord(oracleBin))
		}

		// -- product inputs: unchanged bytes, plus a generated driver for the test
		//    row. The driver is a separate file; the _test.go bytes are untouched.
		productInputs := map[string]*Object{}
		sourceArguments := map[string][]string{}
		for _, mode := range []string{"interpreted", "compiled"} {
			productSrc := work + "/src/" + mode
			stageSources(productSrc, row, name)
			inputs := []string{productSrc + "/" + name}
			if testRow {
				driver := productSrc + "/gbe_test_driver.go"
				source, err := os.ReadFile(ROOT + "/" + path)
				if err != nil {
					fatal(err.Error())
				}
				text, err := testDriver(source, path)
				if err != nil {
					fatal(err.Error())
				}
				os.WriteFile(driver, []byte(text), 0o644)
				inputs = append(inputs, driver)
			}
			if sha(productSrc+"/"+name) != row[7] {
				fatal("staged product source diverged from the pinned bytes: " + path)
			}
			bindings = append(bindings, newInputBinding(productSrc, false, mode))
			records := NewObject()
			for _, file := range inputs {
				records.Set(file, mustFileRecord(file))
			}
			productInputs[mode] = records
			if len(inputs) == 1 {
				sourceArguments[mode] = []string{inputs[0]}
			} else {
				var flagged []string
				for _, file := range inputs {
					flagged = append(flagged, "--go-file", file)
				}
				sourceArguments[mode] = flagged
			}
		}

		// -- compiled: transpile the unchanged Go, build the generated Go, run it.
		transpileDir := work + "/compiled/transpile"
		os.MkdirAll(transpileDir, 0o755)
		generated := transpileDir + "/generated.go"
		sourceMap := transpileDir + "/generated.go.map"
		transpileCmd := append([]string{BASHY, "transpile", "--bashpp", "--source=go"}, sourceArguments["compiled"]...)
		transpileCmd = append(transpileCmd, "-o", generated, "--map", sourceMap)
		transpile := g.run(transpileCmd, transpileDir, benv, "", deadline, transpileLimit, path, nil, work+"/stage/transpile", work+"/logs/transpile", false)
		enforceRun(transpile, bindings, []string{"shared", "compiled"})
		inputSHA := NewObject()
		for _, file := range productInputs["compiled"].Keys() {
			inputSHA.Set(file, productInputs["compiled"].Obj(file).Get("sha256"))
		}
		stages["compiled"] = append(stages["compiled"], stageRecord("transpile", transpile, replacements, Obj("source_sha256", row[7], "input_sha256", inputSHA)))
		loweredOK := stageOK(transpile) && fileSize(generated) > 0
		if loweredOK {
			last(stages["compiled"]).Set("generated_go_sha256", sha(generated))
			// The declared source map is checked against the shared corpus schema,
			// not merely recorded: a transpile that emitted an unparseable,
			// mis-positioned or mis-digested map has not produced the artifact the
			// contract describes, and the compiled mode must not proceed as if it had.
			var mapping *Object
			if data, err := os.ReadFile(sourceMap); err == nil {
				if parsed, err := Parse(data); err == nil {
					mapping, _ = parsed.(*Object)
				}
			}
			if mapping != nil && validSourceMap(mapping, mustFileRecord(generated), productInputs["compiled"]) {
				last(stages["compiled"]).Set("generated_file", mustFileRecord(generated))
				last(stages["compiled"]).Set("source_map_file", mustFileRecord(sourceMap))
				last(stages["compiled"]).Set("source_inputs", productInputs["compiled"])
				last(stages["compiled"]).Set("source_map_sha256", sha(sourceMap))
				bindings = append(bindings, newInputBinding(transpileDir, false, "compiled"))
			} else {
				loweredOK = false
				last(stages["compiled"]).Set("state", "invalid_source_map")
			}
		}

		if loweredOK {
			buildDir := work + "/compiled/build"
			stageAssets(buildDir, row)
			os.WriteFile(buildDir+"/go.mod", []byte(goModLowered), 0o644)
			if err := copyFile(generated, buildDir+"/main.go"); err != nil {
				fatal(err.Error())
			}
			bindings = append(bindings, newInputBinding(buildDir, true, "compiled"))
			loweredBin := work + "/bin/lowered"
			build := g.run([]string{tc.goBinary, "build", "-o", loweredBin, "."}, buildDir, benv, "", deadline, buildLimit, path, nil, work+"/stage/build", work+"/logs/build", false)
			enforceRun(build, bindings, []string{"shared", "compiled"})
			stages["compiled"] = append(stages["compiled"], stageRecord("build", build, replacements, Obj("generated_go_sha256", sha(generated))))
			if stageOK(build) && isRegularFile(loweredBin) && isExecutable(loweredBin) && nativeBinary(loweredBin) {
				binaries["compiled"] = loweredBin
				last(stages["compiled"]).Set("native_file", mustFileRecord(loweredBin))
				last(stages["compiled"]).Set("artifact_sha256", sha(loweredBin))
				last(stages["compiled"]).Set("artifact_bytes", Int(fileSize(loweredBin)))
			}
		}

		bindings = append(bindings, newInputBinding(work+"/bin", false, "shared"))

		// -- three runs, each in its own freshly constructed execution root.
		type observation struct {
			configuration *Object
			result        *runResult
			effects       *Object
			profile       [][2]string
		}
		observations := map[string]*observation{}
		runtimeRoots := map[string]string{}
		for _, mode := range MODES {
			runtimeRoots[mode] = stageRoot(work+"/run/"+mode, row, adapters)
		}
		for _, mode := range MODES {
			root := runtimeRoots[mode]
			// Adapter scratch (the loopback origin's trust anchor) lives OUTSIDE the
			// execution root so a gate fixture can never be read as a program effect.
			adapterDir := work + "/adapters/" + mode
			os.MkdirAll(adapterDir, 0o755)
			env := runEnv(tc, root, behaviors)
			var command []string
			switch mode {
			case "oracle":
				if b, ok := binaries["oracle"]; ok {
					command = append([]string{b}, args...)
				}
			case "compiled":
				if b, ok := binaries["compiled"]; ok {
					command = append([]string{b}, args...)
				}
			default:
				command = append([]string{BASHY, "--bashpp", "--source=go"}, sourceArguments["interpreted"]...)
				if testRow && len(args) > 0 {
					command = append(command, "--")
				}
				command = append(command, args...)
			}
			configuration := configureRuntime(tc.goBinary, root, env, deadline, work+"/logs/config-"+mode)
			before := snapshotListing(root)
			var result *runResult
			if command != nil && bindingsIntact(bindings, []string{"shared", mode}) && configuration.Str("state") == "complete" {
				result = g.run(command, root, env, input, deadline, runLimit, path, runAdapters, adapterDir, work+"/logs/run-"+mode, true)
			} else {
				missing := "oracle build"
				if mode != "oracle" {
					missing = ""
					if n := len(stages["compiled"]); n > 0 {
						missing = stages["compiled"][n-1].Str("stage")
					}
				}
				result = &runResult{state: "unspawned", stdout: []byte{}, stderr: []byte{}, command: []string{}}
				result.setDetail("no runnable artifact: " + missing + " did not produce one")
			}
			if configuration.Str("state") != "complete" {
				result.state = "configuration_failure"
			}
			enforceRun(result, bindings, []string{"shared", mode})
			after := snapshotListing(root)
			effects, err := effectDigest(before, after, normalizations)
			if err != nil {
				result.addDetail("effect normalization failed: " + err.Error())
				effects = nil
			}
			stages[mode] = append(stages[mode], stageRecord("run", result, replacements, nil))
			observations[mode] = &observation{configuration: configuration, result: result, effects: effects, profile: envProfile(env, root)}
		}

		divergent := envDivergence(observations["oracle"].profile, observations["interpreted"].profile, observations["compiled"].profile)
		var undeclared []string
		for _, key := range divergent {
			if !contains(declaredEnvDivergence, key) {
				undeclared = append(undeclared, key)
			}
		}
		if len(undeclared) > 0 {
			fatal("undeclared environment divergence on " + path + ": " + rubyStringArray(undeclared))
		}

		reference := observations["oracle"]
		referenceNormalized, referenceOK := normalizePair(reference.result, normalizations)

		for _, mode := range MODES {
			obs := observations[mode]
			result := obs.result
			if result.state != "complete" || !result.spawned {
				incomplete = true
			}
			normalized, normalizedOK := normalizePair(result, normalizations)
			if !normalizedOK {
				result.addDetail(normalized[2])
			}
			var verdict string
			switch {
			case result.state != "complete":
				verdict = "fail_incomplete"
			case !normalizedOK || !referenceOK || obs.effects == nil:
				verdict = "fail_normalization"
			case mode == "oracle":
				verdict = "pass"
			case !deepEqual(result.exit, reference.result.exit) || normalized[0] != referenceNormalized[0] || normalized[1] != referenceNormalized[1]:
				verdict = "fail_mismatch"
			case reference.effects != nil && obs.effects.Str("sha256") != reference.effects.Str("sha256"):
				verdict = "fail_effects"
			default:
				verdict = "pass"
			}
			var normalizedStdout, normalizedStderr, effectsSHA, effectsDelta, detail any
			if normalizedOK {
				normalizedStdout = b64([]byte(normalized[0]))
				normalizedStderr = b64([]byte(normalized[1]))
			}
			if obs.effects != nil {
				effectsSHA = obs.effects.Get("sha256")
				effectsDelta = obs.effects.Get("delta")
			}
			if result.hasDetail {
				detail = relativize(result.detail, replacements)
			}
			stageValues := make([]any, len(stages[mode]))
			for i, s := range stages[mode] {
				stageValues[i] = s
			}
			records = append(records, attemptRecord(Obj(
				"type", "attempt", "path", path, "mode", mode, "kind", kind,
				"spawned", result.spawned, "state", result.state, "exit", result.exit,
				"raw_stdout_b64", b64(result.stdout),
				"raw_stderr_b64", b64(result.stderr),
				"normalized_stdout_b64", normalizedStdout,
				"normalized_stderr_b64", normalizedStderr,
				"effects_sha256", effectsSHA,
				"effects_delta", effectsDelta,
				"stages", stageValues, "configuration", obs.configuration,
				"verdict", verdict, "detail", detail,
				"binding_sha256", binding,
			)))
		}

		if sha(ROOT+"/"+path) != row[7] {
			fatal("source changed during gate: " + path)
		}
		tail := records[len(records)-len(MODES):]
		for _, record := range tail {
			journal.WriteString(Generate(record) + "\n")
		}
		journal.Sync()
		var summaryParts []string
		for _, r := range tail {
			exit := ""
			if r.Get("exit") != nil {
				exit = r.Get("exit").(Number).String()
			}
			summaryParts = append(summaryParts, fmt.Sprintf("%s=%s(%s,%s)", r.Str("mode"), r.Str("verdict"), r.Str("state"), exit))
		}
		fmt.Printf("ROW %d/%d %s: %s\n", index+1, len(rows), path, strings.Join(summaryParts, " "))
	}

	journal.Close()

	attempts := 0
	for _, r := range records {
		if r.Str("type") == "attempt" {
			attempts++
		}
	}
	if attempts != denominator {
		fatal(fmt.Sprintf("missing-attempt evidence: expected %d attempt records, got %d", denominator, attempts))
	}
	bashyReal, err := realPath(BASHY)
	if err != nil || bashyReal != realBashy || sha(realBashy) != bashySHA || !sameInode(realBashy, launcherStat[1]) {
		fatal("candidate mutation during gate")
	}
	if sha(realBashy+".real") != payloadSHA || !sameInode(realBashy+".real", payloadStat[1]) {
		fatal("candidate payload mutation during gate")
	}
	if sha(candidateManifest) != candidate.Str("manifest_sha256") || sha(candidatesPath) != candidate.Str("candidates_sha256") {
		fatal("candidate manifest mutation during gate")
	}
	for _, record := range records {
		if record.Str("type") != "attempt" {
			continue
		}
		body := record.Without("evidence_sha256")
		if record.Str("binding_sha256") != binding || record.Str("evidence_sha256") != sha256Hex([]byte(Generate(body))) {
			fatal("result tampering detected")
		}
	}

	// Temp workspace cleanup and all joins precede publication. Unspawned
	// commands remain attempt evidence, but are never included in the executed
	// numerator.
	executed := 0
	failures := []any{}
	for _, r := range records {
		if r.Str("type") != "attempt" {
			continue
		}
		if r.Bool("spawned") {
			executed++
		}
		if r.Str("verdict") != "pass" {
			failures = append(failures, r.Str("path")+":"+r.Str("mode")+":"+r.Str("verdict"))
		}
	}
	verdict := "fail"
	if len(failures) == 0 && !incomplete && attempts == denominator && executed == denominator {
		verdict = "pass"
	}
	summary := Obj(
		"type", "summary", "verdict", verdict, "denominator", Int(int64(denominator)),
		"attempt_records", Int(int64(attempts)), "executed", Int(int64(executed)), "missing_or_unspawned", Int(int64(denominator-executed)),
		"failures", failures,
		"corpus_sha256", manifest.Get("corpus_sha256"), "corpus_root_sha256", corpusRoot,
		"behavior_schema_sha256", manifest.Get("behavior_schema_sha256"), "classification_sha256", manifest.Get("classification_sha256"),
		"normalizer_version", manifest.Get("normalizer_version"), "normalizer_sha256", manifest.Get("normalizer_sha256"),
		"toolchain_sha256", manifest.Get("toolchain_sha256"), "go_sha256", manifest.Get("go_sha256"),
		"candidates_sha256", candidate.Get("candidates_sha256"), "candidate_manifest_sha256", candidate.Get("manifest_sha256"),
		"launcher_sha256", bashySHA, "payload_sha256", payloadSHA,
	)
	summaryHash := sha256Hex([]byte(Generate(summary)))
	chain := []string{sha256Hex([]byte(Generate(manifest)))}
	for _, r := range records {
		if r.Str("type") == "attempt" {
			chain = append(chain, r.Str("evidence_sha256"))
		}
	}
	chain = append(chain, summaryHash)
	rootDigest := sha256Hex([]byte(strings.Join(chain, "\n")))
	summary.Set("root_digest", rootDigest)
	records = append(records, summary)

	os.MkdirAll(filepath.Dir(results), 0o755)
	dest := results + "." + verdict
	var payload strings.Builder
	for _, r := range records {
		payload.WriteString(Generate(r))
		payload.WriteString("\n")
	}
	temp := dest + ".tmp." + strconv.Itoa(os.Getpid())
	f, err := os.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		fatal(err.Error())
	}
	f.WriteString(payload.String())
	f.Sync()
	f.Close()
	if err := os.Rename(temp, dest); err != nil {
		fatal(err.Error())
	}
	if verdict == "fail" {
		first := ""
		if len(failures) > 0 {
			first = failures[0].(string)
		}
		fatal(fmt.Sprintf("verdict=fail denominator=%d executed=%d missing=%d; first: %s; evidence: %s", denominator, executed, denominator-executed, first, dest))
	}
	fmt.Printf("PASS: verdict=pass denominator=%d executed=%d evidence=%s root_digest=%s\n", denominator, executed, dest, rootDigest)
}

func last(stages []*Object) *Object { return stages[len(stages)-1] }

func envOr(name, fallback string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return fallback
}

func sameSet(a, b []string) bool {
	x := append([]string(nil), a...)
	y := append([]string(nil), b...)
	sort.Strings(x)
	sort.Strings(y)
	return strings.Join(x, "\x00") == strings.Join(y, "\x00") && len(x) == len(y)
}

func mustStat(path string) [2]int64 {
	dev, ino, err := statIdentity(path)
	if err != nil {
		fatal(err.Error())
	}
	return [2]int64{dev, ino}
}

func sameInode(path string, inode int64) bool {
	_, ino, err := statIdentity(path)
	return err == nil && ino == inode
}

// resolveToolchain: the pinned Go toolchain, authenticated by identity, digest,
// release source and native header before it builds or runs anything.
func resolveToolchain(toolpin *Toolchain) *toolchainContext {
	goroot, err := pinnedGoroot(toolpin)
	if err != nil {
		fatal(err.Error())
	}
	goBinary := goroot + "/bin/go"
	identityCmd := exec.Command(goBinary, "version")
	identityCmd.Env = append(envWithout("GOTOOLCHAIN"), "GOTOOLCHAIN=local")
	identity, err := identityCmd.Output()
	if err != nil || strings.TrimSpace(string(identity)) != toolpin.Identity {
		fatal("Go identity mismatch")
	}
	if sha(goBinary) != toolpin.GoSHA256 {
		fatal("Go binary checksum mismatch")
	}
	versionFile, err := os.ReadFile(goroot + "/VERSION")
	if err != nil {
		fatal("Go release source mismatch")
	}
	first := rubyLinesChomp(string(versionFile))
	if len(first) == 0 || strings.TrimSpace(first[0]) != toolpin.Version {
		fatal("Go release source mismatch")
	}
	if !nativeBinary(goBinary) {
		fatal("Go tool is not native")
	}
	modcacheCmd := exec.Command(goBinary, "env", "GOMODCACHE")
	modcacheCmd.Env = append(envWithout("GOTOOLCHAIN"), "GOTOOLCHAIN=local")
	modcacheOut, _ := modcacheCmd.Output()
	gomodcache := strings.TrimSpace(string(modcacheOut))
	if gomodcache == "" || !isDir(gomodcache) {
		fatal("cannot resolve the SDK module cache")
	}
	return &toolchainContext{goroot: goroot, goBinary: goBinary, gomodcache: gomodcache}
}

func envWithout(key string) []string {
	var out []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, key+"=") {
			out = append(out, kv)
		}
	}
	return out
}

// envDivergence: the keys of environment pairs that are not common to every
// mode's profile (profiles.flatten(1).uniq - profiles.reduce(:&)).
func envDivergence(profiles ...[][2]string) []string {
	counts := map[[2]string]int{}
	var order [][2]string
	for _, profile := range profiles {
		seen := map[[2]string]bool{}
		for _, pair := range profile {
			if seen[pair] {
				continue
			}
			seen[pair] = true
			if counts[pair] == 0 {
				order = append(order, pair)
			}
			counts[pair]++
		}
	}
	var keys []string
	seenKey := map[string]bool{}
	for _, pair := range order {
		if counts[pair] != len(profiles) && !seenKey[pair[0]] {
			seenKey[pair[0]] = true
			keys = append(keys, pair[0])
		}
	}
	return keys
}

// normalizePair normalizes both streams of a result; on failure the third
// element carries the error message and ok is false.
func normalizePair(result *runResult, normalizations []string) ([3]string, bool) {
	stdout, err := Normalize(result.stdout, normalizations, "stdout")
	if err != nil {
		return [3]string{"", "", err.Error()}, false
	}
	stderr, err := Normalize(result.stderr, normalizations, "stderr")
	if err != nil {
		return [3]string{"", "", err.Error()}, false
	}
	return [3]string{stdout, stderr, ""}, true
}
