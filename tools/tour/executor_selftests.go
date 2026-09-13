// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Selftests for the tour three-mode executor and its offline gate — the port
// of tools/tour/executor-selftests.rb. Two layers:
//
//	UNIT   the pure decision functions in executor.go: contract loading, the
//	       phase-migration bridge, argv rendering, stage and observation
//	       scoring, source-map validation, manifest-based candidate
//	       authentication and the independent normalization audit.
//	GATE   `tour validate-executor` is executed as a real subprocess against a
//	       synthetic 97-row fixture tree (93 applicable + 4 build-only, 291
//	       observations, one declared-volatile row with a native oracle). The
//	       fixture is built to PASS; each subsequent case mutates exactly one
//	       thing and requires the gate to reject it with the expected finding.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type fixture struct {
	dir              string
	inventoryDataSHA string
	inventoryRows    int
}

const (
	fixtureGoPath    = "/fixture/go"
	fixtureBashyPath = "/fixture/bashy"
)

var schemaFor = map[string]string{
	"applicable_go_program": "baseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run",
	"build_only_go_program": "baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build-run",
}

func fixturePaths() (applicable, norun []string) {
	for i := 0; i < applicableRows; i++ {
		applicable = append(applicable, fmt.Sprintf("_content/tour/fixture/prog-%03d.go", i))
	}
	for i := 0; i < buildOnlyRows; i++ {
		norun = append(norun, fmt.Sprintf("_content/tour/fixture/norun-%d.go", i))
	}
	return
}

func fixtureItems() []Item {
	applicable, norun := fixturePaths()
	items := []Item{}
	for _, p := range applicable {
		items = append(items, Item{Path: p, Applicability: "applicable_go_program"})
	}
	for _, p := range norun {
		items = append(items, Item{Path: p, Applicability: "build_only_go_program"})
	}
	return items
}

func fixtureStdout(path string) []byte {
	return []byte(strings.TrimSuffix(filepath.Base(path), ".go") + " output\n")
}

func fixtureSource(path string) []byte {
	return []byte("package main // " + path + "\n")
}

