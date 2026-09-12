// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Offline gate for the tour-executor/v2 ledger — the port of
// tools/tour/executor-gate.rb (Sprint 118 / Story #4 / Story-ID 759341a95870).
//
// The gate trusts NOTHING the runner wrote about itself. Every field it acts
// on is re-derived from files the gate reads independently (the contract, the
// phase-migration table, the inventory, the accepted baseline, the pins, the
// normalizer, the semantic comparator table) or recomputed from the ledger's
// own raw bytes. It fails closed on missing, PLANNED, unexpected N/A and
// mismatched observations, plus every forgery class listed in
// docs/tour/executor.md.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// The longest wall-clock interval a single row's observations may claim.
const maxWindowSeconds = 900.0

// The retained Candidate018/021/022/023 ledgers were sealed with v1. Keep the
// exact digest as an authentication key.
var legacySemanticsLibraries = map[string]string{
	semanticsLegacyVersion: "18bbf973a54ce0dd5ef1c62d564e31eac25bb9c2655658cd8f3c420d78240dce",
}
var legacySemanticsTables = map[string]string{
	semanticsLegacyVersion: "4039f378a63ebaf50b28fabb488a9c5be2cb2f2e77d43b8dde2cbcd8b11d9015",
}

var sha256RE = regexp.MustCompile(`\A[0-9a-f]{64}\z`)

type gate struct {
	failures []string
}

func (g *gate) bad(reason string) {
	g.failures = append(g.failures, reason)
}

func abortf(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	return 1
}

