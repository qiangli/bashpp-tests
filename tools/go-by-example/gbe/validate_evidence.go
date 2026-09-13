// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Independent verification of a Go by Example evidence chain, ported from
// tools/go-by-example/validate-evidence.rb.
//
// Nothing here trusts a field the producer wrote about itself. Normalized
// output, effect digests, per-attempt verdicts, the summary and the root digest
// are all re-derived from the raw bytes plus the repository's own reviewed
// tables, and the resulting root must additionally appear in
// docs/go-by-example/evidence-roots.tsv: SHA-256 links fields together but
// cannot say who produced them, so authentication comes from a separately
// committed anchor, never from a self-consistent document.
package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// Stage names each mode must record, in order, before its run. They are what
// stops a successful transpile from being read as an artifact that executed.
var requiredStages = map[string][][]string{
	"oracle":      {{"oracle-build", "oracle-test-build"}},
	"interpreted": {},
	"compiled":    {{"transpile"}},
}

var reGateAdapters = regexp.MustCompile(`(?m)^var ADAPTERS = \[\]string\{([^}]*)\}`)
var reQuoted = regexp.MustCompile(`"([^"]*)"`)

// gateAdapters reads the adapter registry out of the gate source, so a schema
// entry no production code implements is refused here as well as in the gate.
func gateAdapters(root string) []string {
	data, err := os.ReadFile(root + "/tools/go-by-example/gbe/gate.go")
	if err != nil {
		return nil
	}
	m := reGateAdapters.FindSubmatch(data)
	if m == nil {
		return nil
	}
	var out []string
	for _, q := range reQuoted.FindAllSubmatch(m[1], -1) {
		out = append(out, string(q[1]))
	}
	return out
}

func readEvidence(path string) ([]*Object, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rows []*Object
	for _, line := range rubyLinesChomp(string(data)) {
		v, err := Parse([]byte(line))
		if err != nil {
			return nil, err
		}
		o, ok := v.(*Object)
		if !ok {
			return nil, fmt.Errorf("record is not an object")
		}
		rows = append(rows, o)
	}
	return rows, nil
}

func b64decode(s string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(s)
}

func splitNames(value string) []string {
	if value == "none" {
		return []string{}
	}
	return strings.Split(value, ",")
}

func hex64(v any) bool {
	s, ok := v.(string)
	return ok && reHex64.MatchString(s)
}

func stageList(attempt *Object) []*Object {
	var out []*Object
	for _, s := range attempt.Arr("stages") {
		o, _ := s.(*Object)
		out = append(out, o)
	}
	return out
}