func buildFixture(root, dir string) (*fixture, error) {
	for _, d := range []string{"docs/tour", "tests/tour", "tools/tour"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			return nil, err
		}
	}
	for _, rel := range []string{"docs/tour/executor-contract.tsv", "docs/tour/candidate.tsv", "docs/tour/phase-migration.tsv",
		normalizerPath, semanticsLibraryPath, captureLibraryPath} {
		if err := os.WriteFile(filepath.Join(dir, rel), readFile(filepath.Join(root, rel)), 0o644); err != nil {
			return nil, err
		}
	}
	applicable, _ := fixturePaths()
	volatile := applicable[0]
	inventoryRows := []string{}
	for _, item := range fixtureItems() {
		source := fixtureSource(item.Path)
		inventoryRows = append(inventoryRows, strings.Join([]string{item.Path, "lesson_play_program", "n/a", item.Applicability, "exception:none",
			schemaFor[item.Applicability], fmt.Sprint(len(source)), sha256hex(source)}, "\t"))
	}
	inventoryBody := strings.Join(inventoryRows, "\n") + "\n"
	os.WriteFile(filepath.Join(dir, "tests/tour/inventory.tsv"), []byte("# fixture\n"+inventoryBody), 0o644)
	dataSHA := sha256hex([]byte(inventoryBody))

	resultsRows := []string{}
	for _, item := range fixtureItems() {
		row := []string{item.Path, item.Applicability, "0", "0", "444"}
		if item.Applicability == "applicable_go_program" {
			out := fixtureStdout(item.Path)
			row = append(row, "go-run", "0", "0", fmt.Sprint(len(out)), sha256hex(out), "0", sha256hex(nil), "strict", "pass")
		} else {
			row = append(row, "go-test-or-build", "0", "-", "-", "-", "-", "-", "-", "pass")
		}
		resultsRows = append(resultsRows, strings.Join(row, "\t"))
	}
	os.WriteFile(filepath.Join(dir, "tests/tour/results.tsv"), []byte("# fixture\n"+strings.Join(resultsRows, "\n")+"\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "docs/tour/pin.tsv"),
		[]byte(fmt.Sprintf("# fixture\nfixture.example/website\tv0.0.0\tdeadbeef\th1:x=\tBSD-3-Clause\tfixture\t%d\t%s\n", len(inventoryRows), dataSHA)), 0o644)
	os.WriteFile(filepath.Join(dir, "docs/tour/toolchain.tsv"),
		[]byte("# fixture\ndarwin\tarm64\tgo1.27.0\tgo version go1.27.0 darwin/arm64\t"+strings.Repeat("c", 64)+"\tfixture\tfixture\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "docs/tour/helpers.tsv"),
		[]byte("# fixture\ngolang.org/x/tour\tv0.1.0\tBSD-3-Clause\th1:mod=\th1:zip=\tpic,reader,tree,wc\tfixture\n"), 0o644)
	license := []byte("BSD fixture license\n")
	os.WriteFile(filepath.Join(dir, "docs/tour/corpus.tsv"),
		[]byte(fmt.Sprintf("# fixture\ntour\ttour/LICENSE\t%d\t%s\t97\t98\tfixture\n", len(license), sha256hex(license))), 0o644)
	os.WriteFile(filepath.Join(dir, "docs/tour/baseline-pin.tsv"), []byte("# fixture\nfixture\n"), 0o644)
	// One declared-volatile fixture row, adjudicated by the real `line_set`
	// comparator against a real oracle record.
	os.WriteFile(filepath.Join(dir, "docs/tour/volatility.tsv"),
		[]byte("# fixture\n"+volatile+"\tfixture map order\tline set comparison\n"), 0o644)
	params := canonical(map[string]any{"lines": []any{strings.TrimSuffix(string(fixtureStdout(volatile)), "\n")}})
	os.WriteFile(filepath.Join(dir, "docs/tour/semantics.tsv"),
		[]byte(fmt.Sprintf("# fixture\n%s\tline_set\t%s\tnot_required\tfixture map order\t%s\n", volatile, sha256hex(fixtureSource(volatile)), params)), 0o644)
	return &fixture{dir: dir, inventoryDataSHA: dataSHA, inventoryRows: len(inventoryRows)}, nil
}

func normalizedFor(raw []byte) map[string]any {
	out, ok := auditNormalize(raw)
	if !ok {
		return map[string]any{"valid_utf8": false, "bytes": nil, "sha256": nil}
	}
	return map[string]any{"valid_utf8": true, "bytes": int64(len(out)), "sha256": sha256hex(out)}
}

type fixtureClock struct{ now float64 }

func (c *fixtureClock) next() float64 {
	c.now += 0.5
	return c.now
}

func fixtureStage(clock *fixtureClock, spec Stage, argv []string, mode string, stdout, stderr []byte, path string) map[string]any {
	generatedSHA := sha256hex([]byte("generated:" + path))
	produced := map[string]any{}
	for _, name := range spec.Produces {
		token := map[string]string{"go": "{OUT_GO}", "map": "{OUT_MAP}", "bin": "{BIN}"}[name]
		sha := sha256hex([]byte(name + ":" + path))
		if name == "go" {
			sha = generatedSHA
		}
		record := map[string]any{"present": true, "bytes": int64(10), "sha256": sha,
			"path": filepath.Base(argv[indexOf(spec.ArgvTemplate, token)])}
		if name == "map" {
			record["source_map"] = map[string]any{"schema_version": "bashy-transpile-map-v1", "origin": path,
				"go_digest": "sha256:" + generatedSHA, "mappings": int64(12),
				"source_files": []any{path}, "positioned": true}
		}
		produced[name] = record
	}
	cwd := "module"
	if spec.ExecuteBody && mode != "interpreted" {
		cwd = "runtime"
	}
	pathEnv := "/usr/bin:/bin"
	if spec.ExecuteBody {
		pathEnv = ""
	}
	record := map[string]any{
		"index": spec.Index, "stage": spec.Stage, "execute_body": spec.ExecuteBody,
		"command": anyList(argv), "cwd": cwd, "path_env": pathEnv,
		"spawned": true, "state": "exited", "exit": int64(0), "signal": nil, "descendants_survived": false,
		"duration_ms": int64(1), "started_at": clock.next(), "finished_at": clock.next(),
		"artifacts": produced,
		"raw": map[string]any{"stdout_base64": b64(stdout), "stdout_bytes": int64(len(stdout)),
			"stderr_base64": b64(stderr), "stderr_bytes": int64(len(stderr))},
		"logs":       map[string]any{"stdout_sha256": sha256hex(stdout), "stderr_sha256": sha256hex(stderr)},
		"normalized": map[string]any{"stdout": normalizedFor(stdout), "stderr": normalizedFor(stderr)},
		"masking": map[string]any{"stdout": maskingReport(stdout, normalizedFor(stdout)["bytes"]),
			"stderr": maskingReport(stderr, normalizedFor(stderr)["bytes"])},
	}
	if spec.ExecuteBody {
		record["input_absence"] = map[string]any{"scope": inputAbsenceScope, "cwd": cwd, "path_env": "", "os_sandbox": false}
	}
	return record
}

func buildFixtureLedger(fx *fixture, contract Contract, migration Migration) []map[string]any {
	clock := &fixtureClock{now: float64(time.Date(2026, 9, 8, 12, 0, 0, 0, time.Local).Unix())}
	runFrom := clock.now
	dir := fx.dir
	shaOf := func(rel string) string { return shaFile(filepath.Join(dir, rel)) }
	components := loadCandidateContract(filepath.Join(dir, "docs/tour/candidate.tsv"))
	repositories := []any{}
	boundComponents := []any{}
	for _, c := range components {
		name := asString(c["component"])
		repositories = append(repositories, map[string]any{"name": name, "path": "/fixture/" + name, "commit": strings.Repeat("a", 40)})
		merged := map[string]any{}
		for k, v := range c {
			merged[k] = v
		}
		merged["bound"] = true
		merged["dir"] = "/fixture/" + name
		merged["commit"] = strings.Repeat("a", 40)
		boundComponents = append(boundComponents, merged)
	}
	candidate := map[string]any{
		"binding":          "manifest:launcher+payload+repository-commits",
		"authenticated_by": "AuthenticateCandidate (tools/tour/capture.go)",
		"manifest_path":    "/fixture/candidate.json", "manifest_sha256": strings.Repeat("m", 64),
		"frontend_version": "gosource-v1", "build_recipe": "make build BASHY_GOSOURCE=1",
		"manifest_status": "fixture",
		"version_line":    "bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-dev (abc1234)",
		"binaries": map[string]any{"launcher": map[string]any{"path": fixtureBashyPath, "present": true, "bytes": int64(1), "sha256": strings.Repeat("a", 64)},
			"payload": map[string]any{"path": fixtureBashyPath + ".real", "present": true, "expected": true, "bytes": int64(2), "sha256": strings.Repeat("b", 64)}},
		"repositories":    repositories,
		"components":      boundComponents,
		"contract_sha256": shaOf("docs/tour/candidate.tsv"),
	}
	semantics, err := loadSemanticsTable(filepath.Join(dir, "docs/tour/semantics.tsv"), nil)
	if err != nil {
		panic(err)
	}
	runtimeDep, _ := runtimeDependency(candidate)
	manifest := map[string]any{
		"type": "manifest", "schema": executorSchema, "generated_by": "fixture", "partial": false,
		"evidence_root":          "/fixture/evidence",
		"capture_implementation": captureImplementation,
		"capture_library_sha256": shaOf(captureLibraryPath),
		"story":                  map[string]any{"sprint": int64(118), "story": int64(4), "story_id": "759341a95870"},
		"contract":               map[string]any{"path": "docs/tour/executor-contract.tsv", "sha256": shaOf("docs/tour/executor-contract.tsv")},
		"phase_migration":        map[string]any{"path": "docs/tour/phase-migration.tsv", "sha256": shaOf("docs/tour/phase-migration.tsv"), "rows": int64(6)},
		"semantics": map[string]any{"path": "docs/tour/semantics.tsv", "sha256": shaOf("docs/tour/semantics.tsv"),
			"gate_effect": "semantic-comparator", "version": semanticsVersion, "rows": int64(1),
			"oracle_repeats": int64(7), "min_oracle_runs": int64(minOracleRuns),
			"library_sha256": shaOf(semanticsLibraryPath)},
		"inventory": map[string]any{"path": "tests/tour/inventory.tsv", "sha256": shaOf("tests/tour/inventory.tsv"),
			"rows":                int64(fx.inventoryRows),
			"executable_programs": int64(denominator), "applicable": int64(applicableRows),
			"build_only": int64(buildOnlyRows), "data_sha256": fx.inventoryDataSHA},
		"accepted_baseline": map[string]any{"path": "tests/tour/results.tsv", "sha256": shaOf("tests/tour/results.tsv"),
			"pin": "docs/tour/baseline-pin.tsv", "pin_sha256": shaOf("docs/tour/baseline-pin.tsv")},
		"source_pin": map[string]any{"path": "docs/tour/pin.tsv", "sha256": shaOf("docs/tour/pin.tsv")},
		"corpus":     map[string]any{"path": "docs/tour/corpus.tsv", "sha256": shaOf("docs/tour/corpus.tsv")},
		"go":         map[string]any{"path": fixtureGoPath, "identity": "go version go1.27.0 darwin/arm64", "sha256": strings.Repeat("c", 64)},
		"helper_module": map[string]any{"module": "golang.org/x/tour", "version": "v0.1.0", "license": "BSD-3-Clause", "go_mod_sum": "h1:mod=",
			"zip_sum": "h1:zip=", "packages": []any{"pic", "reader", "tree", "wc"},
			"materialized_dir": "/fixture/gomodcache/golang.org/x/tour@v0.1.0"},
		"runtime_dependency": runtimeDep,
		"candidate":          candidate, "candidate_failures": anyList(candidateFailures(candidate)),
		"volatility": map[string]any{"path": "docs/tour/volatility.tsv", "gate_effect": "measurement-record", "rows": int64(1),
			"sha256": shaOf("docs/tour/volatility.tsv")},
		"normalizer":            map[string]any{"path": normalizerPath, "sha256": shaOf(normalizerPath), "version": normalizerVersion},
		"environment":           map[string]any{"input_absence_scope": inputAbsenceScope, "os_sandbox": false},
		"expected_observations": int64(observationsFull),
	}
	records := []map[string]any{manifest}
	accepted := loadAccepted(filepath.Join(dir, "tests/tour/results.tsv"))
	for _, item := range fixtureItems() {
		path := item.Path
		semanticRow := semantics[path]
		observations := []map[string]any{}
		for _, mode := range modes {
			recipe := contract[modeKey{item.Applicability, mode}]
			source := fixtureSource(path)
			subs := substitutions(path, fixtureBashyPath, fixtureGoPath, filepath.Join("/fixture/evidence", mode, slug(path), "artifacts"))
			bodyOut := []byte{}
			if item.Applicability == "applicable_go_program" {
				bodyOut = fixtureStdout(path)
			}
			stages := []any{}
			for _, spec := range recipe.Stages {
				argv := mustRenderArgv(spec.ArgvTemplate, subs)
				out := []byte{}
				if spec.ExecuteBody {
					out = bodyOut
				}
				stages = append(stages, fixtureStage(clock, spec, argv, mode, out, []byte{}, path))
			}
			for i, s := range stages {
				stage := asMap(s)
				inputs := map[string]any{}
				for _, name := range consumedArtifacts(recipe.Stages[i]) {
					for p := i - 1; p >= 0; p-- {
						previous := asMap(stages[p])
						if a, ok := asMap(previous["artifacts"])[name]; ok {
							inputs[name] = deepCopy(a)
							break
						}
					}
				}
				stage["inputs"] = inputs
			}
			observations = append(observations, map[string]any{
				"type": "observation", "path": path, "applicability": item.Applicability,
				"exception": "none", "differential_schema": schemaFor[item.Applicability],
				"mode": mode, "phase": recipe.Phase,
				"historical_phase_token": migration[modeKey{item.Applicability, mode}].HistoricalToken,
				"source":                 map[string]any{"bytes": int64(len(source)), "sha256": sha256hex(source)},
				"stages":                 stages, "authoritative_stage": int64(len(stages) - 1),
			})
		}

		if semanticRow != nil {
			binarySHA := sha256hex([]byte("bin:" + path))
			runs := []any{}
			for i := 0; i < 7; i++ {
				runs = append(runs, map[string]any{"index": int64(i), "spawned": true, "state": "exited", "exit": int64(0), "signal": nil,
					"descendants_survived": false, "duration_ms": int64(1),
					"started_at": clock.next(), "finished_at": clock.next(),
					"stdout_base64": b64(fixtureStdout(path)), "stdout_bytes": int64(len(fixtureStdout(path))),
					"stderr_base64": "", "stderr_bytes": int64(0)})
			}
			utcOffset := utcOffsetNow()
			records = append(records, map[string]any{"type": "oracle", "path": path, "comparator": semanticRow.Comparator,
				"source_sha256": semanticRow.SourceSHA256, "repeats": int64(len(runs)),
				"binary": map[string]any{"present": true, "bytes": int64(10), "sha256": binarySHA},
				"window": semanticWindow(nil, runs, utcOffset),
				"runs":   runs, "provenance": "fixture native repeats"})
			oracle := []Observation{}
			for range runs {
				oracle = append(oracle, Observation{Exit: int64(0), Stdout: string(fixtureStdout(path)), Stderr: ""})
			}
			for _, observation := range observations {
				stages := asList(observation["stages"])
				final := asMap(stages[len(stages)-1])
				window := semanticWindow(stages, runs, utcOffset)
				observation["window"] = window
				verdict := compareSemantic(semanticRow, Observation{Exit: final["exit"], Stdout: string(b64decode(toS(dig(final, "raw", "stdout_base64")))), Stderr: ""}, oracle, window, semanticsVersion)
				verdict["stage"] = final["stage"]
				observation["semantic"] = verdict
				observation["historical_accepted"] = "informational"
			}
		}

		for _, observation := range observations {
			mode := asString(observation["mode"])
			var baselineObs map[string]any
			if mode != "baseline" {
				baselineObs = observations[0]
			}
			observation["status"] = observationStatus(observation, contract[modeKey{item.Applicability, mode}], accepted[path], baselineObs, semanticRow, semanticsVersion)
			records = append(records, observation)
		}
	}
	manifest["run_window"] = map[string]any{"from": runFrom - 1, "to": clock.now + 1, "utc_offset": utcOffsetNow()}
	observations := []map[string]any{}
	oracleCount := int64(0)
	for _, r := range records {
		if r["type"] == "observation" {
			observations = append(observations, r)
		}
		if r["type"] == "oracle" {
			oracleCount++
		}
	}
	records = append(records, map[string]any{"type": "summary", "candidate_reauthenticated": true, "observations": int64(len(observations)),
		"programs": int64(len(fixtureItems())), "modes": anyList(modes), "outcomes": map[string]any{"PASS": int64(len(observations))},
		"semantic_rows": oracleCount, "expected_observations": int64(observationsFull), "sources_unchanged": true})
	return reseal(records)
}

// reseal recomputes summary counts, the root and the verdict so a mutated
// ledger stays internally consistent everywhere EXCEPT the mutated fact.
func reseal(records []map[string]any) []map[string]any {
	body := []map[string]any{}
	for _, r := range records {
		if r["type"] != "root" && r["type"] != "verdict" {
			body = append(body, r)
		}
	}
	observations := []map[string]any{}
	var summary map[string]any
	oracleCount := int64(0)
	for _, r := range body {
		switch r["type"] {
		case "observation":
			observations = append(observations, r)
		case "summary":
			summary = r
		case "oracle":
			oracleCount++
		}
	}
	if summary != nil {
		summary["outcomes"] = countBy(observations, "status")
		summary["observations"] = int64(len(observations))
		summary["semantic_rows"] = oracleCount
	}
	rootRecord := map[string]any{"type": "root", "algorithm": "sha256-canonical-jsonl", "sha256": ledgerRoot(body)}
	pass := len(observations) == observationsFull && summary != nil &&
		jsonEqual(summary["outcomes"], map[string]any{"PASS": int64(observationsFull)})
	value := "FAIL"
	if pass {
		value = "PASS"
	}
	return append(body, rootRecord, map[string]any{"type": "verdict", "value": value, "root_sha256": rootRecord["sha256"]})
}

// runGate executes `tour validate-executor` as a real subprocess.
func runGate(root, ledger string, extraEnv map[string]string) (int, string) {
	exe, _ := os.Executable()
	cmd := exec.Command(exe, "validate-executor")
	env := append(os.Environ(), "TOUR_REPO_ROOT="+root, "TOUR_EXECUTOR_RESULTS="+ledger)
	for k, v := range extraEnv {
		env = append(env, k+"="+v)
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		} else {
			code = -1
		}
	}
	return code, string(out)
}

