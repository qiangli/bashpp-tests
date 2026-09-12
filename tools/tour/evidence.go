// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// The superseded tour-evidence/v2 runner library — the port of
// tools/tour/evidence.rb (Sprint 98 / Story #4). Its ledger,
// tests/tour/evidence.jsonl, is retained unchanged as historical failure
// evidence and is still validated by `tour validate-evidence` (harness-wired).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const (
	evidenceSchema = "tour-evidence/v2"
)

var (
	evidenceStages   = []string{"transpile", "build", "run"}
	agentBannerRE    = regexp.MustCompile(`(?m)^bashy: .* detected, and this repo has no agent config `)
	bashyIdentityRE  = regexp.MustCompile(`-bashy-(dev|\d[\w.]*)(?:\s+\(([0-9a-f]{7,40})(-dirty)?\))?\z`)
	unsafePathCharRE = regexp.MustCompile(`[^\w./]`)
)

// evidenceNormalize returns the tour-evidence normalized record, which also
// carries the normalized bytes in base64.
func evidenceNormalize(raw []byte) map[string]any {
	out, ok := normalizeV1(raw)
	if !ok {
		return map[string]any{"valid_utf8": false, "bytes": nil, "sha256": nil, "base64": nil}
	}
	return map[string]any{"valid_utf8": true, "bytes": int64(len(out)), "sha256": sha256hex(out), "base64": b64(out)}
}

// EvidenceCapture is TourEvidence.capture's result.
type EvidenceCapture struct {
	Spawned        bool
	State          string
	Exit           any
	Stdout, Stderr []byte
}

// evidenceCapture: every command gets a new process group. On deadline, and
// again after wait, the entire group is swept so descendants cannot retain
// capture descriptors.
func evidenceCapture(argv []string, chdir string, timeout float64, env map[string]string) EvidenceCapture {
	result := EvidenceCapture{Spawned: false, State: "launch_failure", Exit: nil}
	out, err := os.CreateTemp("", "tour-out")
	if err != nil {
		return result
	}
	defer os.Remove(out.Name())
	defer out.Close()
	errf, err := os.CreateTemp("", "tour-err")
	if err != nil {
		return result
	}
	defer os.Remove(errf.Name())
	defer errf.Close()
	devnull, _ := os.Open(os.DevNull)
	defer devnull.Close()

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Path = argv[0]
	cmd.Dir = chdir
	// Like Process.spawn(env, ...) without unsetenv_others: `env` overlays the
	// inherited environment.
	cmd.Env = overlayEnv(env)
	cmd.Stdin = devnull
	cmd.Stdout = out
	cmd.Stderr = errf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(errf, "Errno::ENOENT: %s\n", err.Error())
	} else {
		result.Spawned = true
		pid := cmd.Process.Pid
		deadline := time.Now().Add(time.Duration(timeout * float64(time.Second)))
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
			default:
				if time.Now().After(deadline) {
					result.State = "deadline"
					syscall.Kill(-pid, syscall.SIGTERM)
					time.Sleep(100 * time.Millisecond)
					syscall.Kill(-pid, syscall.SIGKILL)
					<-done
					waited = true
				} else {
					time.Sleep(10 * time.Millisecond)
				}
			}
		}
		if result.State != "deadline" {
			result.State = "exited"
			if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok {
				if ws.Exited() {
					result.Exit = int64(ws.ExitStatus())
				} else if ws.Signaled() {
					result.Exit = int64(128 + int(ws.Signal()))
				}
			}
		}
		syscall.Kill(-pid, syscall.SIGKILL)
	}
	result.Stdout, _ = os.ReadFile(out.Name())
	result.Stderr, _ = os.ReadFile(errf.Name())
	return result
}

func evidenceDerived(stdout, stderr []byte) map[string]any {
	return map[string]any{"stdout": evidenceNormalize(stdout), "stderr": evidenceNormalize(stderr)}
}

func agentBanner(stderr []byte) bool {
	return agentBannerRE.Match(stderr)
}

// evidenceOutcome mirrors TourEvidence.outcome.
func evidenceOutcome(attempt map[string]any, baseline map[string]any) string {
	if !truthy(attempt["spawned"]) {
		return "FAIL:launch_failure"
	}
	if attempt["state"] == "deadline" {
		return "FAIL:deadline"
	}
	if !jsonEqual(attempt["exit"], int64(0)) {
		return "FAIL:exit:" + toS(attempt["exit"])
	}
	if !truthy(dig(attempt, "normalized", "stdout", "valid_utf8")) || !truthy(dig(attempt, "normalized", "stderr", "valid_utf8")) {
		return "FAIL:invalid_utf8"
	}
	if baseline != nil {
		for _, stream := range []string{"stdout", "stderr"} {
			if !jsonEqual(dig(attempt, "normalized", stream, "sha256"), dig(baseline, "normalized", stream, "sha256")) {
				return "FAIL:mismatch"
			}
		}
	}
	return "PASS"
}

// evidenceCommandFor: command construction for the two single-shot modes.
func evidenceCommandFor(mode string, applicability string, bashy, goBin, local string) []string {
	switch mode {
	case "baseline":
		verb := "run"
		if applicability == "build_only_go_program" {
			verb = "build"
		}
		return []string{goBin, verb, local}
	case "interpreted":
		argv := []string{bashy, "--bashpp"}
		if applicability == "build_only_go_program" {
			argv = append(argv, "-n")
		}
		return append(argv, local)
	}
	panic("command_for does not handle mode " + mode)
}

// EvidencePipeline is the compiled pipeline's outcome: the authoritative stage
// and its raw capture.
type EvidencePipeline struct {
	Command map[string]any
	Stage   string
	Raw     EvidenceCapture
}

