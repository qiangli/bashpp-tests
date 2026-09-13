// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// tour-evidence/v2 validator — the port of tools/tour/evidence-validator.rb.
// Two independent layers, neither of which trusts the producer:
//
//  1. STRUCTURAL — every field is re-derived from data the validator itself
//     reads (inventory, accepted baseline, pin files, normalizer) and must
//     match what the ledger claims.
//  2. REPLAY — every attempt's command is re-executed against a freshly
//     materialized module with the exact pinned Go binary and the exact bashy
//     binary named in the manifest; the fresh spawn/state/exit and (for the
//     two Bash++ modes) the fresh normalized output must match the record.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func cmdEvidenceValidator(root string) int {
	file := envOr("TOUR_EVIDENCE", filepath.Join(root, "tests/tour/evidence.jsonl"))
	normalizer := envOr("TOUR_NORMALIZER", filepath.Join(root, normalizerPath))
	if !fileExists(file) {
		return abortf("FATAL: missing evidence %s", file)
	}
	records, err := readLedger(file)
	if err != nil {
		if strings.HasPrefix(err.Error(), "non-canonical") {
			return abortf("FATAL: %s", strings.Replace(err.Error(), "non-canonical JSON on line", "non-canonical JSON line", 1))
		}
		return abortf("FATAL: %v", err)
	}
	if len(records) < 4 {
		return abortf("FATAL: malformed evidence envelope")
	}
	manifest, verdict := records[0], records[len(records)-1]
	if !(manifest["type"] == "manifest" && records[len(records)-3]["type"] == "summary" && records[len(records)-2]["type"] == "root" && verdict["type"] == "verdict") {
		return abortf("FATAL: malformed evidence envelope")
	}
	if manifest["schema"] != evidenceSchema {
		return abortf("FATAL: schema mismatch")
	}
	// The normalizer binding: the on-disk Go implementation, or the retired
	// Ruby script's frozen digest for a ledger sealed before the port.
	normalizerOK := jsonEqual(dig(manifest, "normalizer", "sha256"), shaFile(normalizer)) ||
		(dig(manifest, "normalizer", "path") == retiredRubyNormalizerPath && jsonEqual(dig(manifest, "normalizer", "sha256"), retiredRubyNormalizerSHA256))
	if !normalizerOK {
		return abortf("FATAL: normalizer checksum mismatch")
	}

	inventoryFile := filepath.Join(root, toS(dig(manifest, "inventory", "path")))
	items, dataSHA := evidenceInventory(inventoryFile)
	inventory := map[string]Item{}
	for _, item := range items {
		inventory[item.Path] = item
	}
	if !(len(inventory) == 97 && jsonEqual(dig(manifest, "inventory", "executable_programs"), int64(97)) && dig(manifest, "inventory", "data_sha256") == dataSHA) {
		return abortf("FATAL: manifest inventory binding mismatch")
	}

	baseFile := filepath.Join(root, toS(dig(manifest, "baseline", "accepted_results")))
	pinFile := filepath.Join(root, toS(dig(manifest, "baseline", "pin")))
	if !jsonEqual(shaFile(baseFile), dig(manifest, "baseline", "accepted_results_sha256")) {
		return abortf("FATAL: accepted baseline file binding mismatch")
	}
	if !jsonEqual(shaFile(pinFile), dig(manifest, "baseline", "pin_sha256")) {
		return abortf("FATAL: baseline pin binding mismatch")
	}
	validate := exec.Command(filepath.Join(root, "tools/tour/validate-results.sh"))
	validate.Env = append(os.Environ(), "TOUR_RESULTS="+baseFile)
	validate.Stdout = nil
	validate.Stderr = os.Stderr
	if err := validate.Run(); err != nil {
		return abortf("FATAL: accepted baseline observations fail their independent validator")
	}
	baselineLedger := map[string][]string{}
	for _, f := range tsvRowsLoose(baseFile) {
		baselineLedger[field(f, 0)] = f
	}

	// --- exact Go 1.27 builder: cross-checked against the pin file
	pinRow := firstDataRow(filepath.Join(root, "docs/tour/pin.tsv"))
	tourVersion := pinRow[1]
	helperRow := firstDataRow(filepath.Join(root, "docs/tour/helpers.tsv"))
	goos, goarch := hostGoosGoarch()
	var tcRow []string
	for _, f := range tsvRowsLoose(filepath.Join(root, "docs/tour/toolchain.tsv")) {
		if field(f, 0) == goos && field(f, 1) == goarch {
			tcRow = f
			break
		}
	}
	if tcRow == nil {
		return abortf("FATAL: no pinned Go toolchain row for %s/%s in docs/tour/toolchain.tsv", goos, goarch)
	}
	tcVersion, tcIdentity, tcSHA := tcRow[2], tcRow[3], tcRow[4]

	goInfo := asMap(manifest["go"])
	goPath := toS(goInfo["path"])
	if !(truthy(goInfo["present"]) && isExecutable(goPath)) {
		return abortf("FATAL: exact Go binary unavailable")
	}
	if shaFile(goPath) != toS(goInfo["sha256"]) {
		return abortf("FATAL: exact Go binary checksum mismatch")
	}
	if shellOutput(nil, goPath, "version") != toS(goInfo["identity"]) {
		return abortf("FATAL: exact Go identity mismatch")
	}
	if toS(goInfo["identity"]) != tcIdentity {
		return abortf("FATAL: Go builder is not the pinned Go 1.27 toolchain (manifest identity %s, pinned %s)", toS(goInfo["identity"]), tcIdentity)
	}
	if !(toS(goInfo["sha256"]) == tcSHA && toS(goInfo["pinned_sha256"]) == tcSHA) {
		return abortf("FATAL: Go builder checksum is not the pinned Go 1.27 toolchain (manifest %s, pinned %s)", toS(goInfo["sha256"]), tcSHA)
	}

	// --- clean published reproducible bashy: re-derived from the LIVE binary
	bashy := asMap(manifest["bashy"])
	bashyPath := toS(bashy["path"])
	if !(truthy(bashy["present"]) && isExecutable(bashyPath)) {
		return abortf("FATAL: bashy binary unavailable")
	}
	if shaFile(bashyPath) != toS(bashy["sha256"]) {
		return abortf("FATAL: exact bashy executable checksum mismatch")
	}
	liveOut, _ := exec.Command(bashyPath, "--version").Output()
	liveBashyVersion := strings.TrimSpace(firstLine(string(liveOut)))
	if liveBashyVersion != toS(bashy["version"]) {
		return abortf("FATAL: exact bashy version mismatch — manifest claims %s, live binary reports %s", inspectString(toS(bashy["version"])), inspectString(liveBashyVersion))
	}
	identity := bashyIdentity(liveBashyVersion)
	if !(truthy(identity["published"]) && !truthy(identity["dirty"])) {
		return abortf("FATAL: bashy build is dirty or unpublished (%s) — a workspace/dirty build is not clean published reproducible evidence", inspectString(toS(bashy["version"])))
	}
	if !jsonEqual(bashy["source_revision"], identity["revision"]) {
		return abortf("FATAL: bashy source_revision does not match its own version string")
	}
	if bashy["published"] != true {
		return abortf("FATAL: bashy published flag does not match its own version string")
	}
	if bashy["reproducible"] != true {
		return abortf("FATAL: bashy reproducible flag does not match its own version string")
	}

	attempts := records[1 : len(records)-3]
	if !(len(attempts) == 291 && jsonEqual(manifest["attempts"], int64(291))) {
		return abortf("FATAL: coverage must be exactly 97 x 3 = 291")
	}
	type key struct{ path, mode string }
	seen := map[key]bool{}
	baselines := map[string]map[string]any{}
	recomputedCounts := map[string]any{}
	for _, attempt := range attempts {
		path, mode := asString(attempt["path"]), asString(attempt["mode"])
		k := key{path, mode}
		item, known := inventory[path]
		if !(known && containsString(modes, mode) && !seen[k]) {
			return abortf("FATAL: unexpected or duplicate attempt %s %s", path, mode)
		}
		seen[k] = true
		expectedSource := map[string]any{"bytes": item.Bytes, "sha256": item.SHA256}
		if !(attempt["applicability"] == item.Applicability && jsonEqual(attempt["source"], expectedSource)) {
			return abortf("FATAL: inventory/source mismatch %s %s", path, mode)
		}
		if !containsString(evidenceStages, asString(attempt["stage"])) {
			return abortf("FATAL: unknown pipeline stage %s %s", path, mode)
		}
		command := attempt["command"]
		if mode != "baseline" && baselines[path] != nil && jsonEqual(command, baselines[path]["command"]) {
			return abortf("FATAL: synthetic mutual-equality artifact %s %s", path, mode)
		}
		switch mode {
		case "baseline":
			argv, isList := command.([]any)
			if !isList || len(argv) == 0 {
				return abortf("FATAL: unbound command %s %s", path, mode)
			}
			if expandPath(asString(argv[0])) != expandPath(goPath) {
				return abortf("FATAL: baseline did not use exact Go %s", path)
			}
			if attempt["stage"] != "run" {
				return abortf("FATAL: baseline stage must be run %s", path)
			}
		case "interpreted":
			argv, isList := command.([]any)
			if !isList || len(argv) == 0 {
				return abortf("FATAL: unbound command %s %s", path, mode)
			}
			if !(asString(argv[0]) == bashyPath && containsString(strList(argv), "--bashpp")) {
				return abortf("FATAL: interpreted command binding %s", path)
			}
			if attempt["stage"] != "run" {
				return abortf("FATAL: interpreted stage must be run %s", path)
			}
		case "compiled":
			pipeline, isMap := command.(map[string]any)
			if !isMap || !equalStrings(sortedKeys(pipeline), []string{"build", "run", "transpile"}) {
				return abortf("FATAL: unbound compiled pipeline %s", path)
			}
			transpile := strList(pipeline["transpile"])
			if !(len(transpile) > 0 && transpile[0] == bashyPath && containsString(transpile, "transpile")) {
				return abortf("FATAL: compiled transpile binding %s", path)
			}
			build := strList(pipeline["build"])
			if !(len(build) > 0 && build[0] == goPath && containsString(build, "build")) {
				return abortf("FATAL: compiled build binding %s", path)
			}
			runArgv, isRunList := pipeline["run"].([]any)
			if !isRunList || len(runArgv) != 1 {
				return abortf("FATAL: compiled run binding %s", path)
			}
		}
		stdout, okOut := strictB64(toS(dig(attempt, "raw", "stdout_base64")))
		stderr, okErr := strictB64(toS(dig(attempt, "raw", "stderr_base64")))
		if !okOut || !okErr {
			return abortf("FATAL: invalid base64 in raw streams %s %s", path, mode)
		}
		if agentBanner(stderr) {
			return abortf("FATAL: agent-specific Bashy advertisement in evidence %s %s", path, mode)
		}
		derived := evidenceDerived(stdout, stderr)
		if !jsonEqual(attempt["normalized"], derived) {
			return abortf("FATAL: normalized fields not derived from raw streams %s %s", path, mode)
		}
		var calculated string
		if mode == "baseline" {
			row := baselineLedger[path]
			buildOnly := item.Applicability == "build_only_go_program"
			expected := expectedAccepted(row, buildOnly)
			if !jsonEqual(attempt["accepted_observation"], expected) {
				return abortf("FATAL: baseline accepted observation copied or altered %s", path)
			}
			authentic := jsonEqual(attempt["exit"], expected["exit"])
			if buildOnly {
				authentic = authentic && len(stdout) == 0 && len(stderr) == 0
			} else {
				authentic = authentic && jsonEqual(dig(derived, "stdout", "bytes"), expected["stdout_bytes"]) &&
					jsonEqual(dig(derived, "stdout", "sha256"), expected["stdout_sha256"]) &&
					jsonEqual(dig(derived, "stderr", "bytes"), expected["stderr_bytes"]) &&
					jsonEqual(dig(derived, "stderr", "sha256"), expected["stderr_sha256"])
			}
			if !jsonEqual(attempt["accepted_observation_matches"], authentic) {
				return abortf("FATAL: accepted baseline match flag is not derived %s", path)
			}
			calculated = evidenceOutcome(attempt, nil)
			baselines[path] = attempt
		} else {
			if baselines[path] == nil {
				return abortf("FATAL: mode precedes its baseline %s", path)
			}
			calculated = evidenceOutcome(attempt, baselines[path])
		}
		if attempt["outcome"] != calculated {
			return abortf("FATAL: derived outcome mismatch %s %s", path, mode)
		}
		recomputedCounts[calculated] = toI(recomputedCounts[calculated]) + 1
	}
	for path := range inventory {
		for _, mode := range modes {
			if !seen[key{path, mode}] {
				return abortf("FATAL: missing attempt %s %s", path, mode)
			}
		}
	}
	summary := records[len(records)-3]
	expectedSummary := map[string]any{"type": "summary", "attempts": int64(291), "programs": int64(97), "modes": anyList(modes), "outcomes": recomputedCounts}
	if !jsonEqual(summary, expectedSummary) {
		return abortf("FATAL: summary mismatch")
	}
	calculatedRoot := ledgerRoot(records[:len(records)-2])
	if !jsonEqual(records[len(records)-2], map[string]any{"type": "root", "algorithm": "sha256-canonical-jsonl", "sha256": calculatedRoot}) {
		return abortf("FATAL: evidence root mismatch")
	}
	expectedVerdict := "FAIL"
	if jsonEqual(recomputedCounts, map[string]any{"PASS": int64(291)}) {
		expectedVerdict = "PASS"
	}
	if !jsonEqual(verdict, map[string]any{"type": "verdict", "value": expectedVerdict, "root_sha256": calculatedRoot}) {
		return abortf("FATAL: verdict mismatch")
	}

	// -------------------------------------------------------------------
	// PROCESS PHASE — replay authentication.
	// -------------------------------------------------------------------
	timeout := float64(mustInt(envOr("TOUR_STEP_TIMEOUT", "30")))
	tourRoot := envOr("TOUR_ROOT", filepath.Join(shellOutput(nil, "go", "env", "GOMODCACHE"), "golang.org/x/website@"+tourVersion))
	work, err := os.MkdirTemp("", "tour-evidence-replay")
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	defer os.RemoveAll(work)
	mod := filepath.Join(work, "module")
	if err := evidenceMaterializeModule(mod, tourRoot, items, tcVersion, helperRow); err != nil {
		return abortf("FATAL: cannot materialize replay module: %v", err)
	}
	for _, attempt := range attempts {
		path, mode := asString(attempt["path"]), asString(attempt["mode"])
		item := inventory[path]
		local := filepath.Join(mod, path)
		env := map[string]string{"GOTOOLCHAIN": "local", "BASHY_HINTS": "off"}
		var fresh EvidenceCapture
		if mode == "compiled" {
			compiledDir := filepath.Join(work, "compiled", unsafePathCharRE.ReplaceAllString(path, "_"))
			os.MkdirAll(compiledDir, 0o755)
			pipeline := evidenceCompiledPipeline(bashyPath, goPath, local, mod, compiledDir, timeout, env)
			if pipeline.Stage != asString(attempt["stage"]) {
				return abortf("FATAL: replay pipeline stage mismatch %s %s (recorded %s, replay %s)", path, mode, toS(attempt["stage"]), pipeline.Stage)
			}
			fresh = pipeline.Raw
		} else {
			fresh = evidenceCapture(evidenceCommandFor(mode, item.Applicability, bashyPath, goPath, local), mod, timeout, env)
		}
		freshNormalized := evidenceDerived(fresh.Stdout, fresh.Stderr)
		controlMatch := jsonEqual(fresh.Spawned, attempt["spawned"]) && fresh.State == asString(attempt["state"]) && jsonEqual(fresh.Exit, attempt["exit"])
		if !controlMatch {
			return abortf("FATAL: replay spawn/state/exit not reproduced %s %s (recorded exit=%s state=%s, replay exit=%s state=%s)",
				path, mode, toS(attempt["exit"]), toS(attempt["state"]), toS(fresh.Exit), fresh.State)
		}
		bytesMatch := true
		for _, stream := range []string{"stdout", "stderr"} {
			if !jsonEqual(dig(freshNormalized, stream, "sha256"), dig(attempt, "normalized", stream, "sha256")) {
				bytesMatch = false
			}
		}
		if bytesMatch || mode == "baseline" {
			continue
		}
		return abortf("FATAL: replay raw-output mismatch %s %s — recorded observation was not reproduced by executing its own bound command", path, mode)
	}

	fmt.Printf("Tour evidence VALID %s: 97 programs x 3 modes = 291; root %s; replay-authenticated\n", expectedVerdict, calculatedRoot)
	return 0
}

func expandPath(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	return abs
}