func findRecord(records []map[string]any, pred func(map[string]any) bool) map[string]any {
	for _, r := range records {
		if pred(r) {
			return r
		}
	}
	return nil
}

func findIndex(records []map[string]any, pred func(map[string]any) bool) int {
	for i, r := range records {
		if pred(r) {
			return i
		}
	}
	return -1
}

func deleteAt(records []map[string]any, i int) []map[string]any {
	return append(append([]map[string]any{}, records[:i]...), records[i+1:]...)
}

func insertAt(records []map[string]any, i int, r map[string]any) []map[string]any {
	out := append([]map[string]any{}, records[:i]...)
	out = append(out, r)
	return append(out, records[i:]...)
}

func deepCopyRecords(records []map[string]any) []map[string]any {
	out := make([]map[string]any, len(records))
	for i, r := range records {
		out[i] = asMap(deepCopy(r))
	}
	return out
}

func lastStage(observation map[string]any) map[string]any {
	stages := asList(observation["stages"])
	return asMap(stages[len(stages)-1])
}

func stageAt(observation map[string]any, i int) map[string]any {
	return asMap(asList(observation["stages"])[i])
}

func restate(observation map[string]any, stdout []byte) {
	final := lastStage(observation)
	final["raw"] = map[string]any{"stdout_base64": b64(stdout), "stdout_bytes": int64(len(stdout)), "stderr_base64": "", "stderr_bytes": int64(0)}
	asMap(final["normalized"])["stdout"] = normalizedFor(stdout)
	asMap(final["logs"])["stdout_sha256"] = sha256hex(stdout)
}