func validateEvidenceMain(args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: validate-evidence EVIDENCE")
		os.Exit(1)
	}
	root := ROOT
	die := func(message string) { fatal(message) }
	evidencePath := args[0]

	rows, err := readEvidence(evidencePath)
	if err != nil {
		die("invalid evidence JSON")
	}
	if len(rows) < 3 || rows[0].Str("type") != "manifest" || rows[len(rows)-1].Str("type") != "summary" {
		die("evidence must be manifest, attempts, summary")
	}
	manifest, attempts, summary := rows[0], rows[1:len(rows)-1], rows[len(rows)-1]
	if !deepEqual(manifest.Get("schema"), Int(evidenceSchema)) {
		die("unsupported evidence schema")
	}
	if manifest.Str("story") != story {
		die("wrong durable story binding")
	}

	inventoryPath := root + "/docs/go-by-example/inventory.tsv"
	schemaPath := root + "/docs/go-by-example/behavior-schema.tsv"
	toolchainPath := root + "/docs/go-by-example/toolchain.tsv"
	candidatesPath := root + "/docs/go-by-example/candidates.tsv"
	evidenceRootsPath := root + "/docs/go-by-example/evidence-roots.tsv"
	classificationPath := root + "/docs/go-by-example/classification.tsv"
	gbeDir := root + "/tools/go-by-example/gbe"
	normalizerPath := gbeDir + "/normalizer.go"

	allInventory, err := readTSV(inventoryPath)
	if err != nil {
		die("cannot read " + inventoryPath)
	}
	var inventory [][]string
	for _, r := range allInventory {
		if len(r) > 1 && (r[1] == "program" || r[1] == "test_program") {
			inventory = append(inventory, r)
		}
	}
	if len(inventory) != 85 {
		die("production inventory no longer has exactly 85 rows")
	}
	denominator := len(inventory) * len(MODES)
	if len(attempts) != denominator {
		die(fmt.Sprintf("evidence must contain %d attempts", denominator))
	}
	wantDenominator := Obj("rows", Int(int64(len(inventory))), "modes_per_row", Int(int64(len(MODES))), "attempts", Int(int64(denominator)))
	if !deepEqual(manifest.Get("denominator"), wantDenominator) || !deepEqual(manifest.Get("modes"), MODES) {
		die("invalid manifest denominator/modes")
	}

	schemaRows, err := readTSV(schemaPath)
	if err != nil {
		die("cannot read " + schemaPath)
	}
	var registeredNormalizations, registeredAdapters []string
	behaviors := map[string][2]string{}
	var behaviorOrder []string
	for _, row := range schemaRows {
		if len(row) < 2 {
			continue
		}
		switch row[0] {
		case "normalization":
			registeredNormalizations = append(registeredNormalizations, row[1])
		case "adapter":
			registeredAdapters = append(registeredAdapters, row[1])
		case "behavior":
			requires, allows := "", ""
			if len(row) > 2 {
				requires = row[2]
			}
			if len(row) > 3 {
				allows = row[3]
			}
			if _, seen := behaviors[row[1]]; !seen {
				behaviorOrder = append(behaviorOrder, row[1])
			}
			behaviors[row[1]] = [2]string{requires, allows}
		}
	}
	if len(behaviors) == 0 || len(registeredAdapters) == 0 || len(registeredNormalizations) == 0 {
		die("behavior schema declares no behaviors, adapters or normalizations")
	}
	if !uniqueStrings(registeredAdapters) || !uniqueStrings(registeredNormalizations) {
		die("schema vocabularies must be unique")
	}
	for _, name := range behaviorOrder {
		spec := behaviors[name]
		for _, adapter := range strings.Split(spec[0], ",") {
			if !contains(registeredAdapters, adapter) {
				die("behavior " + name + " requires undeclared adapter " + adapter)
			}
		}
		for _, norm := range strings.Split(spec[1], ",") {
			if !contains(registeredNormalizations, norm) {
				die("behavior " + name + " allows undeclared normalization " + norm)
			}
		}
	}
	if !sameSet(registeredNormalizations, NormalizerNames) {
		die("normalizer registry differs from production schema")
	}
	// An adapter names a control the gate performs. A registry entry no
	// production code implements is exactly the "adapter name as evidence of
	// determinism" failure Sprint 118 removed, so it is refused here as well as
	// in the gate.
	implemented := gateAdapters(root)
	if missing := sortedDifference(registeredAdapters, implemented); len(missing) > 0 {
		die("schema declares an adapter the gate does not implement: " + rubyStringArray(missing))
	}
	if extra := sortedDifference(implemented, registeredAdapters); len(extra) > 0 {
		die("gate implements an adapter the schema does not declare: " + rubyStringArray(extra))
	}

	for _, row := range inventory {
		path := root + "/" + row[0]
		if !isRegularFile(path) || fmt.Sprint(fileSize(path)) != row[6] || sha(path) != row[7] {
			die("anchored corpus source mismatch: " + row[0])
		}
		rowNormalizations := []string{"none"}
		if row[3] != "none" {
			rowNormalizations = strings.Split(row[3], ",")
		}
		if len(sortedDifference(rowNormalizations, registeredNormalizations)) > 0 {
			die("inventory uses an unregistered normalizer: " + row[0])
		}
	}

	classification, err := readTSV(classificationPath)
	if err != nil {
		die("cannot read " + classificationPath)
	}
	for _, row := range classification {
		if len(row) != 6 {
			die("classification table has malformed rows")
		}
	}
	var authored [][]string
	for _, row := range classification {
		if row[1] == "program" || row[1] == "test_program" {
			authored = append(authored, row)
		}
	}
	authoredText, inventoryText := "", ""
	for _, row := range authored {
		authoredText += strings.Join(row, "\t") + "\n"
	}
	for _, row := range inventory {
		inventoryText += strings.Join(row[:6], "\t") + "\n"
	}
	if authoredText != inventoryText {
		die("inventory classification columns do not match the authored classification table")
	}
	for _, row := range authored {
		path, kind, behavior, normalization, adapter := row[0], row[1], row[2], row[3], row[4]
		declared := strings.Split(behavior, ",")
		for _, name := range declared {
			if _, ok := behaviors[name]; !ok {
				die("row declares an unregistered behavior: " + path)
			}
		}
		if (kind == "test_program") != contains(declared, "test_harness") {
			die("test_harness behavior and test_program kind must agree: " + path)
		}
		if contains(declared, "deterministic") && (len(declared) != 1 || normalization != "none" || adapter != "none") {
			die("deterministic is exclusive and must compare raw bytes: " + path)
		}
		adapters := splitNames(adapter)
		normalizations := splitNames(normalization)
		if len(sortedDifference(adapters, registeredAdapters)) > 0 {
			die("row uses an unregistered adapter: " + path)
		}
		if len(sortedDifference(normalizations, registeredNormalizations)) > 0 {
			die("row uses an unregistered normalizer: " + path)
		}
		var required, licensedAdapters, licensedNormalizations []string
		for _, name := range declared {
			for _, a := range strings.Split(behaviors[name][0], ",") {
				licensedAdapters = append(licensedAdapters, a)
				if a != "none" {
					required = append(required, a)
				}
			}
			licensedNormalizations = append(licensedNormalizations, strings.Split(behaviors[name][1], ",")...)
		}
		if len(sortedDifference(required, adapters)) > 0 {
			die("declared behavior requires an adapter the row does not carry: " + path)
		}
		if len(sortedDifference(adapters, licensedAdapters)) > 0 {
			die("row carries an adapter no declared behavior requires: " + path)
		}
		if len(sortedDifference(normalizations, licensedNormalizations)) > 0 {
			die("row carries a normalization no declared behavior licenses: " + path)
		}
	}
	if validateMain(nil, io.Discard) != 0 {
		die("standalone corpus integrity revalidation failed")
	}
	var corpusRootText strings.Builder
	for _, r := range inventory {
		corpusRootText.WriteString(r[0] + "\x00" + r[7] + "\n")
	}
	corpusRoot := sha256Hex([]byte(corpusRootText.String()))

	goos, goarch := hostIdentity()
	toolRows, _ := readTSV(toolchainPath)
	var toolpin []string
	for _, r := range toolRows {
		if len(r) >= 5 && r[0] == goos && r[1] == goarch {
			toolpin = r
			break
		}
	}
	if toolpin == nil {
		die("no local production anchor row")
	}
	// The candidate anchor is re-derived from candidates.tsv here, independently
	// of whatever the evidence says about itself, and its declared SDK identity
	// must be the same reviewed release the oracle used: a pass may never be
	// assembled from a Go 1.27 oracle plus a candidate some other release built.
	recordedCandidate := manifest.Obj("candidate")
	recordedManifestSHA := ""
	if recordedCandidate != nil {
		recordedManifestSHA = recordedCandidate.Str("manifest_sha256")
	}
	reviewed, err := reviewedCandidate(candidatesPath, recordedManifestSHA)
	if err != nil {
		die(err.Error())
	}
	if reviewed.Fields["go_identity"] != toolpin[3] {
		die("candidate pin was not built by the pinned Go toolchain: " + rubyInspect(reviewed.Fields["go_identity"]) + " != " + rubyInspect(toolpin[3]))
	}

	anchors := Obj(
		"corpus_sha256", sha(inventoryPath), "corpus_root_sha256", corpusRoot,
		"behavior_schema_sha256", sha(schemaPath), "classification_sha256", sha(classificationPath),
		"normalizer_version", Int(NormalizerVersion),
		"normalizer_sha256", sha(normalizerPath), "toolchain_sha256", sha(toolchainPath),
		"go_sha256", toolpin[4],
	)
	for _, key := range anchors.Keys() {
		if !deepEqual(manifest.Get(key), anchors.Get(key)) {
			die("manifest " + key + " is not anchored to production")
		}
	}

	// --- candidate binding ---
	// The whole candidate is re-derived here from candidates.tsv: both digests,
	// the front-end version, the exact reviewed build recipe, the SDK identity,
	// and every runtime repository at its exact reviewed commit, the lowering
	// runtime and filebrowser included. Evidence produced against any other
	// candidate is refused.
	recorded := recordedCandidate
	if recorded == nil || recorded.Len() == 0 {
		die("evidence records no candidate binding")
	}
	if recorded.Str("candidates_sha256") != sha(candidatesPath) {
		die("candidates table is not anchored to production")
	}
	for _, key := range []string{"manifest_sha256", "launcher_sha256", "payload_sha256", "frontend_version", "build_recipe", "go_identity"} {
		if !deepEqual(recorded.Get(key), reviewed.Fields[key]) {
			die("candidate " + key + " is not the repository-reviewed value")
		}
	}
	if recorded.Str("launcher_sha256") == recorded.Str("payload_sha256") {
		die("candidate launcher and payload digests may not coincide")
	}
	if !deepEqual(recorded.Get("repositories"), reviewed.RepositoryRecords()) {
		die("candidate runtime dependencies differ from the reviewed set: " + Generate(recorded.Get("repositories")))
	}
	if !deepEqual(recorded.Get("sh_module_commit"), reviewed.Commits["sh"]) {
		die("candidate lowering runtime is not the reviewed mvdan.cc/sh/v3 commit")
	}
	// The recorded recipe is part of what is being reviewed: an evidence chain
	// that quietly reverts to `go run` or grants one mode extra environment is
	// not the reviewed contract, whatever its hashes say.
	recipe := manifest.Obj("recipe")
	if recipe == nil {
		recipe = NewObject()
	}
	for _, m := range MODES {
		if recipe.Str(m) == "" {
			die("evidence does not record the reviewed three-mode recipe")
		}
	}
	if !strings.Contains(recipe.Str("oracle"), "go build") || strings.Contains(recipe.Str("oracle"), "go run") {
		die("oracle recipe must build and run a native binary, never `go run`")
	}
	if !strings.Contains(recipe.Str("interpreted"), "--source=go") || !strings.Contains(recipe.Str("compiled"), "--source=go") {
		die("product recipes must use the unchanged-Go-source selector")
	}
	// Explicit multi-file input must use the product's own repeated --go-file.
	// The alternative -- appending the second file as an operand -- makes the
	// CLI hand it to the program as argv, so a one-file build would be compared
	// against the oracle's two-file one and the divergence would be invisible.
	if !deepEqual(recipe.Get("multi_file_input"), "--go-file") {
		die("evidence does not record the --go-file multi-file input contract")
	}
	if !deepEqual(recipe.Get("declared_env_divergence"), []any{}) {
		die("evidence declares an environment divergence between modes: " + Generate(recipe.Get("declared_env_divergence")))
	}
	// GOROOT/GOMODCACHE are the product runtime's import-resolution inputs. They
	// are admissible only as part of the block EVERY mode receives; a chain that
	// granted them to the interpreter alone would be a tooling exemption, and is
	// refused.
	if !deepEqual(recipe.Get("common_runtime_go_env"), []string{"GOROOT", "GOMODCACHE", "GOCACHE"}) {
		die("evidence does not record the common runtime Go environment")
	}
	if !deepEqual(recipe.Get("effect_normalizations"), effectNormalizations) {
		die("evidence licenses an unreviewed effect normalization: " + Generate(recipe.Get("effect_normalizations")))
	}
	// The process, deadline and descendant primitives are the shared corpus
	// ones, and the evidence has to name the exact reviewed bytes it used for
	// them.
	if !strings.Contains(recipe.Str("process_primitives"), "Corpus.capture") {
		die("evidence does not record the shared corpus process primitives")
	}
	if !deepEqual(recipe.Get("corpus_executor_sha256"), sha(gbeDir+"/corpus.go")) {
		die("corpus executor is not anchored to production")
	}
	if recipe.Has("runtime_config_sha256") {
		if !deepEqual(recipe.Get("runtime_config_sha256"), sha(gbeDir+"/runtimeconfig.go")) {
			die("runtime configuration helper is not anchored")
		}
		if !deepEqual(recipe.Get("runtime_telemetry"), Obj("OTEL_TRACES_EXPORTER", "none", "Go", "pinned go telemetry off in each isolated HOME before effect baseline")) {
			die("unreviewed telemetry configuration")
		}
	}
	if !deepEqual(recipe.Get("input_binding_sha256"), sha(gbeDir+"/inputs.go")) {
		die("input binding helper is not anchored to production")
	}
	if !deepEqual(recipe.Get("launcher_source_sha256"), sha(root+"/tools/go-by-example/launch.go")) {
		die("run launcher is not anchored to production")
	}
	// The isolation claim is bounded on purpose: no OS-level sandbox is built,
	// so the evidence may not be worded as if the SDK or the source tree were
	// denied.
	if !strings.Contains(recipe.Str("source_absence"), "NOT an OS-level denial") {
		die("evidence overstates isolation")
	}

	binding := sha256Hex([]byte(Generate(manifest)))
	var expectedPairs, actualPairs []string
	for _, r := range inventory {
		for _, mode := range MODES {
			expectedPairs = append(expectedPairs, r[0]+"\x00"+mode)
		}
	}
	for _, r := range attempts {
		actualPairs = append(actualPairs, r.Str("path")+"\x00"+r.Str("mode"))
	}
	if strings.Join(actualPairs, "\n") != strings.Join(expectedPairs, "\n") {
		die("missing, duplicate, reordered, or foreign row/mode evidence")
	}

	seenStreamPaths := map[string]bool{}
	type normalizedPair struct {
		ok     bool
		stdout string
		stderr string
	}
	recomputedAll := make([]normalizedPair, len(attempts))
	for index, attempt := range attempts {
		body := attempt.Without("evidence_sha256")
		if attempt.Str("binding_sha256") != binding || attempt.Str("evidence_sha256") != sha256Hex([]byte(Generate(body))) {
			die("result tampering detected")
		}
		var inventoryRow []string
		for _, row := range inventory {
			if row[0] == attempt.Str("path") {
				inventoryRow = row
				break
			}
		}
		if attempt.Str("kind") != inventoryRow[1] {
			die("attempt kind differs from the inventory: " + attempt.Str("path"))
		}
		normalizations := splitNames(inventoryRow[3])
		label := attempt.Str("path") + ":" + attempt.Str("mode")

		if recipe.Has("runtime_config_sha256") && attempt.Str("state") == "complete" {
			config := attempt.Obj("configuration")
			if config == nil {
				config = NewObject()
			}
			if config.Str("state") != "complete" || config.Str("go_mode") != "off" || !deepEqual(config.Get("environment"), Obj("OTEL_TRACES_EXPORTER", "none")) {
				die("completed attempt lacks verified telemetry setup")
			}
			setup := config.Arr("stages")
			setupOK := len(setup) == 2
			for _, s := range setup {
				stage, _ := s.(*Object)
				if stage == nil || stage.Str("state") != "exited" || !deepEqual(stage.Get("exit"), Int(0)) || stage.Obj("environment") == nil || stage.Obj("environment").Str("OTEL_TRACES_EXPORTER") != "none" {
					setupOK = false
				}
			}
			if !setupOK {
				die("invalid telemetry setup stages")
			}
			argv0 := strSlice(setup[0].(*Object).Get("argv"))
			argv1 := strSlice(setup[1].(*Object).Get("argv"))
			if len(argv0) < 1 || len(argv1) < 1 || strings.Join(argv0[1:], " ") != "telemetry off" || strings.Join(argv1[1:], " ") != "env -json GOTELEMETRY GOTELEMETRYDIR" {
				die("invalid telemetry setup commands")
			}
			if err := checkTelemetry(config, setup, manifest); err != nil {
				die(err.Error())
			}
		}

		// --- stage separation ---
		stages := stageList(attempt)
		if len(stages) == 0 {
			die("attempt records no stages: " + label)
		}
		if stages[len(stages)-1] == nil || stages[len(stages)-1].Str("stage") != "run" {
			die("last recorded stage must be the run: " + label)
		}
		for i, allowed := range requiredStages[attempt.Str("mode")] {
			name := ""
			if i < len(stages) && stages[i] != nil {
				name = stages[i].Str("stage")
			}
			if !contains(allowed, name) {
				die("missing " + strings.Join(allowed, "/") + " stage: " + label)
			}
		}
		if attempt.Str("mode") == "interpreted" && len(stages) != 1 {
			die("interpreted mode may only record a run stage: " + attempt.Str("path"))
		}
		for _, stage := range stages {
			capture := stage.Obj("capture")
			if capture == nil {
				continue
			}
			for _, stream := range []string{"stdout", "stderr"} {
				artifact := capture.Obj(stream)
				if artifact == nil {
					die("key not found: \"" + stream + "\"")
				}
				path, err := realPath(artifact.Str("path"))
				if err != nil {
					die("Errno::ENOENT: No such file or directory @ rb_check_realpath_internal - " + artifact.Str("path"))
				}
				if seenStreamPaths[path] {
					die("duplicate retained stage stream path")
				}
				seenStreamPaths[path] = true
				actual, err := fileRecord(path)
				if err != nil {
					die(err.Error())
				}
				if !deepEqual(actual.Get("sha256"), artifact.Get("sha256")) || !deepEqual(actual.Get("bytes"), artifact.Get("bytes")) || stage.Str(stream+"_sha256") != actual.Str("sha256") {
					die("retained stage stream changed")
				}
				if stage.Str("stage") == "run" {
					raw, err := b64decode(attempt.Str("raw_" + stream + "_b64"))
					data, _ := os.ReadFile(path)
					if err != nil || string(raw) != string(data) {
						die("run raw bytes differ from retained capture")
					}
				}
			}
			for _, key := range []string{"native_file", "generated_file", "source_map_file"} {
				artifact := stage.Obj(key)
				if artifact == nil {
					continue
				}
				actual, err := fileRecord(artifact.Str("path"))
				if err != nil {
					die(err.Error())
				}
				if !deepEqual(actual.Get("sha256"), artifact.Get("sha256")) || !deepEqual(actual.Get("bytes"), artifact.Get("bytes")) {
					die("retained " + key + " changed")
				}
				if key == "native_file" && !nativeBinary(artifact.Str("path")) {
					die("retained native artifact is not a binary")
				}
			}
			if stage.Obj("source_map_file") != nil {
				data, err := os.ReadFile(stage.Obj("source_map_file").Str("path"))
				if err != nil {
					die(err.Error())
				}
				mapping, err := ParseObject(data)
				if err != nil {
					die("invalid retained source map JSON")
				}
				if !validSourceMap(mapping, stage.Obj("generated_file"), stage.Obj("source_inputs")) {
					die("retained source map does not bind original inputs")
				}
			}
		}
		runStage := stages[len(stages)-1]
		if !deepEqual(runStage.Get("spawned"), attempt.Get("spawned")) || runStage.Str("state") != attempt.Str("state") || !deepEqual(runStage.Get("exit"), attempt.Get("exit")) {
			die("run stage disagrees with the attempt: " + label)
		}

		// --- the recorded input spelling, not just the recipe prose ---
		// A product stage that names more than one .go input must have named
		// each of them with --go-file. Appending the extra file as an operand
		// would make the CLI hand it to the program as argv, so a one-file build
		// would have been compared against the oracle's whole package with
		// nothing in the streams to show for it.
		if attempt.Str("mode") == "interpreted" || attempt.Str("mode") == "compiled" {
			for _, stage := range stages {
				argv := strSlice(stage.Get("argv"))
				if len(argv) == 0 {
					continue
				}
				goInputs := 0
				for i, token := range argv {
					prev := ""
					if i > 0 {
						prev = argv[i-1]
					} else if len(argv) > 0 {
						prev = argv[len(argv)-1] // argv[-1] in Ruby
					}
					if strings.HasSuffix(token, ".go") && prev != "-o" && prev != "--map" {
						goInputs++
					}
				}
				if goInputs <= 1 {
					continue
				}
				if attempt.Str("mode") == "interpreted" && stage.Str("stage") == "run" && recipe.Has("multi_file_program_arguments") {
					if !deepEqual(recipe.Get("multi_file_program_arguments"), "-- separator before program argv") {
						die("unreviewed multi-file argv contract")
					}
					if attempt.Str("kind") == "test_program" {
						separator := -1
						for i, token := range argv {
							if token == "--" {
								separator = i
								break
							}
						}
						if separator < 0 || strings.Join(argv[separator+1:], "\x00") != "-test.v" {
							die("test driver arguments lack an explicit separator")
						}
					}
				}
				flagged := 0
				for i := 0; i+1 < len(argv); i++ {
					if argv[i] == "--go-file" && strings.HasSuffix(argv[i+1], ".go") {
						flagged++
					}
				}
				if flagged != goInputs {
					die("a multi-file product stage did not use the --go-file contract: " + label + ":" + stage.Str("stage"))
				}
			}
		}
		if attempt.Str("mode") == "compiled" && attempt.Bool("spawned") {
			var build, transpile *Object
			for _, s := range stages {
				if s.Str("stage") == "build" && build == nil {
					build = s
				}
				if s.Str("stage") == "transpile" && transpile == nil {
					transpile = s
				}
			}
			if build == nil || !deepEqual(build.Get("exit"), Int(0)) || build.Str("state") != "complete" || !hex64(build.Get("artifact_sha256")) {
				die("a compiled run was recorded without a successful build stage: " + attempt.Str("path"))
			}
			// A validated source map is part of the transpile artifact: an
			// unparseable, mis-positioned or mis-digested map means the stage did
			// not produce what the contract describes, and its build must not be
			// read as if it had.
			if transpile == nil || !deepEqual(transpile.Get("exit"), Int(0)) || !hex64(transpile.Get("generated_go_sha256")) || !hex64(transpile.Get("source_map_sha256")) {
				die("a compiled run was recorded without a successful transpile stage: " + attempt.Str("path"))
			}
		}

		// --- independently recomputed comparator inputs ---
		rawStdoutText, okOut := attempt.Get("raw_stdout_b64").(string)
		rawStderrText, okErr := attempt.Get("raw_stderr_b64").(string)
		rawStdout, err1 := b64decode(rawStdoutText)
		rawStderr, err2 := b64decode(rawStderrText)
		if !okOut || !okErr || err1 != nil || err2 != nil {
			die("invalid raw output encoding: " + label)
		}
		stdoutN, errOut := Normalize(rawStdout, normalizations, "stdout")
		stderrN, errErr := Normalize(rawStderr, normalizations, "stderr")
		if errOut == nil && errErr == nil {
			recomputedAll[index] = normalizedPair{true, b64([]byte(stdoutN)), b64([]byte(stderrN))}
		}
		if attempt.Has("effects_delta") {
			var licensed []string
			for _, n := range normalizations {
				if contains(effectNormalizations, n) {
					licensed = append(licensed, n)
				}
			}
			delta, _ := attempt.Get("effects_delta").(string)
			if attempt.Str("effects_sha256") != sha256Hex([]byte(delta)) {
				die("stored effect digest differs from the recorded delta: " + label)
			}
			recomputed, ok := delta, true
			if len(licensed) > 0 {
				recomputed, err = Normalize([]byte(delta), licensed, "stdout")
				ok = err == nil
			}
			if !ok || recomputed != delta {
				die("effect listing was rewritten by an unlicensed normalization: " + label)
			}
		} else if attempt.Get("effects_sha256") != nil {
			die("effect digest recorded without its delta: " + label)
		}
	}

	for start := 0; start+len(MODES) <= len(attempts); start += len(MODES) {
		oracle := attempts[start]
		for offset := 0; offset < len(MODES); offset++ {
			attempt := attempts[start+offset]
			recomputed := recomputedAll[start+offset]
			label := attempt.Str("path") + ":" + attempt.Str("mode")
			storedOut, storedErr := attempt.Get("normalized_stdout_b64"), attempt.Get("normalized_stderr_b64")
			if recomputed.ok {
				if !deepEqual(storedOut, recomputed.stdout) || !deepEqual(storedErr, recomputed.stderr) {
					die("stored normalized output differs from independently recomputed bytes: " + label)
				}
			} else if storedOut != nil || storedErr != nil {
				die("stored normalized output differs from independently recomputed bytes: " + label)
			}
			var expected string
			switch {
			case !attempt.Bool("spawned") || attempt.Str("state") != "complete":
				expected = "fail_incomplete"
			case !recomputed.ok || oracle.Get("normalized_stdout_b64") == nil || attempt.Get("effects_sha256") == nil:
				expected = "fail_normalization"
			case attempt.Str("mode") == "oracle":
				expected = "pass"
			case !deepEqual(attempt.Get("exit"), oracle.Get("exit")) || !deepEqual(recomputed.stdout, oracle.Get("normalized_stdout_b64")) || !deepEqual(recomputed.stderr, oracle.Get("normalized_stderr_b64")):
				expected = "fail_mismatch"
			case oracle.Get("effects_sha256") != nil && !deepEqual(attempt.Get("effects_sha256"), oracle.Get("effects_sha256")):
				expected = "fail_effects"
			default:
				expected = "pass"
			}
			if attempt.Str("verdict") != expected {
				die("per-attempt verdict is not derived from production evidence: " + label)
			}
		}
	}

	executed := 0
	failures := []any{}
	completePass := true
	for _, r := range attempts {
		if r.Bool("spawned") {
			executed++
		}
		if r.Str("verdict") != "pass" {
			failures = append(failures, r.Str("path")+":"+r.Str("mode")+":"+r.Str("verdict"))
		}
		if !(r.Bool("spawned") && r.Str("state") == "complete" && r.Str("verdict") == "pass") {
			completePass = false
		}
	}
	verdict := "fail"
	if completePass && executed == denominator && len(failures) == 0 {
		verdict = "pass"
	}
	expectedSummary := Obj("type", "summary", "verdict", verdict,
		"denominator", Int(int64(denominator)), "attempt_records", Int(int64(denominator)), "executed", Int(int64(executed)),
		"missing_or_unspawned", Int(int64(denominator-executed)), "failures", failures)
	expectedSummary.Merge(anchors)
	expectedSummary.Merge(Obj("candidates_sha256", sha(candidatesPath),
		"candidate_manifest_sha256", reviewed.Fields["manifest_sha256"],
		"launcher_sha256", reviewed.Fields["launcher_sha256"],
		"payload_sha256", reviewed.Fields["payload_sha256"]))
	summaryWithoutRoot := summary.Without("root_digest")
	if !deepEqual(summaryWithoutRoot, expectedSummary) {
		die("summary is not independently derived from anchored evidence")
	}
	summaryHash := sha256Hex([]byte(Generate(summaryWithoutRoot)))
	chain := []string{binding}
	for _, r := range attempts {
		chain = append(chain, r.Str("evidence_sha256"))
	}
	chain = append(chain, summaryHash)
	evidenceRoot := sha256Hex([]byte(strings.Join(chain, "\n")))
	if summary.Str("root_digest") != evidenceRoot {
		die("summary-bound root digest mismatch")
	}
	if !strings.HasSuffix(evidencePath, "."+summary.Str("verdict")) {
		die("verdict/path mismatch")
	}

	// Authentication: a separately reviewed, committed root. Kept after the
	// independent derivations above so mutations get the most precise
	// diagnosis. realpath, not expand_path: `root` is already resolved, so an
	// unresolved /tmp -> /private/tmp would never match.
	evidenceAbs, err := realPath(evidencePath)
	if err != nil {
		evidenceAbs = expandPath(evidencePath)
	}
	evidenceID := evidenceAbs
	if strings.HasPrefix(evidenceAbs, root+"/") {
		evidenceID = evidenceAbs[len(root)+1:]
	}
	rootAnchors, _ := readTSV(evidenceRootsPath)
	anchored := false
	for _, row := range rootAnchors {
		if len(row) >= 4 && row[0] == manifest.Str("story") && row[1] == evidenceID && row[2] == summary.Str("verdict") && row[3] == evidenceRoot {
			anchored = true
		}
	}
	if !anchored {
		die("evidence root is not anchored to reviewed production evidence")
	}
	if summary.Str("verdict") == "pass" {
		if !deepEqual(summary.Get("denominator"), Int(int64(denominator))) || !deepEqual(summary.Get("executed"), Int(int64(denominator))) || !deepEqual(summary.Get("missing_or_unspawned"), Int(0)) || len(failures) != 0 || !completePass {
			die(fmt.Sprintf("PASS requires denominator=executed=%d, missing=0, every attempt complete/pass, and no failures", denominator))
		}
	}
	fmt.Printf("PASS: authenticated %s evidence, denominator=%d executed=%d missing=%d root_digest=%s\n", summary.Str("verdict"), denominator, executed, denominator-executed, evidenceRoot)
}

