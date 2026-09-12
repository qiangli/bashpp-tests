// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Produces tests/tour/evidence.jsonl (tour-evidence/v2) — the port of
// tools/tour/evidence-runner.rb. Superseded by the three-mode executor; kept
// because its retained ledger is historical failure evidence and its
// validator is harness-wired.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func evidenceCommandInfo(path string, versionArgs ...string) map[string]any {
	if !isExecutable(path) {
		return map[string]any{"path": path, "present": false, "sha256": nil, "version": nil}
	}
	out, _ := combinedOutput(path, versionArgs...)
	real := path
	if r, err := filepath.EvalSymlinks(path); err == nil {
		real, _ = filepath.Abs(r)
	}
	return map[string]any{"path": real, "present": true, "sha256": shaFile(path), "version": strings.TrimSpace(firstLine(out))}
}

func cmdEvidenceRunner(root string) int {
	inventoryFile := envOr("TOUR_INVENTORY", filepath.Join(root, "tests/tour/inventory.tsv"))
	baselineFile := envOr("TOUR_BASE_RESULTS", filepath.Join(root, "tests/tour/results.tsv"))
	output := envOr("TOUR_EVIDENCE", filepath.Join(root, "tests/tour/evidence.jsonl"))
	normalizer := envOr("TOUR_NORMALIZER", filepath.Join(root, normalizerPath))
	timeout := float64(mustInt(envOr("TOUR_STEP_TIMEOUT", "30")))
	bashy, ok := os.LookupEnv("BASHPP_BIN")
	if !ok {
		return abortf("FATAL: BASHPP_BIN must name a clean, published bashy release binary (e.g. the output of `bashy self fetch`); a workspace dev build cannot produce evidence")
	}

	pin := firstDataRow(filepath.Join(root, "docs/tour/pin.tsv"))
	version, inventorySHA := pin[1], pin[7]
	tourRoot := envOr("TOUR_ROOT", filepath.Join(shellOutput(nil, "go", "env", "GOMODCACHE"), "golang.org/x/website@"+version))
	tc := firstDataRow(filepath.Join(root, "docs/tour/toolchain.tsv"))
	goBin := filepath.Join(shellOutput(map[string]string{"GOTOOLCHAIN": tc[2]}, "go", "env", "GOROOT"), "bin/go")

	inventory, _ := evidenceInventory(inventoryFile)
	if len(inventory) != 97 {
		return abortf("FATAL: executable inventory must contain exactly 97 programs")
	}
	baselineRows := map[string][]string{}
	for _, f := range tsvRowsLoose(baselineFile) {
		baselineRows[field(f, 0)] = f
	}

	goInfo := evidenceCommandInfo(goBin, "version")
	goInfo["identity"] = tc[3]
	goInfo["pinned_sha256"] = tc[4]
	if !truthy(goInfo["present"]) {
		return abortf("FATAL: exact Go 1.27 binary unavailable at %s", goBin)
	}
	if goInfo["version"] != tc[3] {
		return abortf("FATAL: Go binary is not the pinned toolchain (identity %s, expected %s)", toS(goInfo["version"]), tc[3])
	}
	if goInfo["sha256"] != tc[4] {
		return abortf("FATAL: Go binary checksum does not match docs/tour/toolchain.tsv pin")
	}

	bashyRaw := evidenceCommandInfo(bashy, "--version")
	if !truthy(bashyRaw["present"]) {
		return abortf("FATAL: bashy binary unavailable at %s", bashy)
	}
	identity := bashyIdentity(asString(bashyRaw["version"]))
	if !(truthy(identity["published"]) && !truthy(identity["dirty"])) {
		return abortf("FATAL: bashy build is dirty or unpublished (%s) — evidence requires a clean published release, e.g. `bashy self fetch`", inspectString(asString(bashyRaw["version"])))
	}
	bashyInfo := map[string]any{}
	for k, v := range bashyRaw {
		bashyInfo[k] = v
	}
	bashyInfo["source_revision"] = identity["revision"]
	bashyInfo["published"] = identity["published"]
	bashyInfo["reproducible"] = truthy(identity["published"]) && !truthy(identity["dirty"])
	bashyInfo["build_recipe"] = "bashy self fetch --version " + toS(identity["revision"])

	normalizerRel, _ := filepath.Rel(root, normalizer)
	manifest := map[string]any{
		"type": "manifest", "schema": evidenceSchema,
		"inventory": map[string]any{"path": "tests/tour/inventory.tsv", "executable_programs": int64(97), "data_sha256": inventorySHA},
		"baseline": map[string]any{"accepted_results": "tests/tour/results.tsv", "accepted_results_sha256": shaFile(baselineFile),
			"pin": "docs/tour/baseline-pin.tsv", "pin_sha256": shaFile(filepath.Join(root, "docs/tour/baseline-pin.tsv"))},
		"go":    goInfo,
		"bashy": bashyInfo,
		"normalizer": map[string]any{"path": filepath.ToSlash(normalizerRel), "version": normalizerVersion,
			"sha256": shaFile(normalizer)},
		"attempts": int64(291),
	}

	records := []map[string]any{manifest}
	work, err := os.MkdirTemp("", "tour-evidence")
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	defer os.RemoveAll(work)
	mod := filepath.Join(work, "module")
	helper := firstDataRow(filepath.Join(root, "docs/tour/helpers.tsv"))
	if err := evidenceMaterializeModule(mod, tourRoot, inventory, tc[2], helper); err != nil {
		return abortf("FATAL: %v", err)
	}

	for _, item := range inventory {
		local := filepath.Join(mod, item.Path)
		compiledDir := filepath.Join(work, "compiled", unsafePathCharRE.ReplaceAllString(item.Path, "_"))
		os.MkdirAll(compiledDir, 0o755)
		var baselineAttempt map[string]any
		for _, mode := range modes {
			env := map[string]string{"GOTOOLCHAIN": "local", "BASHY_HINTS": "off"}
			var command any
			var stage string
			var raw EvidenceCapture
			if mode == "compiled" {
				pipeline := evidenceCompiledPipeline(bashy, goBin, local, mod, compiledDir, timeout, env)
				command, stage, raw = pipeline.Command, pipeline.Stage, pipeline.Raw
			} else {
				argv := evidenceCommandFor(mode, item.Applicability, bashy, goBin, local)
				command, stage = anyList(argv), "run"
				raw = evidenceCapture(argv, mod, timeout, env)
			}
			if agentBanner(raw.Stderr) {
				return abortf("FATAL: agent-specific Bashy advertisement entered %s %s evidence", item.Path, mode)
			}
			attempt := map[string]any{
				"type": "attempt", "path": item.Path, "applicability": item.Applicability, "mode": mode,
				"source": map[string]any{"bytes": item.Bytes, "sha256": item.SHA256}, "command": command, "stage": stage,
				"spawned": raw.Spawned, "state": raw.State, "exit": raw.Exit,
				"raw":        map[string]any{"stdout_base64": b64(raw.Stdout), "stderr_base64": b64(raw.Stderr)},
				"normalized": evidenceDerived(raw.Stdout, raw.Stderr),
			}
			var base map[string]any
			if mode != "baseline" {
				base = baselineAttempt
			}
			attempt["outcome"] = evidenceOutcome(attempt, base)
			if mode == "baseline" {
				accepted := baselineRows[item.Path]
				buildOnly := item.Applicability == "build_only_go_program"
				expected := expectedAccepted(accepted, buildOnly)
				attempt["accepted_observation"] = expected
				authentic := jsonEqual(attempt["exit"], expected["exit"])
				if buildOnly {
					authentic = authentic && len(raw.Stdout) == 0 && len(raw.Stderr) == 0
				} else {
					authentic = authentic && jsonEqual(dig(attempt, "normalized", "stdout", "bytes"), expected["stdout_bytes"]) &&
						jsonEqual(dig(attempt, "normalized", "stdout", "sha256"), expected["stdout_sha256"]) &&
						jsonEqual(dig(attempt, "normalized", "stderr", "bytes"), expected["stderr_bytes"]) &&
						jsonEqual(dig(attempt, "normalized", "stderr", "sha256"), expected["stderr_sha256"])
				}
				attempt["accepted_observation_matches"] = authentic
				baselineAttempt = attempt
			}
			records = append(records, attempt)
		}
	}

	counts := countBy(records[1:], "outcome")
	summary := map[string]any{"type": "summary", "attempts": int64(291), "programs": int64(97), "modes": anyList(modes), "outcomes": counts}
	records = append(records, summary)
	rootRecord := map[string]any{"type": "root", "algorithm": "sha256-canonical-jsonl", "sha256": ledgerRoot(records)}
	records = append(records, rootRecord)
	value := "FAIL"
	if jsonEqual(counts, map[string]any{"PASS": int64(291)}) {
		value = "PASS"
	}
	records = append(records, map[string]any{"type": "verdict", "value": value, "root_sha256": rootRecord["sha256"]})
	if err := writeLedger(output, records); err != nil {
		return abortf("FATAL: %v", err)
	}
	fmt.Printf("Tour evidence %s: 97 programs x 3 modes = 291 attempts; root %s\n", value, rootRecord["sha256"])
	return 0
}

// expectedAccepted renders the accepted-observation record from a
// tests/tour/results.tsv row.
func expectedAccepted(row []string, buildOnly bool) map[string]any {
	exitField := 7
	if buildOnly {
		exitField = 6
	}
	expected := map[string]any{"exit": mustInt(field(row, exitField)),
		"stdout_bytes": nil, "stdout_sha256": nil, "stderr_bytes": nil, "stderr_sha256": nil}
	if !buildOnly {
		expected["stdout_bytes"] = mustInt(field(row, 8))
		expected["stdout_sha256"] = field(row, 9)
		expected["stderr_bytes"] = mustInt(field(row, 10))
		expected["stderr_sha256"] = field(row, 11)
	}
	return expected
}