func isObs(mode, applicability string) func(map[string]any) bool {
	return func(r map[string]any) bool {
		return r["type"] == "observation" && (mode == "" || r["mode"] == mode) && (applicability == "" || r["applicability"] == applicability)
	}
}

func cmdExecutorSelftests(root string) int {
	suite := &selftestSuite{}
	contractPath := filepath.Join(root, "docs/tour/executor-contract.tsv")
	candidatePath := filepath.Join(root, "docs/tour/candidate.tsv")
	migrationPath := filepath.Join(root, "docs/tour/phase-migration.tsv")

	// ============================================================ UNIT
	contract, err := loadContract(contractPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		return 1
	}
	migration, err := loadPhaseMigration(migrationPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		return 1
	}
	suite.check("contract: covers both applicabilities in all three modes", func() any {
		missing := []string{}
		for _, a := range executableApplicabilities {
			for _, m := range modes {
				if _, ok := contract[modeKey{a, m}]; !ok {
					missing = append(missing, a+"/"+m)
				}
			}
		}
		return expect(len(missing) == 0, "missing "+inspect(missing))
	})
	suite.check("contract: interpreted mode carries --bashpp --source=go (not bare shell dispatch)", func() any {
		argv := contract[modeKey{"applicable_go_program", "interpreted"}].Stages[0].ArgvTemplate
		return expect(containsString(argv, "--bashpp") && containsString(argv, "--source=go"), inspect(argv))
	})
	suite.check("contract: transpile carries --bashpp (transpile.go rejects it otherwise) and --source=go", func() any {
		argv := contract[modeKey{"applicable_go_program", "compiled"}].Stages[0].ArgvTemplate
		return expect(equalStrings(argv[:4], []string{"{BASHY}", "transpile", "--bashpp", "--source=go"}), inspect(argv))
	})
	suite.check("contract: transpile requests a source map artifact", func() any {
		stage := contract[modeKey{"applicable_go_program", "compiled"}].Stages[0]
		return expect(containsString(stage.ArgvTemplate, "--map") && equalStrings(sortedCopy(stage.Produces), []string{"go", "map"}), fmt.Sprintf("%+v", stage))
	})
	suite.check("contract: build-only interpreted uses semantic --check, never -n", func() any {
		stage := contract[modeKey{"build_only_go_program", "interpreted"}].Stages[0]
		return expect(stage.Stage == "check" && containsString(stage.ArgvTemplate, "--check") && !containsString(stage.ArgvTemplate, "-n") && !stage.ExecuteBody, fmt.Sprintf("%+v", stage))
	})
	suite.check("contract: build-only compiled stops after build, never runs the body", func() any {
		stages := contract[modeKey{"build_only_go_program", "compiled"}].Stages
		names := stageNames(stages)
		return expect(equalStrings(names, []string{"transpile", "build"}) && noneExecutes(stages), inspect(names))
	})
	suite.check("contract: build-only baseline builds without executing", func() any {
		stages := contract[modeKey{"build_only_go_program", "baseline"}].Stages
		return expect(equalStrings(stageNames(stages), []string{"build"}) && noneExecutes(stages), inspect(stageNames(stages)))
	})
	suite.check("contract: applicable baseline is go build + native artifact, never `go run`", func() any {
		stages := contract[modeKey{"applicable_go_program", "baseline"}].Stages
		return expect(equalStrings(stageNames(stages), []string{"build", "run"}) && !containsString(stages[0].ArgvTemplate, "run"), inspect(stageNames(stages)))
	})

	// --- phase migration
	suite.check("phase migration: no build-only mode may execute a body", func() any {
		offenders := []string{}
		for key, row := range migration {
			if key.applicability == "build_only_go_program" && row.ExecutesBody {
				offenders = append(offenders, key.mode)
			}
		}
		return expect(len(offenders) == 0, inspect(offenders))
	})
	suite.check("phase migration: every current build-only phase is explicitly a no-run phase", func() any {
		phases := []string{}
		for key, row := range migration {
			if key.applicability == "build_only_go_program" {
				phases = append(phases, row.CurrentPhase)
			}
		}
		all := true
		for _, p := range phases {
			if !strings.HasSuffix(p, "-no-run") {
				all = false
			}
		}
		return expect(all, inspect(phases))
	})
	suite.check("phase migration: the historical tokens are preserved verbatim", func() any {
		historical := []string{}
		for key, row := range migration {
			if key.applicability == "build_only_go_program" {
				historical = append(historical, row.HistoricalToken)
			}
		}
		historical = sortedCopy(historical)
		return expect(equalStrings(historical, []string{"go-test-or-build", "parse-or-run", "transpile-build-run"}), inspect(historical))
	})
	suite.check("phase migration: agrees with the real contract", func() any {
		items := []Item{{Path: "x.go", Applicability: "applicable_go_program", DifferentialSchema: "baseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run"},
			{Path: "y.go", Applicability: "build_only_go_program", DifferentialSchema: "baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build-run"}}
		failures := phaseMigrationFailures(migration, contract, items)
		return expect(len(failures) == 0, inspect(failures))
	})
	suite.check("phase migration: a rewritten historical inventory token is a finding", func() any {
		items := []Item{{Path: "y.go", Applicability: "build_only_go_program", DifferentialSchema: "baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build"}}
		failures := phaseMigrationFailures(migration, contract, items)
		return expect(anyHasPrefix(failures, "phase_migration:historical_drift"), inspect(failures))
	})
	suite.check("phase migration: a contract that reintroduces a body for a norun row is a finding", func() any {
		widened := Contract{}
		for k, v := range contract {
			widened[k] = v
		}
		base := contract[modeKey{"build_only_go_program", "compiled"}]
		widened[modeKey{"build_only_go_program", "compiled"}] = &Recipe{Phase: "transpile-build-no-run",
			Stages: append(append([]Stage{}, base.Stages...), Stage{Index: 2, Stage: "run", ArgvTemplate: []string{"{BIN}"}, Produces: []string{}, ExecuteBody: true})}
		failures := phaseMigrationFailures(migration, widened, nil)
		return expect(anyHasPrefix(failures, "phase_migration:body_policy"), inspect(failures))
	})
	suite.check("render_argv: substitutes every placeholder", func() any {
		argv, err := renderArgv([]string{"{BASHY}", "--bashpp", "--source=go", "{SRC}"}, map[string]string{"BASHY": "/b", "SRC": "a.go"})
		return expect(err == nil && equalStrings(argv, []string{"/b", "--bashpp", "--source=go", "a.go"}), inspect(argv))
	})
	suite.check("render_argv: an unknown placeholder is a hard error, never a literal argument", func() any {
		_, err := renderArgv([]string{"{NOPE}"}, map[string]string{})
		return expect(err != nil, "no error raised")
	})

	// --- stage scoring
	stage := func(overrides map[string]any) map[string]any {
		s := map[string]any{
			"index": int64(0), "stage": "run", "execute_body": true, "command": []any{"/bin/true"},
			"spawned": true, "state": "exited", "exit": int64(0), "descendants_survived": false, "artifacts": map[string]any{},
			"normalized": map[string]any{"stdout": map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": sha256hex(nil)},
				"stderr": map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": sha256hex(nil)}},
		}
		for k, v := range overrides {
			s[k] = v
		}
		return s
	}
	suite.check("stage_failure: clean stage passes", func() any { return expect(stageFailure(stage(nil)) == "", "expected nil") })
	suite.check("stage_failure: nonzero exit fails", func() any { return expect(stageFailure(stage(map[string]any{"exit": int64(2)})) == "exit:2", "x") })
	suite.check("stage_failure: deadline fails", func() any { return expect(stageFailure(stage(map[string]any{"state": "deadline"})) == "deadline", "x") })
	suite.check("stage_failure: launch failure fails", func() any {
		return expect(stageFailure(stage(map[string]any{"spawned": false})) == "launch_failure", "x")
	})
	suite.check("stage_failure: a leaked process group fails even with exit 0", func() any {
		got := stageFailure(stage(map[string]any{"state": "process_leak"}))
		return expect(got == "state:process_leak", inspectString(got))
	})
	suite.check("stage_failure: a surviving descendant fails even with a clean exit", func() any {
		got := stageFailure(stage(map[string]any{"descendants_survived": true}))
		return expect(got == "descendants_survived", inspectString(got))
	})
	suite.check("stage_failure: a declared artifact that was not produced fails", func() any {
		got := stageFailure(stage(map[string]any{"artifacts": map[string]any{"bin": map[string]any{"present": false}}}))
		return expect(got == "missing_artifact:bin", inspectString(got))
	})
	suite.check("stage_failure: a no-body stage that printed program output fails", func() any {
		got := stageFailure(stage(map[string]any{"execute_body": false, "normalized": map[string]any{"stdout": map[string]any{"valid_utf8": true, "bytes": int64(5), "sha256": "x"},
			"stderr": map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": "y"}}}))
		return expect(got == "body_executed", inspectString(got))
	})
	suite.check("stage_failure: invalid UTF-8 is rejected, never transliterated", func() any {
		got := stageFailure(stage(map[string]any{"normalized": map[string]any{"stdout": map[string]any{"valid_utf8": false, "bytes": nil, "sha256": nil},
			"stderr": map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": "y"}}}))
		return expect(got == "invalid_utf8", inspectString(got))
	})
	suite.check("authoritative_index: the FIRST failing stage owns the verdict", func() any {
		stages := []any{stage(map[string]any{"stage": "transpile", "index": int64(0)}), stage(map[string]any{"stage": "build", "index": int64(1), "exit": int64(1)}), stage(map[string]any{"stage": "run", "index": int64(2)})}
		return expect(authoritativeIndex(stages) == 1, fmt.Sprint(authoritativeIndex(stages)))
	})
	suite.check("authoritative_index: an all-green pipeline is owned by its last stage", func() any {
		stages := []any{stage(map[string]any{"index": int64(0)}), stage(map[string]any{"index": int64(1)}), stage(map[string]any{"index": int64(2)})}
		return expect(authoritativeIndex(stages) == 2, "x")
	})

	// --- source maps
	mapStage := func(overrides map[string]any) map[string]any {
		generated := strings.Repeat("d", 64)
		summary := map[string]any{"schema_version": "bashy-transpile-map-v1", "origin": "a/b.go",
			"go_digest": "sha256:" + generated, "mappings": int64(12), "source_files": []any{"a/b.go"}, "positioned": true}
		for k, v := range overrides {
			summary[k] = v
		}
		return stage(map[string]any{"stage": "transpile", "execute_body": false,
			"artifacts": map[string]any{"go": map[string]any{"present": true, "sha256": generated},
				"map": map[string]any{"present": true, "sha256": strings.Repeat("e", 64), "source_map": summary}}})
	}
	suite.check("source_map: a well-formed map for its own artifact passes", func() any {
		f := sourceMapFailures(mapStage(nil), "a/b.go")
		return expect(len(f) == 0, inspect(f))
	})
	suite.check("source_map: a map whose generation digest is not this artifact fails", func() any {
		f := sourceMapFailures(mapStage(map[string]any{"go_digest": "sha256:" + strings.Repeat("9", 64)}), "a/b.go")
		return expect(containsString(f, "source_map_generation_digest"), inspect(f))
	})
	suite.check("source_map: a map pointing at ANOTHER original source fails", func() any {
		f := sourceMapFailures(mapStage(map[string]any{"origin": "other.go", "source_files": []any{"other.go"}}), "a/b.go")
		return expect(anyHasPrefix(f, "source_map_origin"), inspect(f))
	})
	suite.check("source_map: an empty mapping list fails", func() any {
		f := sourceMapFailures(mapStage(map[string]any{"mappings": int64(0)}), "a/b.go")
		return expect(containsString(f, "source_map_empty"), inspect(f))
	})
	suite.check("source_map: unpositioned mappings fail", func() any {
		f := sourceMapFailures(mapStage(map[string]any{"positioned": false}), "a/b.go")
		return expect(containsString(f, "source_map_unpositioned"), inspect(f))
	})
	suite.check("source_map: a wrong schema version fails", func() any {
		f := sourceMapFailures(mapStage(map[string]any{"schema_version": "other/v9"}), "a/b.go")
		return expect(anyHasPrefix(f, "source_map_schema"), inspect(f))
	})
	suite.check("source_map: an absent map fails", func() any {
		s := stage(map[string]any{"stage": "transpile", "artifacts": map[string]any{"map": map[string]any{"present": false}}})
		return expect(equalStrings(sourceMapFailures(s, "a/b.go"), []string{"source_map_missing"}), "x")
	})

	// --- normalization audit
	suite.check("audit_normalize: collapses CRLF and masks pointer-sized hex only", func() any {
		out, _ := auditNormalize([]byte("a\r\nb 0xdeadbeefcafe 0x1f\n"))
		return expect(string(out) == "a\nb 0xADDR 0x1f\n", inspectString(string(out)))
	})
	suite.check("audit_normalize: leaves timestamps, numbers and paths intact (no blanket masking)", func() any {
		raw := "2026-09-08T12:00:00Z 42 /tmp/x/y\n"
		out, _ := auditNormalize([]byte(raw))
		return expect(string(out) == raw, "stream was altered")
	})
	suite.check("audit_normalize: rejects invalid UTF-8 instead of replacing it", func() any {
		_, ok := auditNormalize([]byte{0xff, 0xfe})
		return expect(!ok, "expected nil")
	})

	// --- semantic contract migration
	sayRow := &SemanticRow{Comparator: "say_interleaving"}
	v1Verdict := map[string]any{"comparator": "say_interleaving", "version": semanticsLegacyVersion, "ok": true, "findings": []any{}}
	suite.check("semantic migration: current adjudication rejects a v1 verdict by default", func() any {
		got := semanticVerdict(map[string]any{"semantic": v1Verdict}, sayRow, semanticsVersion)
		return expect(strings.HasPrefix(got, "FAIL:semantic_version:"), got)
	})
	suite.check("semantic migration: an authenticated v1 replay accepts that same v1 verdict explicitly", func() any {
		got := semanticVerdict(map[string]any{"semantic": v1Verdict}, sayRow, semanticsLegacyVersion)
		return expect(got == "PASS", got)
	})

	// --- candidate authentication
	components := loadCandidateContract(candidatePath)
	candidateFixture := func() map[string]any {
		repositories := []any{}
		bound := []any{}
		for _, c := range components {
			name := asString(c["component"])
			repositories = append(repositories, map[string]any{"name": name, "path": "/src/" + name, "commit": strings.Repeat("a", 40)})
			merged := map[string]any{}
			for k, v := range c {
				merged[k] = v
			}
			merged["bound"] = true
			merged["commit"] = strings.Repeat("a", 40)
			merged["dir"] = "/src/" + name
			bound = append(bound, merged)
		}
		return map[string]any{
			"binding":         "manifest:launcher+payload+repository-commits",
			"manifest_sha256": strings.Repeat("m", 64),
			"binaries": map[string]any{"launcher": map[string]any{"present": true, "sha256": strings.Repeat("a", 64), "path": "/b/bashy"},
				"payload": map[string]any{"present": true, "sha256": strings.Repeat("b", 64), "path": "/b/bashy.real"}},
			"repositories": repositories,
			"components":   bound,
		}
	}
	suite.check("candidate: the declared component set includes every replaced dependency, filebrowser included", func() any {
		names := []string{}
		for _, c := range components {
			names = append(names, asString(c["component"]))
		}
		return expect(equalStrings(sortedCopy(names), []string{"bashy", "coreutils", "filebrowser", "readline", "sh"}), inspect(names))
	})
	suite.check("candidate: a manifest-authenticated Makefile build is ACCEPTED (no release tag required)", func() any {
		reasons := candidateFailures(candidateFixture())
		return expect(len(reasons) == 0, inspect(reasons))
	})
	suite.check("candidate: a declared component missing from the manifest fails", func() any {
		c := candidateFixture()
		for _, x := range asList(c["components"]) {
			if asMap(x)["component"] == "filebrowser" {
				asMap(x)["bound"] = false
				asMap(x)["commit"] = nil
			}
		}
		return expect(containsString(candidateFailures(c), "candidate:unbound:filebrowser"), inspect(candidateFailures(c)))
	})
	suite.check("candidate: a manifest repository nobody declared fails", func() any {
		c := candidateFixture()
		c["repositories"] = append(asList(c["repositories"]), map[string]any{"name": "surprise", "path": "/src/surprise", "commit": strings.Repeat("c", 40)})
		return expect(containsString(candidateFailures(c), "candidate:undeclared_repository:surprise"), "x")
	})
	suite.check("candidate: a truncated revision is not a binding", func() any {
		c := candidateFixture()
		asMap(asList(c["repositories"])[1])["commit"] = "abc1234"
		return expect(containsString(candidateFailures(c), "candidate:unbound_revision:sh"), "x")
	})
	suite.check("candidate: a missing .real payload fails (launcher digest alone is not a binding)", func() any {
		c := candidateFixture()
		asMap(c["binaries"])["payload"] = map[string]any{"present": false, "sha256": nil}
		return expect(containsString(candidateFailures(c), "candidate:missing_payload"), "x")
	})
	suite.check("candidate: a frozen commit that does not match the manifest fails", func() any {
		c := candidateFixture()
		for _, x := range asList(c["components"]) {
			if asMap(x)["component"] == "bashy" {
				asMap(x)["frozen_commit"] = strings.Repeat("d", 40)
			}
		}
		return expect(containsString(candidateFailures(c), "candidate:frozen_mismatch:bashy"), "x")
	})
	suite.check("candidate: a candidate that was not manifest-authenticated fails", func() any {
		c := candidateFixture()
		c["binding"] = "source-commits+makefile-launcher+payload-digests"
		return expect(containsString(candidateFailures(c), "candidate:unauthenticated_manifest"), "x")
	})

	// ============================================================ GATE
	dir, err := os.MkdirTemp("", "tour-executor-selftest")
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		return 1
	}
	defer os.RemoveAll(dir)
	fx, err := buildFixture(root, dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		return 1
	}
	clean := buildFixtureLedger(fx, contract, migration)
	applicablePaths, _ := fixturePaths()
	volatilePath := applicablePaths[0]
	gateEnv := map[string]string{"TOUR_GATE_ROOT": fx.dir}
	runFixtureGate := func(records []map[string]any) (int, string) {
		ledger := filepath.Join(fx.dir, "ledger.jsonl")
		if err := writeLedger(ledger, records); err != nil {
			panic(err)
		}
		return runGate(root, ledger, gateEnv)
	}

	suite.check("gate: a well-formed 97x3 ledger with a native oracle PASSES (the gate is not merely always red)", func() any {
		code, out := runFixtureGate(clean)
		return expect(code == 0, fmt.Sprintf("exit %d: %s", code, out))
	})

	volatileObservation := func(records []map[string]any, mode string) map[string]any {
		return findRecord(records, func(r map[string]any) bool {
			return r["type"] == "observation" && r["path"] == volatilePath && r["mode"] == mode
		})
	}
	type gateCase struct {
		name, expected string
		mutate         func([]map[string]any) []map[string]any
	}
	cases := []gateCase{
		{"gate: generated runtime cannot use another sh revision", "runtime_dependency:candidate_binding", func(records []map[string]any) []map[string]any {
			asMap(records[0]["runtime_dependency"])["commit"] = strings.Repeat("f", 40)
			return records
		}},
		{"gate: compiled run cannot use the native baseline binary", "argv_identity:", func(records []map[string]any) []map[string]any {
			target := findRecord(records, isObs("compiled", "applicable_go_program"))
			baseline := findRecord(records, func(r map[string]any) bool { return isObs("baseline", "")(r) && r["path"] == target["path"] })
			if jsonEqual(lastStage(target)["command"], lastStage(baseline)["command"]) {
				panic("fixture modes must have different binaries")
			}
			lastStage(target)["command"] = deepCopy(lastStage(baseline)["command"])
			return records
		}},
		{"gate: compiled build cannot use original source instead of transpiled output", "argv_identity:", func(records []map[string]any) []map[string]any {
			target := findRecord(records, isObs("compiled", ""))
			command := asList(stageAt(target, 1)["command"])
			command[len(command)-1] = target["path"]
			return records
		}},
		{"gate: input artifact digest must match its producer", "artifact_input_identity:", func(records []map[string]any) []map[string]any {
			target := findRecord(records, isObs("compiled", ""))
			asMap(asMap(stageAt(target, 1)["inputs"])["go"])["sha256"] = strings.Repeat("f", 64)
			return records
		}},
		{"gate: output artifact path cannot impersonate another artifact", "artifact_path:", func(records []map[string]any) []map[string]any {
			target := findRecord(records, isObs("compiled", ""))
			asMap(asMap(stageAt(target, 1)["artifacts"])["bin"])["path"] = "wrong.bin"
			return records
		}},
		{"gate: candidate component commit must match repository", "candidate:component_repository:", func(records []map[string]any) []map[string]any {
			asMap(asList(asMap(records[0]["candidate"])["components"])[0])["commit"] = strings.Repeat("f", 40)
			return records
		}},
		{"gate: a MISSING observation is rejected", "missing:", func(records []map[string]any) []map[string]any {
			return deleteAt(records, findIndex(records, isObs("compiled", "")))
		}},
		{"gate: a PLANNED placeholder status is rejected", "placeholder_status:", func(records []map[string]any) []map[string]any {
			findRecord(records, isObs("", ""))["status"] = "PLANNED"
			return records
		}},
		{"gate: an unexpected not-applicable claim is rejected", "unexpected_na:", func(records []map[string]any) []map[string]any {
			findRecord(records, isObs("", ""))["not_applicable"] = "host"
			return records
		}},
		{"gate: an N/A status inside the executable denominator is rejected", "placeholder_status:", func(records []map[string]any) []map[string]any {
			findRecord(records, isObs("", ""))["status"] = "N/A"
			return records
		}},
		{"gate: a duplicated observation is rejected", "duplicate:", func(records []map[string]any) []map[string]any {
			dup := asMap(deepCopy(findRecord(records, isObs("", ""))))
			return insertAt(records, 1, dup)
		}},
		{"gate: a MISMATCHED product mode is rejected", "not_pass:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, func(r map[string]any) bool {
				return isObs("interpreted", "applicable_go_program")(r) && r["path"] != volatilePath
			})
			restate(observation, []byte("different output\n"))
			return records
		}},
		{"gate: a baseline that does not reproduce the accepted observation is rejected", "not_pass:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, func(r map[string]any) bool {
				return isObs("baseline", "applicable_go_program")(r) && r["path"] != volatilePath
			})
			lastStage(observation)["exit"] = int64(3)
			return records
		}},
		{"gate: a hand-edited PASS on a failed stage is rejected", "status_forged:", func(records []map[string]any) []map[string]any {
			stageAt(findRecord(records, isObs("compiled", "")), 0)["exit"] = int64(2)
			return records
		}},
		{"gate: a successful transpile cannot stand in for the artifact run", "stage_substitution:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("compiled", "applicable_go_program"))
			asMap(asMap(stageAt(observation, 1)["artifacts"])["bin"])["present"] = false
			return records
		}},
		{"gate: a build-only row whose no-body stage printed output is rejected", "body_executed:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("interpreted", "build_only_go_program"))
			leaked := []byte("hello from the body\n")
			s := stageAt(observation, 0)
			s["raw"] = map[string]any{"stdout_base64": b64(leaked), "stdout_bytes": int64(len(leaked)), "stderr_base64": "", "stderr_bytes": int64(0)}
			asMap(s["normalized"])["stdout"] = normalizedFor(leaked)
			return records
		}},
		{"gate: a forged command (source swapped for another row) is rejected", "argv_src:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("interpreted", "applicable_go_program"))
			argv := asList(stageAt(observation, 0)["command"])
			argv[len(argv)-1] = applicablePaths[1]
			return records
		}},
		{"gate: dropping --source=go from the recorded command is rejected", "argv_literal:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("interpreted", "applicable_go_program"))
			asList(stageAt(observation, 0)["command"])[2] = "--posix"
			return records
		}},
		{"gate: a missing transpiler source map is rejected", "source_map_missing:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("compiled", ""))
			asMap(asMap(stageAt(observation, 0)["artifacts"])["map"])["present"] = false
			return records
		}},
		{"gate: a source map with no mappings is rejected", "source_map_empty:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("compiled", ""))
			asMap(asMap(asMap(stageAt(observation, 0)["artifacts"])["map"])["source_map"])["mappings"] = int64(0)
			return records
		}},
		{"gate: a source map that does not describe its own generated artifact is rejected", "source_map_generation_digest:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("compiled", ""))
			asMap(asMap(asMap(stageAt(observation, 0)["artifacts"])["map"])["source_map"])["go_digest"] = "sha256:" + strings.Repeat("9", 64)
			return records
		}},
		{"gate: a source map pointing at another original source is rejected", "source_map_origin:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("compiled", ""))
			asMap(asMap(asMap(stageAt(observation, 0)["artifacts"])["map"])["source_map"])["origin"] = applicablePaths[2]
			return records
		}},
		{"gate: blanket normalization that erases a stream is rejected", "normalizer_drift:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, func(r map[string]any) bool {
				return isObs("baseline", "applicable_go_program")(r) && r["path"] != volatilePath
			})
			asMap(lastStage(observation)["normalized"])["stdout"] = map[string]any{"valid_utf8": true, "bytes": int64(0), "sha256": sha256hex(nil)}
			return records
		}},
		{"gate: a private capture implementation is rejected", "capture:implementation", func(records []map[string]any) []map[string]any {
			records[0]["capture_implementation"] = "tools/tour/executor.go"
			return records
		}},
		{"gate: a rebound shared capture library digest is rejected", "capture:library_sha256", func(records []map[string]any) []map[string]any {
			records[0]["capture_library_sha256"] = strings.Repeat("0", 64)
			return records
		}},
		{"gate: an unbound replaced dependency fails the candidate", "candidate:unbound:filebrowser", func(records []map[string]any) []map[string]any {
			for _, c := range asList(asMap(records[0]["candidate"])["components"]) {
				if asMap(c)["component"] == "filebrowser" {
					asMap(c)["bound"] = false
					asMap(c)["commit"] = nil
				}
			}
			records[0]["candidate_failures"] = anyList(candidateFailures(asMap(records[0]["candidate"])))
			return records
		}},
		{"gate: a manifest repository nobody declared fails the candidate", "candidate:repository_set", func(records []map[string]any) []map[string]any {
			candidate := asMap(records[0]["candidate"])
			candidate["repositories"] = append(asList(candidate["repositories"]), map[string]any{"name": "surprise", "path": "/x", "commit": strings.Repeat("c", 40)})
			records[0]["candidate_failures"] = anyList(candidateFailures(candidate))
			return records
		}},
		{"gate: a candidate that hides its own failures in the manifest is rejected", "candidate:runner_hid_failures", func(records []map[string]any) []map[string]any {
			asMap(dig(records[0], "candidate", "binaries", "payload"))["present"] = false
			return records
		}},
		{"gate: an OS-sandbox claim the corpus cannot honour is rejected", "input_absence:os_sandbox_claimed", func(records []map[string]any) []map[string]any {
			asMap(records[0]["environment"])["os_sandbox"] = true
			return records
		}},
		{"gate: a weakened input-absence scope claim is rejected", "input_absence:scope", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("baseline", "applicable_go_program"))
			asMap(lastStage(observation)["input_absence"])["scope"] = "fully sandboxed"
			return records
		}},
		{"gate: a native body stage that ran in the source directory is rejected", "input_absence:cwd", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("compiled", "applicable_go_program"))
			lastStage(observation)["cwd"] = "module"
			asMap(lastStage(observation)["input_absence"])["cwd"] = "module"
			return records
		}},
		{"gate: a body stage with a populated PATH is rejected", "input_absence:path", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, isObs("interpreted", "applicable_go_program"))
			lastStage(observation)["path_env"] = "/usr/bin:/bin"
			return records
		}},
		{"gate: a partial ledger cannot stand in for a full run", "ledger:partial", func(records []map[string]any) []map[string]any {
			records[0]["partial"] = true
			return records
		}},
		{"gate: a rebound inventory row digest is rejected", "denominator:inventory_data_sha256", func(records []map[string]any) []map[string]any {
			asMap(records[0]["inventory"])["data_sha256"] = strings.Repeat("f", 64)
			return records
		}},
		{"gate: a rebound inventory file digest is rejected", "binding:inventory:sha256", func(records []map[string]any) []map[string]any {
			asMap(records[0]["inventory"])["sha256"] = strings.Repeat("f", 64)
			return records
		}},
		{"gate: a swapped normalizer binding is rejected", "binding:normalizer:sha256", func(records []map[string]any) []map[string]any {
			asMap(records[0]["normalizer"])["sha256"] = strings.Repeat("0", 64)
			return records
		}},
		{"gate: a rebound phase-migration table is rejected", "binding:phase_migration:sha256", func(records []map[string]any) []map[string]any {
			asMap(records[0]["phase_migration"])["sha256"] = strings.Repeat("0", 64)
			return records
		}},
		{"gate: a rewritten historical phase token on an observation is rejected", "historical_phase_drift:", func(records []map[string]any) []map[string]any {
			findRecord(records, isObs("compiled", "build_only_go_program"))["historical_phase_token"] = "transpile-build-no-run"
			return records
		}},
		{"gate: a ledger claiming the volatility MEASUREMENT table excuses a mismatch is rejected", "volatility:claims_gate_effect", func(records []map[string]any) []map[string]any {
			asMap(records[0]["volatility"])["gate_effect"] = "waives-mismatch"
			return records
		}},
		{"gate: an undeclared volatility annotation is rejected", "volatility_undeclared:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, func(r map[string]any) bool { return r["type"] == "observation" && r["path"] == applicablePaths[5] })
			observation["volatility"] = map[string]any{"volatile_element": "invented", "comparator_needed": "none"}
			return records
		}},
		{"gate: an observation-level waiver is rejected", "unexpected_na:", func(records []map[string]any) []map[string]any {
			findRecord(records, isObs("", ""))["expected_failure"] = "unimplemented"
			return records
		}},
		{"gate: an off-pin Go toolchain identity is rejected", "toolchain:identity", func(records []map[string]any) []map[string]any {
			asMap(records[0]["go"])["identity"] = "go version go1.26.0 darwin/arm64"
			return records
		}},
		// ---- semantic comparator forgery
		{"gate: a FORGED semantic verdict over wrong output is rejected", "semantic_forged:", func(records []map[string]any) []map[string]any {
			restate(volatileObservation(records, "interpreted"), []byte("totally different\n"))
			return records // `semantic.ok` stays true; the gate recomputes it
		}},
		{"gate: a semantic verdict flipped to ok is rejected", "semantic_forged:", func(records []map[string]any) []map[string]any {
			observation := volatileObservation(records, "compiled")
			restate(observation, []byte("totally different\n"))
			asMap(observation["semantic"])["ok"] = true
			asMap(observation["semantic"])["findings"] = []any{}
			return records
		}},
		// An HONESTLY recomputed semantic verdict over wrong output must still FAIL.
		{"gate: wrong output on a volatile row still FAILS, comparator and all", "not_pass:", func(records []map[string]any) []map[string]any {
			observation := volatileObservation(records, "interpreted")
			restate(observation, []byte("totally different\n"))
			table, _ := loadSemanticsTable(filepath.Join(fx.dir, "docs/tour/semantics.tsv"), nil)
			row := table[volatilePath]
			oracleRecord := findRecord(records, func(r map[string]any) bool { return r["type"] == "oracle" && r["path"] == volatilePath })
			oracle := []Observation{}
			for _, r := range asList(oracleRecord["runs"]) {
				oracle = append(oracle, Observation{Exit: asMap(r)["exit"], Stdout: string(b64decode(asString(asMap(r)["stdout_base64"]))), Stderr: ""})
			}
			final := lastStage(observation)
			verdict := compareSemantic(row, Observation{Exit: final["exit"], Stdout: string(b64decode(toS(dig(final, "raw", "stdout_base64")))), Stderr: ""},
				oracle, asMap(observation["window"]), semanticsVersion)
			verdict["stage"] = final["stage"]
			observation["semantic"] = verdict
			first := ""
			if f := asList(verdict["findings"]); len(f) > 0 {
				first = toS(f[0])
			}
			observation["status"] = "FAIL:semantic:" + first
			return records
		}},
		{"gate: a semantic verdict claimed for an undeclared row is rejected", "semantic_undeclared:", func(records []map[string]any) []map[string]any {
			observation := findRecord(records, func(r map[string]any) bool {
				return r["type"] == "observation" && r["path"] == applicablePaths[7] && r["mode"] == "baseline"
			})
			observation["semantic"] = map[string]any{"comparator": "line_set", "version": semanticsVersion, "ok": true, "findings": []any{}, "evidence": map[string]any{}}
			return records
		}},
		{"gate: a volatile row with no oracle record is rejected", "oracle:row_set", func(records []map[string]any) []map[string]any {
			return deleteAt(records, findIndex(records, func(r map[string]any) bool { return r["type"] == "oracle" }))
		}},
		{"gate: an oracle thinner than the declared minimum is rejected", "oracle:repeats", func(records []map[string]any) []map[string]any {
			oracle := findRecord(records, func(r map[string]any) bool { return r["type"] == "oracle" })
			oracle["runs"] = asList(oracle["runs"])[:3]
			oracle["repeats"] = int64(3)
			return records
		}},
		{"gate: an oracle that is not repeats of the built artifact is rejected", "oracle_binary_mismatch:", func(records []map[string]any) []map[string]any {
			asMap(findRecord(records, func(r map[string]any) bool { return r["type"] == "oracle" })["binary"])["sha256"] = strings.Repeat("7", 64)
			return records
		}},
		{"gate: an oracle bound to another source digest is rejected", "oracle:source_binding:", func(records []map[string]any) []map[string]any {
			findRecord(records, func(r map[string]any) bool { return r["type"] == "oracle" })["source_sha256"] = strings.Repeat("8", 64)
			return records
		}},
		{"gate: a widened comparison window is rejected", "semantic_window_forged:", func(records []map[string]any) []map[string]any {
			observation := volatileObservation(records, "baseline")
			window := asMap(observation["window"])
			window["to"] = asFloat(window["to"]) + 100000
			return records
		}},
		{"gate: an oracle run that leaked a process is rejected", "oracle:run_not_clean:", func(records []map[string]any) []map[string]any {
			asMap(asList(findRecord(records, func(r map[string]any) bool { return r["type"] == "oracle" })["runs"])[0])["descendants_survived"] = true
			return records
		}},
	}
	for _, c := range cases {
		c := c
		suite.check(c.name, func() any {
			records := c.mutate(deepCopyRecords(clean))
			code, out := runFixtureGate(reseal(records))
			if code == 0 {
				return "gate passed (exit 0)\n" + out
			}
			return expect(strings.Contains(out, c.expected), fmt.Sprintf("expected finding %s, got:\n%s", inspectString(c.expected), out))
		})
	}

	// A mutation of a REFERENCE FILE rather than the ledger.
	suite.check("gate: rewriting the pinned historical schema to agree with the new phase is rejected", func() any {
		inventoryPath := filepath.Join(fx.dir, "tests/tour/inventory.tsv")
		original := readFile(inventoryPath)
		defer os.WriteFile(inventoryPath, original, 0o644)
		os.WriteFile(inventoryPath, []byte(strings.ReplaceAll(string(original), "bpp_compiled:transpile-build-run", "bpp_compiled:transpile-build-no-run")), 0o644)
		code, out := runFixtureGate(clean)
		if code == 0 {
			return "gate passed (exit 0)"
		}
		return expect(strings.Contains(out, "phase_migration:historical_drift") || strings.Contains(out, "binding:inventory:sha256"), out)
	})

	// A tampered root must be caught even though everything else balances.
	suite.check("gate: a tampered root hash is rejected", func() any {
		records := deepCopyRecords(clean)
		records[len(records)-2]["sha256"] = strings.Repeat("1", 64)
		records[len(records)-1]["root_sha256"] = strings.Repeat("1", 64)
		code, out := runFixtureGate(records)
		if code == 0 {
			return "gate passed (exit 0)"
		}
		return expect(strings.Contains(out, "root:tampered"), out)
	})

	suite.check("gate: a forged PASS verdict over failing observations is rejected", func() any {
		records := deepCopyRecords(clean)
		lastStage(findRecord(records, isObs("", "")))["exit"] = int64(9)
		sealed := reseal(records)
		sealed[len(sealed)-1]["value"] = "PASS"
		code, out := runFixtureGate(sealed)
		if code == 0 {
			return "gate passed (exit 0)"
		}
		return expect(strings.Contains(out, "verdict:forged") || strings.Contains(out, "not_pass:"), out)
	})

	fmt.Printf("tour executor selftests: %d passed, %d failed\n", len(suite.passed), len(suite.failed))
	for _, f := range suite.failed {
		fmt.Fprintf(os.Stderr, "  FAIL %s\n", f)
	}
	if len(suite.failed) == 0 {
		return 0
	}
	return 1
}

func stageNames(stages []Stage) []string {
	out := []string{}
	for _, s := range stages {
		out = append(out, s.Stage)
	}
	return out
}

func noneExecutes(stages []Stage) bool {
	for _, s := range stages {
		if s.ExecuteBody {
			return false
		}
	}
	return true
}

func anyHasPrefix(list []string, prefix string) bool {
	for _, s := range list {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}
