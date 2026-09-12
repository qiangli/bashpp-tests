// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Produces tests/tour/executor-results.jsonl — the tour-executor/v2 ledger.
// Port of tools/tour/executor-runner.rb (Sprint 118 / Story #4 / Story-ID
// 759341a95870).
//
// Runs every one of the 97 pinned executable tour programs (93 applicable +
// 4 build-only) in all three declared modes and records exit status, raw
// stdout/stderr, explicit normalization, per-stage artifacts and provenance.
// It never invents a result: an unimplemented product selector produces a
// recorded FAILURE, never a skip, a PLANNED row or a not-applicable.
//
// For the rows docs/tour/semantics.tsv declares volatile, the runner also
// collects an ORACLE — repeated observations of the very native binary the
// baseline stage just built — and adjudicates all three modes with the
// reviewed comparator against those repeats.
//
// Environment:
//
//	BASHPP_BIN                 candidate bashy launcher (required)
//	TOUR_CANDIDATE_MANIFEST    manager-supplied build manifest JSON (required)
//	TOUR_CORPUS_ROOT           committed corpus root (default: <repo>/tour)
//	TOUR_EXECUTOR_RESULTS      output ledger path
//	TOUR_EXECUTOR_EVIDENCE     durable root for raw capture logs and artifacts
//	TOUR_ORACLE_REPEATS        native repeats per volatile row (default 7)
//	TOUR_STEP_TIMEOUT          per-stage timeout in seconds (default 60)
//	TOUR_ONLY                  substring filter; marks the ledger partial,
//	                           which the gate rejects
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const toolchainPath = "/usr/bin:/bin"

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FATAL: "+format+"\n", args...)
	os.Exit(1)
}

// baseEnv: GOROOT names the pinned SDK and is supplied IDENTICALLY to all
// three modes. It is toolchain configuration, not a source-access grant.
func baseEnv(home, tmp, gomodcache, gocache, goproxy, goroot string) map[string]string {
	return map[string]string{
		"HOME": home, "TMPDIR": tmp, "LC_ALL": "C",
		"GOMAXPROCS": "2", "GOROOT": goroot, "GOTOOLCHAIN": "local", "GOFLAGS": "-mod=mod", "GOPROXY": goproxy,
		"GOMODCACHE": gomodcache, "GOCACHE": gocache, "GOPATH": filepath.Join(home, "go"),
		"BASHY_HINTS": "off", "BASHY_AGENTIC": "",
	}
}

func withPath(env map[string]string, path string) map[string]string {
	out := map[string]string{}
	for k, v := range env {
		out[k] = v
	}
	out["PATH"] = path
	return out
}

type materializeSpec struct {
	corpusRoot string
	corpus     []string
	items      []Item
	goVersion  string
	helper     []string
	runtimeDep map[string]any
}

// materialize builds one fresh, read-only module tree: go.mod/go.sum for the
// official helper module, the upstream LICENSE, and every pinned source
// verified byte-for-byte against its inventory row on the way in.
func materialize(modDir string, spec materializeSpec) error {
	if err := os.MkdirAll(modDir, 0o755); err != nil {
		return err
	}
	moduleText := fmt.Sprintf("module tour.executor.local\n\ngo %s\n\nrequire %s %s\n", strings.TrimPrefix(spec.goVersion, "go"), spec.helper[0], spec.helper[1])
	moduleText += fmt.Sprintf("require %s %s\n", asString(spec.runtimeDep["module"]), asString(spec.runtimeDep["require_version"]))
	moduleText += fmt.Sprintf("replace %s => %s\n", asString(spec.runtimeDep["module"]), canonical(spec.runtimeDep["dir"]))
	if err := os.WriteFile(filepath.Join(modDir, "go.mod"), []byte(moduleText), 0o644); err != nil {
		return err
	}
	sum := fmt.Sprintf("%s %s %s\n%s %s/go.mod %s\n", spec.helper[0], spec.helper[1], spec.helper[4], spec.helper[0], spec.helper[1], spec.helper[3])
	if err := os.WriteFile(filepath.Join(modDir, "go.sum"), []byte(sum), 0o644); err != nil {
		return err
	}
	// A deterministic agent-config marker keeps bashy's one-time startup
	// advertisement out of evidence. Not Go source; alters no program under test.
	if err := os.WriteFile(filepath.Join(modDir, "AGENTS.md"), []byte("# Hermetic tour executor workspace\n"), 0o644); err != nil {
		return err
	}
	licenseRel := strings.TrimPrefix(spec.corpus[1], spec.corpus[0]+"/")
	licenseSource := filepath.Join(spec.corpusRoot, licenseRel)
	if !fileExists(licenseSource) {
		return fmt.Errorf("missing upstream LICENSE %s", licenseSource)
	}
	license := readFile(licenseSource)
	if int64(len(license)) != mustInt(spec.corpus[2]) {
		return fmt.Errorf("LICENSE byte count does not match docs/tour/corpus.tsv")
	}
	if sha256hex(license) != spec.corpus[3] {
		return fmt.Errorf("LICENSE sha256 does not match docs/tour/corpus.tsv")
	}
	if err := writeReadOnly(filepath.Join(modDir, "LICENSE"), license); err != nil {
		return err
	}
	for _, item := range spec.items {
		source := filepath.Join(spec.corpusRoot, item.Path)
		if !fileExists(source) {
			return fmt.Errorf("missing pinned source %s", source)
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
		if sha256hex(readFile(local)) != item.SHA256 {
			return fmt.Errorf("copy drift %s", item.Path)
		}
	}
	return nil
}

func writeReadOnly(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return err
	}
	return os.Chmod(path, 0o444)
}