// evidenceCompiledPipeline: transpile with bashy, build with the exact pinned
// Go, execute the resulting binary. The recorded raw/state/exit belong to
// whichever stage is authoritative.
func evidenceCompiledPipeline(bashy, goBin, source, moduleDir, workdir string, timeout float64, env map[string]string) EvidencePipeline {
	base := strings.TrimSuffix(filepath.Base(source), ".go")
	transpiled := filepath.Join(workdir, base+".transpiled.go")
	binary := filepath.Join(workdir, base+".bin")
	os.Remove(transpiled)
	os.Remove(binary)
	command := map[string]any{
		"transpile": anyList([]string{bashy, "transpile", source, "-o", transpiled}),
		"build":     anyList([]string{goBin, "build", "-o", binary, transpiled}),
		"run":       anyList([]string{binary}),
	}
	transpileRaw := evidenceCapture(strList(command["transpile"]), moduleDir, timeout, env)
	if !(transpileRaw.Spawned && transpileRaw.State == "exited" && jsonEqual(transpileRaw.Exit, int64(0)) && fileExists(transpiled)) {
		return EvidencePipeline{command, "transpile", transpileRaw}
	}
	buildEnv := map[string]string{}
	for k, v := range env {
		buildEnv[k] = v
	}
	buildEnv["GOTOOLCHAIN"] = "local"
	buildRaw := evidenceCapture(strList(command["build"]), moduleDir, timeout, buildEnv)
	if !(buildRaw.Spawned && buildRaw.State == "exited" && jsonEqual(buildRaw.Exit, int64(0)) && isExecutable(binary)) {
		return EvidencePipeline{command, "build", buildRaw}
	}
	runRaw := evidenceCapture(strList(command["run"]), moduleDir, timeout, map[string]string{})
	return EvidencePipeline{command, "run", runRaw}
}

// evidenceMaterializeModule builds the scratch module (go.mod/go.sum for the
// pinned helper, every pinned tour source copied and byte/sha verified) that
// both the runner and the replay validator use.
func evidenceMaterializeModule(modDir, tourRoot string, inventory []Item, goVersion string, helper []string) error {
	if err := os.MkdirAll(modDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(modDir, "go.mod"), []byte(fmt.Sprintf("module tour.evidence.local\n\ngo %s\n\nrequire %s %s\n", strings.TrimPrefix(goVersion, "go"), helper[0], helper[1])), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(modDir, "go.sum"), []byte(fmt.Sprintf("%s %s %s\n%s %s/go.mod %s\n", helper[0], helper[1], helper[4], helper[0], helper[1], helper[3])), 0o644); err != nil {
		return err
	}
	if err := writeReadOnly(filepath.Join(modDir, "AGENTS.md"), []byte("# Hermetic Tour evidence workspace\n")); err != nil {
		return err
	}
	licenseSource := filepath.Join(tourRoot, "LICENSE")
	if !fileExists(licenseSource) {
		return fmt.Errorf("missing upstream LICENSE %s", licenseSource)
	}
	if err := writeReadOnly(filepath.Join(modDir, "LICENSE"), readFile(licenseSource)); err != nil {
		return err
	}
	for _, item := range inventory {
		source := filepath.Join(tourRoot, item.Path)
		st, err := os.Stat(source)
		if err != nil || !st.Mode().IsRegular() {
			return fmt.Errorf("missing source %s", source)
		}
		if st.Mode().Perm() != 0o444 {
			return fmt.Errorf("source mode is not read-only 444: %s", item.Path)
		}
		bytes := readFile(source)
		if int64(len(bytes)) != item.Bytes || sha256hex(bytes) != item.SHA256 {
			return fmt.Errorf("source pin mismatch %s", item.Path)
		}
		local := filepath.Join(modDir, item.Path)
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			return err
		}
		if err := writeReadOnly(local, bytes); err != nil {
			return err
		}
	}
	return nil
}

// bashyIdentity parses `bashy --version` output into a provenance identity.
func bashyIdentity(versionLine string) map[string]any {
	m := bashyIdentityRE.FindStringSubmatch(versionLine)
	if m == nil {
		return map[string]any{"revision": nil, "published": false, "dirty": true}
	}
	tag, commit, dirty := m[1], m[2], m[3]
	if tag == "dev" {
		var rev any
		if commit != "" {
			rev = commit
		}
		return map[string]any{"revision": rev, "published": false, "dirty": true}
	}
	return map[string]any{"revision": tag, "published": true, "dirty": dirty != ""}
}

// evidenceInventory: the executable rows exactly as the evidence tools read them.
func evidenceInventory(path string) ([]Item, string) {
	lines := []string{}
	items := []Item{}
	for _, line := range strings.Split(strings.TrimSuffix(string(readFile(path)), "\n"), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		lines = append(lines, line)
		f := strings.Split(line, "\t")
		if !containsString(executableApplicabilities, field(f, 3)) {
			continue
		}
		items = append(items, Item{Path: field(f, 0), Applicability: field(f, 3), Bytes: mustInt(field(f, 6)), SHA256: field(f, 7)})
	}
	return items, sha256hex([]byte(strings.Join(lines, "\n") + "\n"))
}

func firstDataRow(path string) []string {
	for _, row := range tsvRowsLoose(path) {
		return row
	}
	return nil
}

func hostGoosGoarch() (string, string) {
	goos := strings.ToLower(shellOutput(nil, "uname", "-s"))
	goarch := shellOutput(nil, "uname", "-m")
	return goos, goarch
}

func overlayEnv(env map[string]string) []string {
	merged := map[string]string{}
	for _, kv := range os.Environ() {
		k, v, _ := strings.Cut(kv, "=")
		merged[k] = v
	}
	for k, v := range env {
		merged[k] = v
	}
	return envSlice(merged)
}