func cmdExecutorGate(root string) int {
	// Directory holding the reference pins/inventory/contract the gate
	// re-derives from. ALWAYS this repository in real use; the selftests point
	// it at a synthetic fixture tree.
	refs := envOr("TOUR_GATE_ROOT", root)
	ledgerPath := envOr("TOUR_EXECUTOR_RESULTS", filepath.Join(root, "tests/tour/executor-results.jsonl"))
	g := &gate{}

	if !fileExists(ledgerPath) {
		return abortf("FATAL: missing ledger %s", ledgerPath)
	}
	records, err := readLedger(ledgerPath)
	if err != nil {
		return abortf("FATAL: unreadable ledger: %v", err)
	}
	if len(records) < 4 {
		return abortf("FATAL: malformed ledger envelope")
	}
	manifest := records[0]
	if manifest["type"] != "manifest" {
		return abortf("FATAL: ledger does not begin with a manifest")
	}
	if manifest["schema"] != executorSchema {
		return abortf("FATAL: schema mismatch (%s)", toS(manifest["schema"]))
	}
	summary, rootRecord, verdict := records[len(records)-3], records[len(records)-2], records[len(records)-1]
	if summary["type"] != "summary" || rootRecord["type"] != "root" || verdict["type"] != "verdict" {
		return abortf("FATAL: malformed ledger envelope")
	}

	// --- 1. binding: every pin the manifest names is re-hashed here
	for _, binding := range []struct{ key, path string }{
		{"contract", "docs/tour/executor-contract.tsv"},
		{"phase_migration", "docs/tour/phase-migration.tsv"},
		{"inventory", "tests/tour/inventory.tsv"},
		{"accepted_baseline", "tests/tour/results.tsv"},
		{"source_pin", "docs/tour/pin.tsv"},
		{"corpus", "docs/tour/corpus.tsv"},
	} {
		declared := dig(manifest, binding.key, "path")
		if declared != binding.path {
			g.bad(fmt.Sprintf("binding:%s:path=%s", binding.key, toS(declared)))
		}
		if !jsonEqual(dig(manifest, binding.key, "sha256"), shaFile(filepath.Join(refs, binding.path))) {
			g.bad(fmt.Sprintf("binding:%s:sha256", binding.key))
		}
	}
	// The normalizer binding: the Go implementation on disk, or — for a
	// ledger sealed by the retired Ruby harness — exactly the retired script's
	// frozen digest under its own path.
	normalizerDeclared := toS(dig(manifest, "normalizer", "path"))
	switch normalizerDeclared {
	case normalizerPath:
		if !jsonEqual(dig(manifest, "normalizer", "sha256"), shaFile(filepath.Join(refs, normalizerPath))) {
			g.bad("binding:normalizer:sha256")
		}
	case retiredRubyNormalizerPath:
		if !jsonEqual(dig(manifest, "normalizer", "sha256"), retiredRubyNormalizerSHA256) {
			g.bad("binding:normalizer:sha256")
		}
	default:
		g.bad("binding:normalizer:path=" + normalizerDeclared)
		g.bad("binding:normalizer:sha256")
	}
	if dig(manifest, "volatility", "path") != "docs/tour/volatility.tsv" {
		g.bad("binding:volatility:path")
	}
	if !jsonEqual(dig(manifest, "volatility", "sha256"), shaFile(filepath.Join(refs, "docs/tour/volatility.tsv"))) {
		g.bad("binding:volatility:sha256")
	}
	if dig(manifest, "volatility", "gate_effect") != "measurement-record" {
		g.bad("volatility:claims_gate_effect")
	}
	if dig(manifest, "semantics", "gate_effect") != "semantic-comparator" {
		g.bad("semantics:gate_effect")
	}
	ledgerSemanticsVersion := toS(dig(manifest, "semantics", "version"))
	supported := []string{semanticsVersion, semanticsLegacyVersion}
	if !containsString(supported, ledgerSemanticsVersion) {
		g.bad("semantics:version")
	}
	ledgerComparisonVersion := semanticsVersion
	if containsString(supported, ledgerSemanticsVersion) {
		ledgerComparisonVersion = ledgerSemanticsVersion
	}
	if dig(manifest, "semantics", "path") != "docs/tour/semantics.tsv" {
		g.bad("binding:semantics:path")
	}
	expectedSemanticsTable := ""
	if ledgerSemanticsVersion == semanticsVersion {
		expectedSemanticsTable = shaFile(filepath.Join(refs, "docs/tour/semantics.tsv"))
	} else {
		expectedSemanticsTable = legacySemanticsTables[ledgerSemanticsVersion]
	}
	if !(expectedSemanticsTable != "" && jsonEqual(dig(manifest, "semantics", "sha256"), expectedSemanticsTable)) {
		g.bad("binding:semantics:sha256")
	}
	libraryOK := false
	if ledgerSemanticsVersion == semanticsVersion {
		declaredLibrary := toS(dig(manifest, "semantics", "library_sha256"))
		libraryOK = declaredLibrary == shaFile(filepath.Join(refs, semanticsLibraryPath)) ||
			declaredLibrary == retiredRubySemanticsLibrarySHA256
	} else if expected := legacySemanticsLibraries[ledgerSemanticsVersion]; expected != "" {
		libraryOK = jsonEqual(dig(manifest, "semantics", "library_sha256"), expected)
	}
	if !libraryOK {
		g.bad("semantics:library_sha256")
	}
	if !jsonEqual(dig(manifest, "accepted_baseline", "pin_sha256"), shaFile(filepath.Join(refs, "docs/tour/baseline-pin.tsv"))) {
		g.bad("binding:baseline_pin")
	}
	if dig(manifest, "normalizer", "version") != normalizerVersion {
		g.bad("binding:normalizer_version")
	}
	if truthy(manifest["partial"]) {
		g.bad("ledger:partial")
	}

	// -- the streams must have come from the SHARED capture primitive.
	captureOK := false
	switch manifest["capture_implementation"] {
	case captureImplementation:
		captureOK = jsonEqual(manifest["capture_library_sha256"], shaFile(filepath.Join(refs, captureLibraryPath)))
	case retiredRubyCaptureImplementation:
		captureOK = jsonEqual(manifest["capture_library_sha256"], retiredRubyCaptureLibrarySHA256)
	default:
		g.bad("capture:implementation=" + toS(manifest["capture_implementation"]))
	}
	if !captureOK {
		g.bad("capture:library_sha256")
	}

	contract, err := loadContract(filepath.Join(refs, "docs/tour/executor-contract.tsv"))
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	migration, err := loadPhaseMigration(filepath.Join(refs, "docs/tour/phase-migration.tsv"))
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	inventory, err := loadInventory(filepath.Join(refs, "tests/tour/inventory.tsv"))
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	items := map[string]Item{}
	itemOrder := []string{}
	for _, item := range inventory.Items {
		items[item.Path] = item
		itemOrder = append(itemOrder, item.Path)
	}
	accepted := loadAccepted(filepath.Join(refs, "tests/tour/results.tsv"))
	pin := tsvRows(filepath.Join(refs, "docs/tour/pin.tsv"))[0]
	tc := tsvRows(filepath.Join(refs, "docs/tour/toolchain.tsv"))[0]
	declaredVolatility := map[string]map[string]any{}
	for _, row := range tsvRows(filepath.Join(refs, "docs/tour/volatility.tsv")) {
		declaredVolatility[field(row, 0)] = map[string]any{"volatile_element": field(row, 1), "comparator_needed": field(row, 2)}
	}
	inventoryDigests := map[string]string{}
	for path, item := range items {
		inventoryDigests[path] = item.SHA256
	}
	semantics, err := loadSemanticsTable(filepath.Join(refs, "docs/tour/semantics.tsv"), inventoryDigests)
	if err != nil {
		g.bad("semantics:table:" + err.Error())
		semantics = map[string]*SemanticRow{}
	}
	semanticKeys := sortedKeys(mapKeysAny(semantics))
	volatilityKeys := []string{}
	for k := range declaredVolatility {
		volatilityKeys = append(volatilityKeys, k)
	}
	sort.Strings(volatilityKeys)
	if !equalStrings(semanticKeys, volatilityKeys) {
		g.bad("semantics:row_set")
	}

	if !(jsonEqual(dig(manifest, "inventory", "data_sha256"), inventory.DataSHA256) && inventory.DataSHA256 == field(pin, 7)) {
		g.bad("denominator:inventory_data_sha256")
	}
	if len(items) != denominator {
		g.bad(fmt.Sprintf("denominator:executable=%d", len(items)))
	}
	applicable, buildOnly := 0, 0
	for _, item := range items {
		if item.Applicability == "applicable_go_program" {
			applicable++
		} else if item.Applicability == "build_only_go_program" {
			buildOnly++
		}
	}
	if applicable != applicableRows {
		g.bad("denominator:applicable")
	}
	if buildOnly != buildOnlyRows {
		g.bad("denominator:build_only")
	}
	if !jsonEqual(dig(manifest, "inventory", "executable_programs"), int64(denominator)) {
		g.bad("denominator:manifest_full97")
	}

	// --- 2. phase contract: both ends of the migration table
	for _, f := range phaseMigrationFailures(migration, contract, inventory.Items) {
		g.bad(f)
	}
	for _, key := range migrationKeys(migration) {
		if key.applicability == "build_only_go_program" && migration[key].ExecutesBody {
			g.bad("phase_migration:body_allowed:" + key.mode)
		}
	}

	// --- 3. pinned Go baseline identity
	if dig(manifest, "go", "identity") != tc[3] {
		g.bad("toolchain:identity")
	}
	if dig(manifest, "go", "sha256") != tc[4] {
		g.bad("toolchain:sha256")
	}

	// --- 4. helper module provisioning
	helper := tsvRows(filepath.Join(refs, "docs/tour/helpers.tsv"))[0]
	for _, f := range []struct {
		name string
		i    int
	}{{"module", 0}, {"version", 1}, {"license", 2}, {"go_mod_sum", 3}, {"zip_sum", 4}} {
		if dig(manifest, "helper_module", f.name) != helper[f.i] {
			g.bad("helper:" + f.name)
		}
	}
	if !jsonEqual(dig(manifest, "helper_module", "packages"), anyList(strings.Split(helper[5], ","))) {
		g.bad("helper:packages")
	}
	if toS(dig(manifest, "helper_module", "materialized_dir")) == "" {
		g.bad("helper:not_materialized")
	}

	// --- 5. candidate provenance (manifest-authenticated)
	candidate := asMap(manifest["candidate"])
	if candidate == nil {
		candidate = map[string]any{}
	}
	if !jsonEqual(candidate["contract_sha256"], shaFile(filepath.Join(refs, "docs/tour/candidate.tsv"))) {
		g.bad("candidate:contract_sha256")
	}
	declaredContract := loadCandidateContract(filepath.Join(refs, "docs/tour/candidate.tsv"))
	declaredComponents := []string{}
	for _, c := range declaredContract {
		declaredComponents = append(declaredComponents, asString(c["component"]))
	}
	sort.Strings(declaredComponents)
	componentNames := []string{}
	for _, c := range asList(candidate["components"]) {
		componentNames = append(componentNames, asString(asMap(c)["component"]))
	}
	if !equalStrings(sortedCopy(componentNames), declaredComponents) {
		g.bad("candidate:component_set")
	}
	repoNames := []string{}
	for _, r := range asList(candidate["repositories"]) {
		repoNames = append(repoNames, asString(asMap(r)["name"]))
	}
	if !equalStrings(sortedCopy(repoNames), declaredComponents) {
		g.bad("candidate:repository_set")
	}
	for _, expected := range declaredContract {
		name := asString(expected["component"])
		component := map[string]any{}
		for _, c := range asList(candidate["components"]) {
			if asString(asMap(c)["component"]) == name {
				component = asMap(c)
				break
			}
		}
		agrees := true
		for k, v := range expected {
			if !jsonEqual(component[k], v) {
				agrees = false
			}
		}
		if !agrees {
			g.bad("candidate:component_contract:" + name)
		}
		repository := map[string]any{}
		for _, r := range asList(candidate["repositories"]) {
			if asString(asMap(r)["name"]) == name {
				repository = asMap(r)
				break
			}
		}
		if !(jsonEqual(component["commit"], repository["commit"]) && jsonEqual(component["dir"], repository["path"])) {
			g.bad("candidate:component_repository:" + name)
		}
	}
	for _, reason := range candidateFailures(candidate) {
		g.bad(reason)
	}
	if dep, err := runtimeDependency(candidate); err != nil {
		g.bad("runtime_dependency:" + err.Error())
	} else if !jsonEqual(manifest["runtime_dependency"], dep) {
		g.bad("runtime_dependency:candidate_binding")
	}
	if summary["candidate_reauthenticated"] != true {
		g.bad("candidate:not_reauthenticated")
	}
	if !equalStrings(sortedCopy(strList(manifest["candidate_failures"])), sortedCopy(candidateFailures(candidate))) {
		g.bad("candidate:runner_hid_failures")
	}
	// The honest-scope claim, at manifest level.
	if truthy(dig(manifest, "environment", "os_sandbox")) {
		g.bad("input_absence:os_sandbox_claimed")
	}
	if dig(manifest, "environment", "input_absence_scope") != inputAbsenceScope {
		g.bad("input_absence:scope")
	}

	// --- 6. the native oracle
	runWindow := asMap(manifest["run_window"])
	oracleRecords := []map[string]any{}
	oracles := map[string]map[string]any{}
	oracleOrder := []string{}
	observations := []map[string]any{}
	for _, r := range records {
		switch r["type"] {
		case "oracle":
			oracleRecords = append(oracleRecords, r)
			path := asString(r["path"])
			if _, seen := oracles[path]; !seen {
				oracleOrder = append(oracleOrder, path)
			}
			oracles[path] = r
		case "observation":
			observations = append(observations, r)
		}
	}
	if len(oracleRecords) != len(oracles) {
		g.bad("oracle:duplicate")
	}
	oracleKeys := sortedCopy(oracleOrder)
	if !equalStrings(oracleKeys, semanticKeys) {
		g.bad(fmt.Sprintf("oracle:row_set:%s", inspect(subtract(oracleKeys, semanticKeys))))
	}
	for _, path := range oracleOrder {
		oracle := oracles[path]
		row, ok := semantics[path]
		if !ok {
			g.bad("oracle:undeclared:" + path)
			continue
		}
		if oracle["comparator"] != row.Comparator {
			g.bad("oracle:comparator:" + path)
		}
		if !(oracle["source_sha256"] == row.SourceSHA256 && oracle["source_sha256"] == items[path].SHA256) {
			g.bad("oracle:source_binding:" + path)
		}
		runs := asList(oracle["runs"])
		if !(int64(len(runs)) == toI(oracle["repeats"]) && isInteger(oracle["repeats"]) && len(runs) >= minOracleRuns) {
			g.bad(fmt.Sprintf("oracle:repeats:%s:%d", path, len(runs)))
		}
		for _, item := range runs {
			r := asMap(item)
			if !(truthy(r["spawned"]) && r["state"] == "exited" && !truthy(r["descendants_survived"])) {
				g.bad(fmt.Sprintf("oracle:run_not_clean:%s:%s", path, toS(r["index"])))
			}
			for _, stream := range []string{"stdout", "stderr"} {
				decoded := b64decode(toS(r[stream+"_base64"]))
				if !jsonEqual(int64(len(decoded)), r[stream+"_bytes"]) {
					g.bad(fmt.Sprintf("oracle:raw_bytes:%s:%s:%s", path, toS(r["index"]), stream))
				}
			}
		}
	}

	// --- 7. observations: completeness, statuses, commands, normalization
	type obsKey struct{ path, mode string }
	seen := map[obsKey]map[string]any{}
	seenOrder := []obsKey{}
	for _, observation := range observations {
		key := obsKey{asString(observation["path"]), asString(observation["mode"])}
		if _, dup := seen[key]; dup {
			g.bad(fmt.Sprintf("duplicate:%s/%s", key.path, key.mode))
		} else {
			seenOrder = append(seenOrder, key)
		}
		seen[key] = observation
	}
	for _, path := range itemOrder {
		for _, mode := range modes {
			if _, ok := seen[obsKey{path, mode}]; !ok {
				g.bad(fmt.Sprintf("missing:%s/%s", path, mode))
			}
		}
	}
	for _, key := range seenOrder {
		if _, ok := items[key.path]; !ok {
			g.bad("unknown_row:" + key.path)
		}
		if !containsString(modes, key.mode) {
			g.bad("unknown_mode:" + key.mode)
		}
	}
	if len(observations) != observationsFull {
		g.bad(fmt.Sprintf("observations=%d", len(observations)))
	}

	baselines := map[string]map[string]any{}
	for key, o := range seen {
		if key.mode == "baseline" {
			baselines[key.path] = o
		}
	}
	effectiveStatuses := []string{}

	for _, observation := range observations {
		path, mode := asString(observation["path"]), asString(observation["mode"])
		tag := path + "/" + mode
		item, ok := items[path]
		if !ok {
			continue
		}

		// -- unexpected N/A and placeholder statuses
		status := toS(observation["status"])
		upper := strings.ToUpper(status)
		if containsString(forbiddenStatuses, upper) || strings.HasPrefix(upper, "PLANNED") || strings.HasPrefix(upper, "N/A") || strings.HasPrefix(upper, "NOT_APPLICABLE") {
			g.bad(fmt.Sprintf("placeholder_status:%s:%s", tag, status))
			continue
		}
		for _, escape := range []string{"not_applicable", "na_reason", "exempt", "exempt_reason", "waived", "expected_failure", "allowed_failure"} {
			if truthy(observation[escape]) {
				g.bad(fmt.Sprintf("unexpected_na:%s:%s", tag, escape))
			}
		}
		if truthy(observation["volatility"]) {
			if declared, ok := declaredVolatility[path]; !ok || !jsonEqual(declared, observation["volatility"]) {
				g.bad("volatility_undeclared:" + tag)
			}
		}
		if item.Exception != "none" {
			g.bad(fmt.Sprintf("unexpected_exception:%s:%s", tag, item.Exception))
		}
		if observation["applicability"] != item.Applicability {
			g.bad("applicability_drift:" + tag)
		}
		if observation["differential_schema"] != item.DifferentialSchema {
			g.bad("schema_drift:" + tag)
		}
		if !(dig(observation, "source", "sha256") == item.SHA256 && jsonEqual(dig(observation, "source", "bytes"), item.Bytes)) {
			g.bad("source_drift:" + tag)
		}

		recipe := contract[modeKey{item.Applicability, mode}]
		migrationRow := migration[modeKey{item.Applicability, mode}]
		if observation["phase"] != recipe.Phase {
			g.bad("phase_drift:" + tag)
		}
		if observation["historical_phase_token"] != migrationRow.HistoricalToken {
			g.bad("historical_phase_drift:" + tag)
		}
		stages := asList(observation["stages"])
		if len(stages) != len(recipe.Stages) {
			g.bad("stage_count:" + tag)
		}

		evidenceRoot := toS(manifest["evidence_root"])
		artifactDir := filepath.Join(evidenceRoot, mode, slug(path), "artifacts")
		expectedSubs := substitutions(path, toS(dig(candidate, "binaries", "launcher", "path")), toS(dig(manifest, "go", "path")), artifactDir)
		if !strings.HasPrefix(evidenceRoot, "/") {
			g.bad("artifact_root:missing_or_relative")
		}
		// -- forged commands: re-render argv from the contract itself
		for i, item := range stages {
			if i >= len(recipe.Stages) {
				break
			}
			stage := asMap(item)
			spec := recipe.Stages[i]
			if !(stage["stage"] == spec.Stage && jsonEqual(stage["index"], spec.Index)) {
				g.bad(fmt.Sprintf("stage_name:%s:%d", tag, i))
			}
			if !jsonEqual(stage["execute_body"], spec.ExecuteBody) {
				g.bad(fmt.Sprintf("execute_body_drift:%s:%s", tag, spec.Stage))
			}
			template := spec.ArgvTemplate
			got := strList(stage["command"])
			if !jsonEqual(stage["command"], anyList(mustRenderArgv(template, expectedSubs))) {
				g.bad(fmt.Sprintf("argv_identity:%s:%s", tag, spec.Stage))
			}
			if len(got) != len(template) {
				g.bad(fmt.Sprintf("argv_shape:%s:%s", tag, spec.Stage))
			}
			for j, token := range template {
				if placeholderRE.MatchString(token) {
					continue
				}
				if j >= len(got) || got[j] != token {
					g.bad(fmt.Sprintf("argv_literal:%s:%s:%d", tag, spec.Stage, j))
				}
			}
			if at := indexOf(template, "{SRC}"); at >= 0 && (at >= len(got) || got[at] != path) {
				g.bad(fmt.Sprintf("argv_src:%s:%s", tag, spec.Stage))
			}
			if at := indexOf(template, "{GO}"); at >= 0 && (at >= len(got) || got[at] != toS(dig(manifest, "go", "path"))) {
				g.bad(fmt.Sprintf("argv_go:%s:%s", tag, spec.Stage))
			}
			if at := indexOf(template, "{BASHY}"); at >= 0 && (at >= len(got) || got[at] != toS(dig(candidate, "binaries", "launcher", "path"))) {
				g.bad(fmt.Sprintf("argv_bashy:%s:%s", tag, spec.Stage))
			}
			artifacts := asMap(stage["artifacts"])
			if !equalStrings(sortedKeys(artifacts), sortedCopy(spec.Produces)) {
				g.bad(fmt.Sprintf("artifact_set:%s:%s", tag, spec.Stage))
			}
			for _, name := range sortedKeys(artifacts) {
				artifact := asMap(artifacts[name])
				key, known := artifactKey[name]
				if !known || artifact["path"] != filepath.Base(expectedSubs[key]) {
					g.bad(fmt.Sprintf("artifact_path:%s:%s", tag, name))
				}
				if truthy(artifact["present"]) {
					bytesOK := isInteger(artifact["bytes"]) && toI(artifact["bytes"]) > 0
					if !(sha256RE.MatchString(toS(artifact["sha256"])) && bytesOK) {
						g.bad(fmt.Sprintf("artifact_digest:%s:%s", tag, name))
					}
				}
			}
			if truthy(stage["spawned"]) {
				inputs := asMap(stage["inputs"])
				if !equalStrings(sortedKeys(inputs), sortedCopy(consumedArtifacts(spec))) {
					g.bad(fmt.Sprintf("artifact_input_set:%s:%s", tag, spec.Stage))
				}
				for _, name := range sortedKeys(inputs) {
					input := asMap(inputs[name])
					var produced map[string]any
					for p := i - 1; p >= 0; p-- {
						previous := asMap(stages[p])
						if a, ok := asMap(previous["artifacts"])[name]; ok {
							produced = asMap(a)
							break
						}
					}
					identical := produced != nil && truthy(input["present"])
					if identical {
						for _, f := range []string{"present", "bytes", "sha256", "path"} {
							if !jsonEqual(input[f], produced[f]) {
								identical = false
							}
						}
					}
					if !identical {
						g.bad(fmt.Sprintf("artifact_input_identity:%s:%s", tag, name))
					}
				}
			}

			// -- no body execution on a `norun`/build obligation
			if !spec.ExecuteBody && jsonEqual(stage["exit"], int64(0)) && toI(dig(stage, "normalized", "stdout", "bytes")) > 0 {
				g.bad(fmt.Sprintf("body_executed:%s:%s", tag, spec.Stage))
			}

			// -- the input-absence claim: exactly the scope the corpus can honour.
			if spec.ExecuteBody && stage["state"] != "not_reached" {
				absence := asMap(stage["input_absence"])
				if absence["scope"] != inputAbsenceScope {
					g.bad("input_absence:scope:" + tag)
				}
				if truthy(absence["os_sandbox"]) {
					g.bad("input_absence:os_sandbox_claimed:" + tag)
				}
				if !(stage["path_env"] == "" && absence["path_env"] == "") {
					g.bad("input_absence:path:" + tag)
				}
				expectedCwd := "runtime"
				if mode == "interpreted" {
					expectedCwd = "module"
				}
				if !(stage["cwd"] == expectedCwd && absence["cwd"] == expectedCwd) {
					g.bad(fmt.Sprintf("input_absence:cwd:%s:%s", tag, toS(stage["cwd"])))
				}
			}

			// -- normalization audit, recomputed from the stored raw bytes
			for _, stream := range []string{"stdout", "stderr"} {
				raw := b64decode(toS(dig(stage, "raw", stream+"_base64")))
				if !jsonEqual(int64(len(raw)), dig(stage, "raw", stream+"_bytes")) {
					g.bad(fmt.Sprintf("raw_bytes:%s:%s:%s", tag, spec.Stage, stream))
				}
				expected, valid := auditNormalize(raw)
				recorded := asMap(dig(stage, "normalized", stream))
				if !valid {
					if truthy(recorded["valid_utf8"]) {
						g.bad(fmt.Sprintf("utf8_claim:%s:%s:%s", tag, spec.Stage, stream))
					}
				} else {
					if !(truthy(recorded["valid_utf8"]) && jsonEqual(recorded["bytes"], int64(len(expected))) &&
						recorded["sha256"] == sha256hex(expected)) {
						g.bad(fmt.Sprintf("normalizer_drift:%s:%s:%s", tag, spec.Stage, stream))
					}
					// Blanket masking: the declared v1 rules can only delete CR bytes
					// and shrink pointer literals.
					if len(raw) > 0 && (len(expected) == 0 || len(expected)*4 < len(raw)*3) {
						g.bad(fmt.Sprintf("blanket_masking:%s:%s:%s", tag, spec.Stage, stream))
					}
				}
			}
		}

		// -- stage substitution
		for i := 1; i < len(stages); i++ {
			stage := asMap(stages[i])
			previous := asMap(stages[i-1])
			if truthy(stage["spawned"]) {
				absent := false
				for _, a := range asMap(previous["artifacts"]) {
					if !truthy(asMap(a)["present"]) {
						absent = true
					}
				}
				if !jsonEqual(previous["exit"], int64(0)) || absent {
					g.bad(fmt.Sprintf("stage_substitution:%s:%s", tag, toS(stage["stage"])))
				}
			}
		}

		// -- source map preservation
		for _, s := range stages {
			stage := asMap(s)
			if stage["stage"] == "transpile" {
				if jsonEqual(stage["exit"], int64(0)) {
					for _, f := range sourceMapFailures(stage, path) {
						g.bad(f + ":" + tag)
					}
				}
				break
			}
		}

		// -- the semantic verdict, recomputed independently
		semanticRow := semantics[path]
		var currentSemantic map[string]any
		if truthy(observation["semantic"]) && semanticRow == nil {
			g.bad("semantic_undeclared:" + tag)
		} else if semanticRow != nil {
			oracle, ok := oracles[path]
			if !ok {
				g.bad("semantic_no_oracle:" + tag)
			} else {
				window := asMap(observation["window"])
				derived := semanticWindow(stages, asList(oracle["runs"]), window["utc_offset"])
				if !(derived != nil && jsonEqual(window, derived)) {
					g.bad("semantic_window_forged:" + tag)
				}
				if !(asFloat(window["to"])-asFloat(window["from"]) <= maxWindowSeconds) {
					g.bad("semantic_window_length:" + tag)
				}
				if truthy(runWindow["from"]) && truthy(runWindow["to"]) {
					contained := asFloat(window["from"]) >= asFloat(runWindow["from"])-1 && asFloat(window["to"]) <= asFloat(runWindow["to"])+1
					if !contained {
						g.bad("semantic_window_outside_run:" + tag)
					}
				}
				// The oracle must be repeats of the very artifact the baseline built.
				var baselineBuild map[string]any
				for _, s := range asList(baselines[path]["stages"]) {
					if asMap(s)["stage"] == "build" {
						baselineBuild = asMap(s)
						break
					}
				}
				if baselineBuild != nil && truthy(dig(baselineBuild, "artifacts", "bin", "present")) {
					if !jsonEqual(dig(oracle, "binary", "sha256"), dig(baselineBuild, "artifacts", "bin", "sha256")) {
						g.bad("oracle_binary_mismatch:" + path)
					}
				}
				decodedOracle := decodeOracle(asList(oracle["runs"]))
				final := asMap(stages[authoritativeIndex(stages)])
				streams := candidateStreams(final)
				recomputed := compareSemantic(semanticRow, streams, decodedOracle, window, ledgerComparisonVersion)
				recorded := map[string]any{}
				for k, v := range asMap(observation["semantic"]) {
					if k != "stage" {
						recorded[k] = v
					}
				}
				if !jsonEqual(recorded, recomputed) {
					g.bad("semantic_forged:" + tag)
				}
				currentSemantic = compareSemantic(semanticRow, streams, decodedOracle, window, semanticsVersion)
			}
		}

		// -- the verdict, recomputed from this observation's own stages
		var baselineObs map[string]any
		if mode != "baseline" {
			baselineObs = baselines[path]
		}
		recomputed := observationStatus(observation, recipe, accepted[path], baselineObs, semanticRow, ledgerComparisonVersion)
		if status != recomputed {
			g.bad(fmt.Sprintf("status_forged:%s:recorded=%s recomputed=%s", tag, status, recomputed))
		}
		effectiveObservation := observation
		if currentSemantic != nil {
			effectiveObservation = map[string]any{}
			for k, v := range observation {
				effectiveObservation[k] = v
			}
			effectiveObservation["semantic"] = currentSemantic
		}
		effective := observationStatus(effectiveObservation, recipe, accepted[path], baselineObs, semanticRow, semanticsVersion)
		effectiveStatuses = append(effectiveStatuses, effective)
		if effective != "PASS" {
			g.bad(fmt.Sprintf("not_pass:%s:%s", tag, effective))
		}
	}

	// --- 8. summary, root and verdict recomputed
	if !jsonEqual(summary["outcomes"], countBy(observations, "status")) {
		g.bad("summary:outcomes")
	}
	if !jsonEqual(summary["observations"], int64(len(observations))) {
		g.bad("summary:observations")
	}
	if !jsonEqual(summary["semantic_rows"], int64(len(oracles))) {
		g.bad("summary:semantic_rows")
	}
	if rootRecord["sha256"] != ledgerRoot(records[:len(records)-2]) {
		g.bad("root:tampered")
	}
	if !jsonEqual(verdict["root_sha256"], rootRecord["sha256"]) {
		g.bad("verdict:root_binding")
	}
	recordedVerdict := "PASS"
	for _, o := range observations {
		if o["status"] != "PASS" {
			recordedVerdict = "FAIL"
			break
		}
	}
	if verdict["value"] != recordedVerdict {
		g.bad(fmt.Sprintf("verdict:forged (claims %s)", toS(verdict["value"])))
	}
	// A v1 FAIL remains an authenticated historical fact. It may validate now
	// only when every raw observation passes v2; current ledgers must still say PASS.
	if ledgerSemanticsVersion == semanticsVersion {
		if verdict["value"] != "PASS" {
			g.bad(fmt.Sprintf("verdict:not_pass (%s)", toS(verdict["value"])))
		}
	} else {
		allPass := true
		for _, s := range effectiveStatuses {
			if s != "PASS" {
				allPass = false
			}
		}
		if !allPass {
			g.bad("verdict:readjudication_not_pass")
		}
	}

	// --- report
	var oracleRunTotal int64
	for _, o := range oracles {
		oracleRunTotal += toI(o["repeats"])
	}
	if len(g.failures) == 0 {
		fmt.Printf("tour executor gate PASS: %d programs x %d modes = %d observations\n", denominator, len(modes), observationsFull)
		fmt.Printf("  semantic rows %d, oracle runs %d\n", len(oracles), oracleRunTotal)
		fmt.Printf("  root %s\n", toS(rootRecord["sha256"]))
		return 0
	}
	type kindCount struct {
		kind  string
		count int
	}
	grouped := map[string]int{}
	kindOrder := []string{}
	for _, f := range g.failures {
		kind, _, _ := strings.Cut(f, ":")
		if _, ok := grouped[kind]; !ok {
			kindOrder = append(kindOrder, kind)
		}
		grouped[kind]++
	}
	counts := []kindCount{}
	for _, kind := range kindOrder {
		counts = append(counts, kindCount{kind, grouped[kind]})
	}
	sort.SliceStable(counts, func(i, j int) bool { return counts[i].count > counts[j].count })
	fmt.Fprintf(os.Stderr, "tour executor gate FAIL: %d findings\n", len(g.failures))
	for _, kc := range counts {
		fmt.Fprintf(os.Stderr, "  %5d  %s\n", kc.count, kc.kind)
	}
	fmt.Fprintln(os.Stderr, "  --- first 25 ---")
	for i, f := range g.failures {
		if i >= 25 {
			break
		}
		fmt.Fprintf(os.Stderr, "  %s\n", f)
	}
	return 1
}

func indexOf(list []string, s string) int {
	for i, item := range list {
		if item == s {
			return i
		}
	}
	return -1
}

func mapKeysAny(m map[string]*SemanticRow) map[string]any {
	out := map[string]any{}
	for k := range m {
		out[k] = nil
	}
	return out
}