// verifySources re-verifies every original source after a mode has run.
func verifySources(modDir, corpusRoot string, items []Item) error {
	for _, item := range items {
		for _, path := range []string{filepath.Join(modDir, item.Path), filepath.Join(corpusRoot, item.Path)} {
			if !fileExists(path) {
				return fmt.Errorf("source disappeared: %s", path)
			}
			if sha256hex(readFile(path)) != item.SHA256 {
				return fmt.Errorf("SOURCE MUTATED during run: %s", path)
			}
		}
	}
	return nil
}

func stageRecord(spec Stage, argv []string, raw *RunResult, subs map[string]string, cwdLabel, pathEnv string) map[string]any {
	artifactRecords := map[string]any{}
	for _, name := range spec.Produces {
		path := subs[artifactKey[name]]
		record := artifactRecord(path)
		record["path"] = filepath.Base(path)
		if name == "map" {
			record["source_map"] = sourceMapSummary(path)
		}
		artifactRecords[name] = record
	}
	normalized := map[string]any{"stdout": normalize(raw.Stdout), "stderr": normalize(raw.Stderr)}
	inputs := raw.InputArtifacts
	if inputs == nil {
		inputs = map[string]any{}
	}
	record := map[string]any{
		"index": spec.Index, "stage": spec.Stage, "execute_body": spec.ExecuteBody,
		"command": anyList(argv), "cwd": cwdLabel, "path_env": pathEnv,
		"spawned": raw.Spawned, "state": raw.State, "exit": raw.Exit, "signal": raw.Signal,
		"descendants_survived": raw.DescendantsSurvived, "duration_ms": raw.DurationMS,
		"started_at": raw.StartedAt, "finished_at": raw.FinishedAt,
		"artifacts": artifactRecords, "inputs": inputs,
		"raw": map[string]any{"stdout_base64": b64(raw.Stdout), "stdout_bytes": int64(len(raw.Stdout)),
			"stderr_base64": b64(raw.Stderr), "stderr_bytes": int64(len(raw.Stderr))},
		"logs":       map[string]any{"stdout_sha256": dig(raw.Logs, "stdout", "sha256"), "stderr_sha256": dig(raw.Logs, "stderr", "sha256")},
		"normalized": normalized,
		"masking": map[string]any{"stdout": maskingReport(raw.Stdout, asMap(normalized["stdout"])["bytes"]),
			"stderr": maskingReport(raw.Stderr, asMap(normalized["stderr"])["bytes"])},
	}
	if spec.ExecuteBody {
		record["input_absence"] = map[string]any{"scope": inputAbsenceScope, "cwd": cwdLabel, "path_env": pathEnv, "os_sandbox": false}
	}
	return record
}