// checkTelemetry re-derives the retained telemetry configuration of a
// completed attempt from the files it names.
func checkTelemetry(config *Object, setup []any, manifest *Object) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("invalid retained telemetry configuration: %v", r)
		}
	}()
	wrap := func(message string) error { return fmt.Errorf("invalid retained telemetry configuration: %s", message) }
	mode := config.Obj("mode_file")
	if mode == nil {
		return wrap("key not found: \"mode_file\"")
	}
	actualMode, ferr := fileRecord(mode.Str("path"))
	if ferr != nil {
		return wrap(ferr.Error())
	}
	modeBytes, _ := os.ReadFile(mode.Str("path"))
	if !deepEqual(actualMode.Get("sha256"), mode.Get("sha256")) || !deepEqual(actualMode.Get("bytes"), mode.Get("bytes")) || !reTelemetryMode.MatchString(string(modeBytes)) {
		return fmt.Errorf("telemetry mode file changed")
	}
	for _, s := range setup {
		stage := s.(*Object)
		argv := strSlice(stage.Get("argv"))
		sum, derr := digest(argv[0])
		if derr != nil {
			return wrap(derr.Error())
		}
		if sum != manifest.Str("go_sha256") {
			return fmt.Errorf("telemetry setup SDK digest mismatch")
		}
		for _, stream := range []string{"stdout", "stderr"} {
			artifact := stage.Obj(stream)
			if artifact == nil {
				return wrap("key not found: \"" + stream + "\"")
			}
			actual, ferr := fileRecord(artifact.Str("path"))
			if ferr != nil {
				return wrap(ferr.Error())
			}
			if !deepEqual(actual.Get("sha256"), artifact.Get("sha256")) || !deepEqual(actual.Get("bytes"), artifact.Get("bytes")) {
				return fmt.Errorf("telemetry setup raw log changed")
			}
		}
	}
	lastStage := setup[len(setup)-1].(*Object)
	data, rerr := os.ReadFile(lastStage.Obj("stdout").Str("path"))
	if rerr != nil {
		return wrap(rerr.Error())
	}
	observed, perr := ParseObject(data)
	if perr != nil {
		return wrap(perr.Error())
	}
	dir, ok := observed.Get("GOTELEMETRYDIR").(string)
	if !ok {
		return wrap("key not found: \"GOTELEMETRYDIR\"")
	}
	if observed.Str("GOTELEMETRY") != "off" || expandPath(dir+"/mode") != expandPath(mode.Str("path")) {
		return fmt.Errorf("telemetry query does not match configuration")
	}
	return nil
}

func uniqueStrings(values []string) bool {
	seen := map[string]bool{}
	for _, v := range values {
		if seen[v] {
			return false
		}
		seen[v] = true
	}
	return true
}