func unreachedStage(spec Stage, argv []string, subs map[string]string) map[string]any {
	artifacts := map[string]any{}
	for _, name := range spec.Produces {
		artifacts[name] = map[string]any{"present": false, "bytes": nil, "sha256": nil, "path": filepath.Base(subs[artifactKey[name]])}
	}
	empty := sha256hex(nil)
	return map[string]any{
		"index": spec.Index, "stage": spec.Stage, "execute_body": spec.ExecuteBody,
		"command": anyList(argv), "cwd": nil, "path_env": nil,
		"inputs":  map[string]any{},
		"spawned": false, "state": "not_reached", "exit": nil, "signal": nil,
		"descendants_survived": false, "duration_ms": int64(0), "started_at": nil, "finished_at": nil,
		"artifacts": artifacts,
		"raw":       map[string]any{"stdout_base64": "", "stdout_bytes": int64(0), "stderr_base64": "", "stderr_bytes": int64(0)},
		"logs":      map[string]any{"stdout_sha256": nil, "stderr_sha256": nil},
		"normalized": map[string]any{"stdout": map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": empty},
			"stderr": map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": empty}},
		"masking": map[string]any{"stdout": maskingReport(nil, int64(0)), "stderr": maskingReport(nil, int64(0))},
	}
}

func decodeOracle(runs []any) []Observation {
	out := []Observation{}
	for _, r := range runs {
		run := asMap(r)
		out = append(out, Observation{Exit: run["exit"], Stdout: string(b64decode(asString(run["stdout_base64"]))),
			Stderr: string(b64decode(asString(run["stderr_base64"])))})
	}
	return out
}

func candidateStreams(final map[string]any) Observation {
	return Observation{Exit: final["exit"], Stdout: string(b64decode(toS(dig(final, "raw", "stdout_base64")))),
		Stderr: string(b64decode(toS(dig(final, "raw", "stderr_base64"))))}
}

func cmdExecutor(root string) int {
	contractPath := filepath.Join(root, "docs/tour/executor-contract.tsv")
	candidatePath := filepath.Join(root, "docs/tour/candidate.tsv")
	migrationPath := filepath.Join(root, "docs/tour/phase-migration.tsv")
	semanticsPath := filepath.Join(root, "docs/tour/semantics.tsv")
	volatilityPath := filepath.Join(root, "docs/tour/volatility.tsv")
	inventoryPath := envOr("TOUR_INVENTORY", filepath.Join(root, "tests/tour/inventory.tsv"))
	acceptedPath := envOr("TOUR_BASE_RESULTS", filepath.Join(root, "tests/tour/results.tsv"))
	output := envOr("TOUR_EXECUTOR_RESULTS", filepath.Join(root, "tests/tour/executor-results.jsonl"))
	corpusRoot := envOr("TOUR_CORPUS_ROOT", filepath.Join(root, "tour"))
	timeout := float64(mustInt(envOr("TOUR_STEP_TIMEOUT", "60")))
	oracleRepeats := int(mustInt(envOr("TOUR_ORACLE_REPEATS", "7")))
	only, partial := os.LookupEnv("TOUR_ONLY")

	contract, err := loadContract(contractPath)
	if err != nil {
		die("%v", err)
	}
	migration, err := loadPhaseMigration(migrationPath)
	if err != nil {
		die("%v", err)
	}
	inventory, err := loadInventory(inventoryPath)
	if err != nil {
		die("%v", err)
	}
	items := inventory.Items
	if len(items) != denominator {
		die("executable denominator must be %d rows, got %d", denominator, len(items))
	}
	applicable, buildOnly := 0, 0
	for _, item := range items {
		if item.Applicability == "applicable_go_program" {
			applicable++
		} else {
			buildOnly++
		}
	}
	if applicable != applicableRows || buildOnly != buildOnlyRows {
		die("denominator split must be %d+%d, got %d+%d", applicableRows, buildOnlyRows, applicable, buildOnly)
	}
	accepted := loadAccepted(acceptedPath)

	if failures := phaseMigrationFailures(migration, contract, items); len(failures) > 0 {
		die("phase migration is inconsistent: %s", strings.Join(failures, ", "))
	}

	byPath := map[string]string{}
	for _, item := range items {
		byPath[item.Path] = item.SHA256
	}
	semantics, err := loadSemanticsTable(semanticsPath, byPath)
	if err != nil {
		die("%v", err)
	}
	volatility := map[string]map[string]any{}
	for _, row := range tsvRows(volatilityPath) {
		volatility[field(row, 0)] = map[string]any{"volatile_element": field(row, 1), "comparator_needed": field(row, 2)}
	}
	volKeys, semKeys := []string{}, []string{}
	for k := range volatility {
		volKeys = append(volKeys, k)
	}
	for k := range semantics {
		semKeys = append(semKeys, k)
	}
	if !equalStrings(sortedCopy(volKeys), sortedCopy(semKeys)) {
		diff := append(subtract(volKeys, semKeys), subtract(semKeys, volKeys)...)
		die("volatility and semantics tables disagree: %s", inspect(sortedCopy(diff)))
	}
	for path, row := range semantics {
		if row.VolatileElement != asString(volatility[path]["volatile_element"]) {
			die("semantics: %s volatile_element does not match docs/tour/volatility.tsv", path)
		}
	}

	pin := tsvRows(filepath.Join(root, "docs/tour/pin.tsv"))[0]
	tc := tsvRows(filepath.Join(root, "docs/tour/toolchain.tsv"))[0]
	helper := tsvRows(filepath.Join(root, "docs/tour/helpers.tsv"))[0]
	corpus := tsvRows(filepath.Join(root, "docs/tour/corpus.tsv"))[0]

	if field(pin, 7) != inventory.DataSHA256 {
		die("pin inventory_data_sha256 mismatch: docs/tour/pin.tsv says %s, inventory hashes to %s", field(pin, 7), inventory.DataSHA256)
	}
	if mustInt(field(pin, 6)) != inventory.Rows {
		die("pin declares %s inventory rows, inventory has %d", field(pin, 6), inventory.Rows)
	}

	// --- pinned Go toolchain, fail closed
	goroot := shellOutput(map[string]string{"GOTOOLCHAIN": tc[2]}, "go", "env", "GOROOT")
	if goroot == "" {
		die("cannot resolve GOROOT for %s", tc[2])
	}
	goBin := filepath.Join(goroot, "bin/go")
	if !isExecutable(goBin) {
		die("pinned Go binary missing at %s", goBin)
	}
	goVersionOut, _ := combinedOutput(goBin, "version")
	goVersion := strings.TrimSpace(firstLine(goVersionOut))
	if goVersion != tc[3] {
		die("Go binary is not the pinned toolchain (%s, expected %s)", inspectString(goVersion), inspectString(tc[3]))
	}
	goSHA := shaFile(goBin)
	if goSHA != tc[4] {
		die("Go binary checksum does not match docs/tour/toolchain.tsv (%s)", goSHA)
	}

	// --- candidate product: authenticated against the EXACT manager-supplied manifest
	bashy := os.Getenv("BASHPP_BIN")
	if bashy == "" || !isExecutable(bashy) {
		die("BASHPP_BIN must name the candidate bashy launcher")
	}
	if real, err := filepath.EvalSymlinks(bashy); err == nil {
		bashy, _ = filepath.Abs(real)
	}
	manifestPath := os.Getenv("TOUR_CANDIDATE_MANIFEST")
	if manifestPath == "" || !fileExists(manifestPath) {
		die("TOUR_CANDIDATE_MANIFEST must name the manager-supplied candidate manifest")
	}
	manifestPath, _ = filepath.Abs(manifestPath)
	candidateContract := loadCandidateContract(candidatePath)
	candidate, err := authenticateCandidate(bashy, manifestPath, candidateContract)
	if err != nil {
		die("candidate authentication failed: %v", err)
	}
	candidate["contract_sha256"] = shaFile(candidatePath)
	candidateReasons := candidateFailures(candidate)
	if len(candidateReasons) > 0 {
		die("candidate binding is incomplete: %s", strings.Join(candidateReasons, ", "))
	}
	runtimeDep, err := runtimeDependency(candidate)
	if err != nil {
		die("%v", err)
	}

	// --- work root, durable evidence root
	work, err := os.MkdirTemp("", "tour-executor")
	if err != nil {
		die("%v", err)
	}
	defer os.RemoveAll(work)
	evidenceRoot, _ := filepath.Abs(envOr("TOUR_EXECUTOR_EVIDENCE", filepath.Join(root, ".cache/tour/executor-evidence")))
	os.RemoveAll(evidenceRoot)
	if err := os.MkdirAll(evidenceRoot, 0o755); err != nil {
		die("%v", err)
	}

	gomodcache := shellOutput(nil, goBin, "env", "GOMODCACHE")
	gocache := shellOutput(nil, goBin, "env", "GOCACHE")
	if gomodcache == "" || gocache == "" {
		die("cannot resolve GOMODCACHE/GOCACHE")
	}

	spec := materializeSpec{corpusRoot: corpusRoot, corpus: corpus, items: items, goVersion: tc[2], helper: helper, runtimeDep: runtimeDep}

	// --- helper module provisioning (once, networked; every later stage is GOPROXY=off)
	provisionDir := filepath.Join(work, "provision")
	provisionHome := filepath.Join(work, "provision-home")
	for _, d := range []string{provisionDir, provisionHome, filepath.Join(work, "provision-tmp")} {
		os.MkdirAll(d, 0o755)
	}
	if err := materialize(provisionDir, spec); err != nil {
		die("%v", err)
	}
	provisionEnv := withPath(baseEnv(provisionHome, filepath.Join(work, "provision-tmp"), gomodcache, gocache, "https://proxy.golang.org,direct", goroot), toolchainPath)
	provisionTimeout := timeout
	if provisionTimeout < 300 {
		provisionTimeout = 300
	}
	provision, err := run([]string{goBin, "mod", "download", helper[0]}, provisionDir, provisionTimeout, provisionEnv,
		filepath.Join(evidenceRoot, "provision/mod-download"))
	if err != nil {
		die("%v", err)
	}
	if !(provision.Spawned && jsonEqual(provision.Exit, int64(0))) {
		fmt.Fprint(os.Stderr, string(provision.Stderr))
		die("cannot provision helper module %s@%s from the pinned sums", helper[0], helper[1])
	}
	helperDir := filepath.Join(gomodcache, helper[0]+"@"+helper[1])
	if !dirExists(helperDir) {
		die("helper module not materialized at %s", helperDir)
	}
	var ziphash any
	if f := filepath.Join(gomodcache, "cache/download", helper[0], "@v", helper[1]+".ziphash"); fileExists(f) {
		ziphash = shaFile(f)
	}
	helperProvision := map[string]any{
		"module": helper[0], "version": helper[1], "license": helper[2],
		"go_mod_sum": helper[3], "zip_sum": helper[4], "packages": anyList(strings.Split(helper[5], ",")),
		"materialized_dir": helperDir,
		"ziphash_sha256":   ziphash,
		"provisioned_by":   fmt.Sprintf("%s mod download %s", goBin, helper[0]),
	}

	// --- manifest
	runStartedAt := nowFloat()
	manifest := map[string]any{
		"type": "manifest", "schema": executorSchema,
		"generated_by":           "tools/tour/executor_runner.go",
		"story":                  map[string]any{"sprint": int64(118), "story": int64(4), "story_id": "759341a95870"},
		"partial":                partial,
		"capture_implementation": captureImplementation,
		"capture_library_sha256": shaFile(filepath.Join(root, captureLibraryPath)),
		"contract":               map[string]any{"path": "docs/tour/executor-contract.tsv", "sha256": shaFile(contractPath)},
		"phase_migration": map[string]any{"path": "docs/tour/phase-migration.tsv", "sha256": shaFile(migrationPath),
			"rows":   int64(len(migration)),
			"policy": "current master plan outranks the stale pinned phase string; historical inventory schema preserved"},
		"inventory": map[string]any{"path": "tests/tour/inventory.tsv", "sha256": shaFile(inventoryPath), "rows": inventory.Rows,
			"executable_programs": int64(len(items)), "applicable": int64(applicable), "build_only": int64(buildOnly),
			"data_sha256": inventory.DataSHA256},
		"accepted_baseline": map[string]any{"path": "tests/tour/results.tsv", "sha256": shaFile(acceptedPath),
			"pin":        "docs/tour/baseline-pin.tsv",
			"pin_sha256": shaFile(filepath.Join(root, "docs/tour/baseline-pin.tsv")),
			"role":       "exact oracle for the 87 stable rows; HISTORICAL stream evidence only for the 10 semantic rows"},
		"source_pin": map[string]any{"path": "docs/tour/pin.tsv", "release": pin[0] + "@" + pin[1], "commit": pin[2], "license": pin[4],
			"sha256": shaFile(filepath.Join(root, "docs/tour/pin.tsv"))},
		"corpus": map[string]any{"path": "docs/tour/corpus.tsv", "root": corpus[0], "license_sha256": corpus[3],
			"source_rows": mustInt(corpus[4]), "corpus_files": mustInt(corpus[5]),
			"sha256": shaFile(filepath.Join(root, "docs/tour/corpus.tsv"))},
		"go": map[string]any{"path": goBin, "identity": goVersion, "sha256": goSHA, "pinned_identity": tc[3], "pinned_sha256": tc[4],
			"goroot": goroot},
		"helper_module":      helperProvision,
		"candidate":          candidate,
		"runtime_dependency": runtimeDep,
		"candidate_failures": anyList(candidateReasons),
		"volatility": map[string]any{"path": "docs/tour/volatility.tsv", "gate_effect": "measurement-record",
			"rows":   int64(len(volatility)),
			"sha256": shaFile(volatilityPath)},
		"semantics": map[string]any{"path": "docs/tour/semantics.tsv", "gate_effect": "semantic-comparator",
			"version": semanticsVersion, "rows": int64(len(semantics)),
			"oracle_repeats": int64(oracleRepeats), "min_oracle_runs": int64(minOracleRuns),
			"library_sha256": shaFile(filepath.Join(root, semanticsLibraryPath)),
			"sha256":         shaFile(semanticsPath)},
		"normalizer": map[string]any{"path": normalizerPath, "sha256": shaFile(filepath.Join(root, normalizerPath)),
			"version": normalizerVersion},
		"environment": map[string]any{"toolchain_path": toolchainPath, "body_path": "", "lc_all": "C", "gomaxprocs": int64(2),
			"goproxy_during_run": "off", "gomodcache": gomodcache, "gocache": gocache,
			"goroot_shared_by_all_modes": goroot,
			"input_absence_scope":        inputAbsenceScope,
			"os_sandbox":                 false,
			"fresh_state":                "module tree per mode; HOME, TMPDIR, artifact and runtime directories per (row, mode)"},
		"evidence_root":         evidenceRoot,
		"platform":              map[string]any{"goos": shellOutput(nil, goBin, "env", "GOOS"), "goarch": shellOutput(nil, goBin, "env", "GOARCH"), "go": runtime.Version()},
		"expected_observations": int64(observationsFull),
	}
	records := []map[string]any{manifest}

	// --- execution
	selected := items
	if partial {
		selected = []Item{}
		for _, item := range items {
			if strings.Contains(item.Path, only) {
				selected = append(selected, item)
			}
		}
		fmt.Fprintf(os.Stderr, "WARN: TOUR_ONLY=%s selects %d/%d rows; this ledger is PARTIAL and the gate will reject it\n", only, len(selected), len(items))
	}

	moduleDirs := map[string]string{}
	for _, mode := range modes {
		moduleDirs[mode] = filepath.Join(work, "state", mode, "module")
		if err := materialize(moduleDirs[mode], spec); err != nil {
			die("%v", err)
		}
	}

	progress := 0
	for _, item := range selected {
		itemSlug := slug(item.Path)
		semanticRow := semantics[item.Path]
		modeRecords := map[string]map[string]any{}
		oracleRuns := []any{}
		var oracleBinary map[string]any

		for _, mode := range modes {
			recipe := contract[modeKey{item.Applicability, mode}]
			mod := moduleDirs[mode]
			state := filepath.Join(work, "state", mode, itemSlug)
			home := filepath.Join(state, "home")
			tmp := filepath.Join(state, "tmp")
			// The artifact directory is DURABLE.
			artifacts := filepath.Join(evidenceRoot, mode, itemSlug, "artifacts")
			// A body stage that executes a NATIVE artifact runs from this fresh,
			// empty directory: the compilation inputs are not reachable through the cwd.
			runtimeDir := filepath.Join(state, "runtime")
			logs := filepath.Join(evidenceRoot, mode, itemSlug, "logs")
			for _, d := range []string{home, tmp, artifacts, runtimeDir, logs} {
				os.MkdirAll(d, 0o755)
			}
			subs := substitutions(item.Path, bashy, goBin, artifacts)

			stages := []any{}
			for _, stageSpec := range recipe.Stages {
				argv := mustRenderArgv(stageSpec.ArgvTemplate, subs)
				toolchainStage := argv[0] == goBin
				bodyInRuntime := stageSpec.ExecuteBody && !toolchainStage && argv[0] != bashy
				cwd, cwdLabel := mod, "module"
				if bodyInRuntime {
					cwd, cwdLabel = runtimeDir, "runtime"
					if leaked := countEntries(runtimeDir); leaked != 0 {
						die("runtime cwd for %s/%s is not empty (%d entries)", item.Path, mode, leaked)
					}
				}
				pathEnv := ""
				if toolchainStage {
					pathEnv = toolchainPath
				}
				env := withPath(baseEnv(home, tmp, gomodcache, gocache, "off", goroot), pathEnv)
				inputs := map[string]any{}
				for _, name := range consumedArtifacts(stageSpec) {
					inputPath := subs[map[string]string{"go": "OUT_GO", "bin": "BIN"}[name]]
					record := artifactRecord(inputPath)
					record["path"] = filepath.Base(inputPath)
					inputs[name] = record
				}
				raw, err := run(argv, cwd, timeout, env, filepath.Join(logs, fmt.Sprintf("%02d-%s", stageSpec.Index, stageSpec.Stage)))
				if err != nil {
					die("%v", err)
				}
				raw.InputArtifacts = inputs
				stages = append(stages, stageRecord(stageSpec, argv, raw, subs, cwdLabel, pathEnv))
				// Stop the pipeline at the first failing stage.
				if stageFailure(asMap(stages[len(stages)-1])) != "" {
					break
				}
			}
			// Pad the record so the gate sees the declared stage count and the
			// exact stage that was never reached.
			for _, stageSpec := range recipe.Stages[len(stages):] {
				stages = append(stages, unreachedStage(stageSpec, mustRenderArgv(stageSpec.ArgvTemplate, subs), subs))
			}

			observation := map[string]any{
				"type": "observation", "path": item.Path, "applicability": item.Applicability,
				"exception": item.Exception, "differential_schema": item.DifferentialSchema,
				"mode": mode, "phase": recipe.Phase,
				"historical_phase_token": migration[modeKey{item.Applicability, mode}].HistoricalToken,
				"source":                 map[string]any{"bytes": item.Bytes, "sha256": item.SHA256},
				"stages":                 stages,
			}
			observation["authoritative_stage"] = int64(authoritativeIndex(stages))
			if mode == "baseline" {
				if acc, ok := accepted[item.Path]; ok {
					observation["accepted_observation"] = map[string]any(acc)
				} else {
					observation["accepted_observation"] = nil
				}
			}
			if vol, ok := volatility[item.Path]; ok {
				observation["volatility"] = vol
			}
			modeRecords[mode] = observation

			// -- the native oracle, for the declared-volatile rows only.
			if !(mode == "baseline" && semanticRow != nil) {
				continue
			}
			binary := subs["BIN"]
			if !fileExists(binary) {
				continue
			}
			oracleBinary = artifactRecord(binary)
			bodyEnv := withPath(baseEnv(home, tmp, gomodcache, gocache, "off", goroot), "")
			for i := 0; i < oracleRepeats; i++ {
				repeatDir := filepath.Join(state, fmt.Sprintf("oracle-%d", i))
				os.MkdirAll(repeatDir, 0o755)
				raw, err := run([]string{binary}, repeatDir, timeout, bodyEnv, filepath.Join(logs, fmt.Sprintf("oracle-%02d", i)))
				if err != nil {
					die("%v", err)
				}
				oracleRuns = append(oracleRuns, map[string]any{
					"index": int64(i), "spawned": raw.Spawned, "state": raw.State, "exit": raw.Exit,
					"signal": raw.Signal, "descendants_survived": raw.DescendantsSurvived,
					"duration_ms": raw.DurationMS, "started_at": raw.StartedAt, "finished_at": raw.FinishedAt,
					"stdout_base64": b64(raw.Stdout), "stdout_bytes": int64(len(raw.Stdout)),
					"stderr_base64": b64(raw.Stderr), "stderr_bytes": int64(len(raw.Stderr)),
				})
			}
		}

		// -- semantic adjudication for a declared-volatile row
		if semanticRow != nil {
			utcOffset := utcOffsetNow()
			oracleWindow := semanticWindow(nil, oracleRuns, utcOffset)
			oracle := decodeOracle(oracleRuns)
			var binaryRecord any
			if oracleBinary != nil {
				binaryRecord = oracleBinary
			}
			var windowRecord any
			if oracleWindow != nil {
				windowRecord = oracleWindow
			}
			records = append(records, map[string]any{
				"type": "oracle", "path": item.Path, "comparator": semanticRow.Comparator,
				"source_sha256": semanticRow.SourceSHA256, "repeats": int64(len(oracleRuns)),
				"binary": binaryRecord, "window": windowRecord, "runs": oracleRuns,
				"provenance": "repeated execution of the native artifact built from the unchanged upstream source in this run",
			})
			for _, mode := range modes {
				observation := modeRecords[mode]
				stages := asList(observation["stages"])
				final := asMap(stages[authoritativeIndex(stages)])
				window := semanticWindow(stages, oracleRuns, utcOffset)
				var windowValue any
				if window != nil {
					windowValue = window
				}
				observation["window"] = windowValue
				verdict := compareSemantic(semanticRow, candidateStreams(final), oracle, window, semanticsVersion)
				verdict["stage"] = final["stage"]
				observation["semantic"] = verdict
				observation["historical_accepted"] = "informational: streams adjudicated by the comparator against the native oracle"
			}
		}

		for _, mode := range modes {
			observation := modeRecords[mode]
			var baselineObs map[string]any
			if mode != "baseline" {
				baselineObs = modeRecords["baseline"]
			}
			observation["status"] = observationStatus(observation, contract[modeKey{item.Applicability, mode}], accepted[item.Path], baselineObs, semanticRow, semanticsVersion)
			records = append(records, observation)
		}

		progress++
		if os.Getenv("TOUR_VERBOSE") != "" {
			fmt.Fprintf(os.Stderr, "  [%d/%d] %s\n", progress, len(selected), item.Path)
		}
	}

	for _, mode := range modes {
		if err := verifySources(moduleDirs[mode], corpusRoot, items); err != nil {
			die("%v", err)
		}
	}
	// Reauthenticate the exact launcher/payload/source revision set after execution.
	finalCandidate, err := authenticateCandidate(bashy, manifestPath, candidateContract)
	if err != nil {
		die("candidate authentication failed: %v", err)
	}
	finalCandidate["contract_sha256"] = shaFile(candidatePath)
	if !jsonEqual(finalCandidate, candidate) {
		die("candidate changed while the Tour corpus ran")
	}

	// --- summary, root, verdict
	manifest["run_window"] = map[string]any{"from": runStartedAt, "to": nowFloat(), "utc_offset": utcOffsetNow()}

	observations := []map[string]any{}
	oracles := []map[string]any{}
	for _, r := range records {
		switch r["type"] {
		case "observation":
			observations = append(observations, r)
		case "oracle":
			oracles = append(oracles, r)
		}
	}
	counts := countBy(observations, "status")
	byMode := map[string]any{}
	for _, mode := range modes {
		subset := []map[string]any{}
		for _, o := range observations {
			if o["mode"] == mode {
				subset = append(subset, o)
			}
		}
		byMode[mode] = countBy(subset, "status")
	}
	var oracleRunTotal int64
	for _, o := range oracles {
		oracleRunTotal += toI(o["repeats"])
	}
	summary := map[string]any{"type": "summary", "observations": int64(len(observations)), "programs": int64(len(selected)),
		"modes": anyList(modes), "outcomes": counts, "by_mode": byMode,
		"expected_observations": int64(observationsFull),
		"semantic_rows":         int64(len(oracles)), "oracle_runs": oracleRunTotal,
		"sources_unchanged": true, "candidate_reauthenticated": true}
	records = append(records, summary)
	rootRecord := map[string]any{"type": "root", "algorithm": "sha256-canonical-jsonl", "sha256": ledgerRoot(records)}
	records = append(records, rootRecord)
	pass := !partial && len(candidateReasons) == 0 && len(observations) == observationsFull &&
		jsonEqual(counts, map[string]any{"PASS": int64(observationsFull)})
	verdict := "FAIL"
	if pass {
		verdict = "PASS"
	}
	records = append(records, map[string]any{"type": "verdict", "value": verdict, "root_sha256": rootRecord["sha256"]})

	if err := writeLedger(output, records); err != nil {
		die("%v", err)
	}
	fmt.Printf("%s %s: %d/%d observations\n", executorSchema, verdict, len(observations), observationsFull)
	for _, mode := range modes {
		parts := []string{}
		outcomes := asMap(byMode[mode])
		for _, k := range sortedKeys(outcomes) {
			parts = append(parts, fmt.Sprintf("%s=%d", k, toI(outcomes[k])))
		}
		fmt.Printf("  %-12s %s\n", mode, strings.Join(parts, " "))
	}
	if len(candidateReasons) == 0 {
		fmt.Println("  candidate: authenticated")
	} else {
		fmt.Printf("  candidate: %s\n", strings.Join(candidateReasons, ", "))
	}
	fmt.Printf("  semantic:  %d rows, %d native oracle runs\n", len(oracles), oracleRunTotal)
	fmt.Printf("  root %s\n", rootRecord["sha256"])
	fmt.Printf("  ledger %s\n", strings.TrimPrefix(output, root+"/"))
	if pass {
		return 0
	}
	return 1
}

func isExecutable(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0
}

func countEntries(dir string) int {
	n := 0
	filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err == nil && path != dir {
			n++
		}
		return nil
	})
	return n
}
