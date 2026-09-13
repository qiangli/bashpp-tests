// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Deterministic three-mode executor library for the pinned go.dev/tour
// denominator — the Go port of tools/tour/executor.rb (Sprint 118 / Story #4 /
// Story-ID 759341a95870). It is shared by four consumers so none of them can
// drift:
//
//	tour executor               produces tests/tour/executor-results.jsonl
//	tour validate-executor      re-derives and audits that ledger offline
//	tour executor-selftests     drives the pure functions and the real gate
//	tour executor-tamper-tests  mutates the REAL ledger and requires the real
//	                            gate to reject each mutation
//
// PROCESS MACHINERY: every subprocess goes through Capture (capture.go), the
// port of the shared corpus primitive. This file converts that primitive's
// FILE-BACKED stream records into the normalized, digest-bound data the tour
// ledger needs; it does not reimplement spawning, deadlines or sweeping.
//
// WHAT THIS CORPUS OWNS ON TOP OF THAT: the command table
// (docs/tour/executor-contract.tsv), the tour inventory join, the pinned
// normalizer audit, the phase-migration contract, the semantic comparators for
// the declared-volatile rows (semantics.go) and the scoring rules below.
package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	executorSchema   = "tour-executor/v2"
	denominator      = 97
	applicableRows   = 93
	buildOnlyRows    = 4
	observationsFull = denominator * 3 // 291
)

var (
	modes                     = []string{"baseline", "interpreted", "compiled"}
	executableApplicabilities = []string{"applicable_go_program", "build_only_go_program"}
	// A ledger may only ever carry these statuses. Placeholder vocabulary that
	// a partially-written or forged ledger might use is listed so the gate can
	// reject it by name instead of silently treating it as "not a failure".
	forbiddenStatuses = []string{"PLANNED", "TODO", "SKIP", "SKIPPED", "N/A", "NA", "NOT_APPLICABLE", "NOTAPPLICABLE", "PENDING", "UNKNOWN"}
	// The ONLY approved not-applicable reason in the tour inventory
	// (docs/tour/standing-exceptions.tsv). It applies exclusively to
	// excluded_fragment rows, outside the executable denominator.
	approvedExceptions = []string{"none", "fragment"}
)

// The honest scope of the input-absence control, recorded on every stage that
// executes a tested body. It is a cwd and command-lookup restriction, not an
// OS-level denial. Claiming more than this would be the gaming vector the
// story warns about.
const inputAbsenceScope = "compilation cwd emptied before native execution; body PATH empty; " +
	"interpreted mode necessarily retains its own source/module context; no OS sandbox"

// Digests of the retired Ruby implementations this corpus was ported from.
// A ledger sealed by the Ruby harness binds these files by digest; the gates
// accept exactly these digests for exactly those paths, and nothing else, so
// Ruby-era evidence stays authenticable without any Ruby being executed.
const (
	retiredRubyCaptureImplementation  = "tools/corpus/executor.rb:Corpus.capture"
	retiredRubyCaptureLibrarySHA256   = "04916fdfc740d4733df6b67d5076623067dc997660d6aed7e8fc2bf14d90a078"
	retiredRubySemanticsLibrarySHA256 = "ac6ffe652d220174a7479220f854e80d79f35dad43150b784ad8fca95975c661"
	retiredRubyNormalizerPath         = "tools/tour/normalize.rb"
	normalizerPath                    = "tools/tour/normalize.go"
	semanticsLibraryPath              = "tools/tour/semantics.go"
	captureLibraryPath                = "tools/tour/capture.go"
)

// ---------------------------------------------------------------- utilities

func readFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(fmt.Sprintf("cannot read %s: %v", path, err))
	}
	return data
}

func shaFile(path string) string {
	return sha256hex(readFile(path))
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

func dirExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

// tsvRows mirrors `File.readlines(...).reject(comment/empty).map(split("\t", -1))`.
func tsvRows(path string) [][]string {
	rows := [][]string{}
	for _, line := range strings.Split(strings.TrimSuffix(string(readFile(path)), "\n"), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		rows = append(rows, strings.Split(line, "\t"))
	}
	return rows
}

// tsvRowsLoose mirrors `line.split("\t")` (trailing empty fields dropped).
func tsvRowsLoose(path string) [][]string {
	rows := tsvRows(path)
	for i, row := range rows {
		for len(row) > 0 && row[len(row)-1] == "" {
			row = row[:len(row)-1]
		}
		rows[i] = row
	}
	return rows
}

func field(row []string, i int) string {
	if i < len(row) {
		return row[i]
	}
	return ""
}

var slugRE = regexp.MustCompile(`[^\w.-]`)

func slug(path string) string {
	return slugRE.ReplaceAllString(path, "_")
}

func mustInt(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		panic(fmt.Sprintf("invalid integer %q", s))
	}
	return n
}

func nowFloat() float64 {
	return float64(time.Now().UnixNano()) / 1e9
}

func utcOffsetNow() int64 {
	_, off := time.Now().Zone()
	return int64(off)
}

func b64(data []byte) string {
	return base64.StdEncoding.EncodeToString(data)
}

// b64decode mirrors Ruby's lenient Base64.decode64.
func b64decode(s string) []byte {
	clean := strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '+' || r == '/' {
			return r
		}
		return -1
	}, s)
	for len(clean)%4 != 0 {
		clean += "="
	}
	out, err := base64.StdEncoding.DecodeString(clean)
	if err != nil {
		// Decode as much as parses, the way decode64 does.
		out, _ = base64.StdEncoding.DecodeString(clean[:len(clean)-len(clean)%4])
	}
	return out
}

type modeKey struct{ applicability, mode string }

// ---------------------------------------------------------------- contract

// Stage is one row of the contract: an ordered stage spec of a recipe.
type Stage struct {
	Index        int64
	Stage        string
	ArgvTemplate []string
	Produces     []string
	ExecuteBody  bool
}

// Recipe is the contract for one (applicability, mode) pair.
type Recipe struct {
	Phase  string
	Stages []Stage
}

type Contract map[modeKey]*Recipe

// loadContract: docs/tour/executor-contract.tsv -> { [applicability, mode] => recipe }.
func loadContract(path string) (Contract, error) {
	recipes := Contract{}
	for _, row := range tsvRows(path) {
		applicability, mode, phase, stageIndex, stage, argv, produces, executeBody :=
			field(row, 0), field(row, 1), field(row, 2), field(row, 3), field(row, 4), field(row, 5), field(row, 6), field(row, 7)
		if !containsString(executableApplicabilities, applicability) {
			return nil, fmt.Errorf("contract: unknown applicability %s", applicability)
		}
		if !containsString(modes, mode) {
			return nil, fmt.Errorf("contract: unknown mode %s", mode)
		}
		if executeBody != "yes" && executeBody != "no" {
			return nil, fmt.Errorf("contract: execute_body must be yes/no, got %s", executeBody)
		}
		key := modeKey{applicability, mode}
		recipe, ok := recipes[key]
		if !ok {
			recipe = &Recipe{Phase: phase}
			recipes[key] = recipe
		}
		if recipe.Phase != phase {
			return nil, fmt.Errorf("contract: phase disagrees within %s/%s", applicability, mode)
		}
		if mustInt(stageIndex) != int64(len(recipe.Stages)) {
			return nil, fmt.Errorf("contract: stage_index out of order in %s/%s", applicability, mode)
		}
		var produced []string
		if produces == "-" {
			produced = []string{}
		} else {
			produced = strings.Split(produces, ",")
		}
		recipe.Stages = append(recipe.Stages, Stage{
			Index: mustInt(stageIndex), Stage: stage, ArgvTemplate: strings.Split(argv, "|"),
			Produces: produced, ExecuteBody: executeBody == "yes",
		})
	}
	missing := []string{}
	for _, a := range executableApplicabilities {
		for _, m := range modes {
			if _, ok := recipes[modeKey{a, m}]; !ok {
				missing = append(missing, fmt.Sprintf("[%q, %q]", a, m))
			}
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("contract: missing recipes for [%s]", strings.Join(missing, ", "))
	}
	return recipes, nil
}

// MigrationRow is one row of docs/tour/phase-migration.tsv.
type MigrationRow struct {
	Applicability, Mode, SchemaField, HistoricalToken, CurrentPhase, Rationale string
	ExecutesBody                                                               bool
}

type Migration map[modeKey]MigrationRow

func loadPhaseMigration(path string) (Migration, error) {
	rows := Migration{}
	for _, row := range tsvRows(path) {
		applicability, mode, f, historical, current, executes, rationale :=
			field(row, 0), field(row, 1), field(row, 2), field(row, 3), field(row, 4), field(row, 5), field(row, 6)
		if !containsString(executableApplicabilities, applicability) {
			return nil, fmt.Errorf("phase-migration: unknown applicability %s", applicability)
		}
		if !containsString(modes, mode) {
			return nil, fmt.Errorf("phase-migration: unknown mode %s", mode)
		}
		if executes != "yes" && executes != "no" {
			return nil, fmt.Errorf("phase-migration: executes_body must be yes/no")
		}
		rows[modeKey{applicability, mode}] = MigrationRow{Applicability: applicability, Mode: mode, SchemaField: f,
			HistoricalToken: historical, CurrentPhase: current, ExecutesBody: executes == "yes", Rationale: rationale}
	}
	for _, a := range executableApplicabilities {
		for _, m := range modes {
			if _, ok := rows[modeKey{a, m}]; !ok {
				return nil, fmt.Errorf("phase-migration: missing rows for %s/%s", a, m)
			}
		}
	}
	return rows, nil
}

// migrationKeys returns the migration keys in a stable order (applicability
// then mode as declared), matching the Ruby hash's insertion order.
func migrationKeys(migration Migration) []modeKey {
	keys := []modeKey{}
	for _, a := range executableApplicabilities {
		for _, m := range modes {
			if _, ok := migration[modeKey{a, m}]; ok {
				keys = append(keys, modeKey{a, m})
			}
		}
	}
	return keys
}

// Item is one executable inventory row.
type Item struct {
	Path, Kind, Applicability, Exception, DifferentialSchema, SHA256 string
	Bytes                                                            int64
}

func itemMap(item Item) map[string]any {
	return map[string]any{"path": item.Path, "applicability": item.Applicability,
		"differential_schema": item.DifferentialSchema, "sha256": item.SHA256, "bytes": item.Bytes}
}

// phaseMigrationFailures checks the migration table against BOTH ends it
// bridges: the pinned historical schema string on each inventory row, and the
// current contract.
func phaseMigrationFailures(migration Migration, contract Contract, items []Item) []string {
	findings := []string{}
	for _, key := range migrationKeys(migration) {
		row := migration[key]
		recipe, ok := contract[key]
		if !ok {
			findings = append(findings, fmt.Sprintf("phase_migration:no_contract:%s/%s", key.applicability, key.mode))
			continue
		}
		if recipe.Phase != row.CurrentPhase {
			findings = append(findings, fmt.Sprintf("phase_migration:current_phase:%s/%s", key.applicability, key.mode))
		}
		executes := false
		for _, stage := range recipe.Stages {
			if stage.ExecuteBody {
				executes = true
			}
		}
		if executes != row.ExecutesBody {
			findings = append(findings, fmt.Sprintf("phase_migration:body_policy:%s/%s", key.applicability, key.mode))
		}
	}
	for _, item := range items {
		declared := map[string]string{}
		for _, pair := range strings.Split(item.DifferentialSchema, ";") {
			k, v, _ := strings.Cut(pair, ":")
			declared[k] = v
		}
		for _, mode := range modes {
			row, ok := migration[modeKey{item.Applicability, mode}]
			if !ok {
				continue
			}
			if declared[row.SchemaField] != row.HistoricalToken {
				findings = append(findings, fmt.Sprintf("phase_migration:historical_drift:%s/%s", item.Path, mode))
			}
		}
	}
	return uniqStrings(findings)
}

var placeholderRE = regexp.MustCompile(`\{(\w+)\}`)

// renderArgv substitutes the contract placeholders. Unknown placeholders are
// a hard error: a silently unsubstituted `{BIN}` would otherwise become a
// literal argument and quietly change what ran.
func renderArgv(template []string, subs map[string]string) ([]string, error) {
	out := make([]string, 0, len(template))
	for _, token := range template {
		var err error
		rendered := placeholderRE.ReplaceAllStringFunc(token, func(match string) string {
			key := match[1 : len(match)-1]
			value, ok := subs[key]
			if !ok {
				err = fmt.Errorf("contract: no substitution for {%s}", key)
				return match
			}
			return value
		})
		if err != nil {
			return nil, err
		}
		out = append(out, rendered)
	}
	return out, nil
}

func mustRenderArgv(template []string, subs map[string]string) []string {
	argv, err := renderArgv(template, subs)
	if err != nil {
		panic(err)
	}
	return argv
}

// substitutions is the concrete substitution map for one (row, mode).
func substitutions(path string, bashy, goBin, artifactDir string) map[string]string {
	base := strings.TrimSuffix(filepath.Base(path), ".go")
	return map[string]string{
		"GO": goBin, "BASHY": bashy, "SRC": path,
		"OUT_GO":  filepath.Join(artifactDir, base+".transpiled.go"),
		"OUT_MAP": filepath.Join(artifactDir, base+".transpiled.go.map"),
		"BIN":     filepath.Join(artifactDir, base+".bin"),
	}
}

var artifactKey = map[string]string{"go": "OUT_GO", "map": "OUT_MAP", "bin": "BIN"}

// ---------------------------------------------------------------- inventory

// Inventory is the executable slice of tests/tour/inventory.tsv plus the
// digest over all data rows.
type Inventory struct {
	Items      []Item
	DataSHA256 string
	Rows       int64
}

func loadInventory(path string) (*Inventory, error) {
	rows := tsvRows(path)
	items := []Item{}
	for _, f := range rows {
		if !containsString(executableApplicabilities, field(f, 3)) {
			continue
		}
		item := Item{Path: field(f, 0), Kind: field(f, 1), Applicability: field(f, 3),
			Exception: strings.TrimPrefix(field(f, 4), "exception:"), DifferentialSchema: field(f, 5),
			Bytes: mustInt(field(f, 6)), SHA256: field(f, 7)}
		if item.Exception != "none" {
			return nil, fmt.Errorf("inventory: executable row %s cites exception %s", item.Path, item.Exception)
		}
		items = append(items, item)
	}
	joined := make([]string, len(rows))
	for i, f := range rows {
		joined[i] = strings.Join(f, "\t")
	}
	return &Inventory{Items: items, DataSHA256: sha256hex([]byte(strings.Join(joined, "\n") + "\n")), Rows: int64(len(rows))}, nil
}

// Accepted is one row of tests/tour/results.tsv (the pinned Go baseline).
type Accepted map[string]any

func loadAccepted(path string) map[string]Accepted {
	out := map[string]Accepted{}
	nilOrInt := func(s string) any {
		if s == "-" {
			return nil
		}
		return mustInt(s)
	}
	nilOrStr := func(s string) any {
		if s == "-" {
			return nil
		}
		return s
	}
	for _, f := range tsvRowsLoose(path) {
		out[field(f, 0)] = Accepted{
			"applicability": field(f, 1), "bytes": mustInt(field(f, 2)), "sha256": field(f, 3), "baseline": field(f, 5),
			"build_exit":   mustInt(field(f, 6)),
			"run_exit":     nilOrInt(field(f, 7)),
			"stdout_bytes": nilOrInt(field(f, 8)), "stdout_sha256": nilOrStr(field(f, 9)),
			"stderr_bytes": nilOrInt(field(f, 10)), "stderr_sha256": nilOrStr(field(f, 11)),
			"outcome": field(f, 13),
		}
	}
	return out
}

// ---------------------------------------------------------------- normalize

// normalize runs the PINNED normalizer rules (normalize.go) and returns the
// ledger's normalized-stream record.
func normalize(raw []byte) map[string]any {
	out, ok := normalizeV1(raw)
	if !ok {
		return map[string]any{"valid_utf8": false, "bytes": nil, "sha256": nil}
	}
	return map[string]any{"valid_utf8": true, "bytes": int64(len(out)), "sha256": sha256hex(out)}
}

// auditNormalize is the INDEPENDENT reimplementation of the declared
// tour-normalizer/v1 rules the gate uses to audit the recorded normalization:
// a hand-written scan rather than the regexp pass above. Returns ok=false
// for a stream that is not strict UTF-8.
func auditNormalize(raw []byte) ([]byte, bool) {
	if !validUTF8Strict(raw) {
		return nil, false
	}
	// Rule 2: CRLF / CR -> LF.
	lf := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); i++ {
		if raw[i] == '\r' {
			lf = append(lf, '\n')
			if i+1 < len(raw) && raw[i+1] == '\n' {
				i++
			}
			continue
		}
		lf = append(lf, raw[i])
	}
	// Rule 3: \b0x[0-9a-fA-F]{8,}\b -> 0xADDR.
	isWord := func(c byte) bool {
		return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
	}
	isHex := func(c byte) bool {
		return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
	}
	out := make([]byte, 0, len(lf))
	for i := 0; i < len(lf); {
		if lf[i] == '0' && i+1 < len(lf) && lf[i+1] == 'x' && (i == 0 || !isWord(lf[i-1])) {
			j := i + 2
			for j < len(lf) && isHex(lf[j]) {
				j++
			}
			if j-(i+2) >= 8 && (j == len(lf) || !isWord(lf[j])) {
				out = append(out, "0xADDR"...)
				i = j
				continue
			}
		}
		out = append(out, lf[i])
		i++
	}
	return out, true
}

// validUTF8Strict is a second, independent strict UTF-8 check: overlongs,
// surrogates and code points above U+10FFFF are rejected.
func validUTF8Strict(b []byte) bool {
	for i := 0; i < len(b); {
		c := b[i]
		switch {
		case c < 0x80:
			i++
		case c >= 0xc2 && c <= 0xdf:
			if i+1 >= len(b) || b[i+1]&0xc0 != 0x80 {
				return false
			}
			i += 2
		case c >= 0xe0 && c <= 0xef:
			if i+2 >= len(b) || b[i+1]&0xc0 != 0x80 || b[i+2]&0xc0 != 0x80 {
				return false
			}
			if c == 0xe0 && b[i+1] < 0xa0 || c == 0xed && b[i+1] >= 0xa0 {
				return false
			}
			i += 3
		case c >= 0xf0 && c <= 0xf4:
			if i+3 >= len(b) || b[i+1]&0xc0 != 0x80 || b[i+2]&0xc0 != 0x80 || b[i+3]&0xc0 != 0x80 {
				return false
			}
			if c == 0xf0 && b[i+1] < 0x90 || c == 0xf4 && b[i+1] >= 0x90 {
				return false
			}
			i += 4
		default:
			return false
		}
	}
	return true
}

// maskingReport: how much of a stream normalization removed.
func maskingReport(raw []byte, normalizedBytes any) map[string]any {
	if len(raw) == 0 {
		return map[string]any{"raw_bytes": int64(0), "normalized_bytes": toI(normalizedBytes), "emptied": false}
	}
	return map[string]any{"raw_bytes": int64(len(raw)), "normalized_bytes": toI(normalizedBytes),
		"emptied": toI(normalizedBytes) == 0}
}

// ---------------------------------------------------------------- processes

// RunResult is what run() returns: the capture facts plus the in-memory raw
// streams and the file-backed log records.
type RunResult struct {
	Spawned             bool
	State               string
	Exit                any // int64 or nil
	Signal              any
	DescendantsSurvived bool
	DurationMS          int64
	StartedAt           float64
	FinishedAt          float64
	Stdout, Stderr      []byte
	Logs                map[string]any
	InputArtifacts      map[string]any
}

// run is the ONLY process entry point in this corpus. It delegates spawning,
// deadline enforcement, process-group sweeping and descendant detection to
// Capture and converts that primitive's FILE-BACKED stream records into the
// in-memory raw bytes the tour normalizer and ledger need — re-checking each
// log against the digest the shared primitive recorded, so a log rewritten
// between capture and read is caught.
func run(argv []string, chdir string, timeout float64, env map[string]string, logPrefix string) (*RunResult, error) {
	startedAt := nowFloat()
	raw, err := Capture(argv, chdir, logPrefix, env, timeout)
	if err != nil {
		return nil, err
	}
	finishedAt := nowFloat()
	streams := map[string][]byte{}
	for _, stream := range []string{"stdout", "stderr"} {
		record := asMap(raw[stream])
		bytes := readFile(asString(record["path"]))
		if sha256hex(bytes) != asString(record["sha256"]) {
			return nil, fmt.Errorf("capture log tampered: %s", asString(record["path"]))
		}
		streams[stream] = bytes
	}
	// A signalled process has no exitstatus; 128+signal is the shell convention
	// the accepted baseline (tools/tour/run-baseline.sh) already used.
	var status any = raw["exit"]
	if status == nil && raw["signal"] != nil {
		status = 128 + toI(raw["signal"])
	}
	return &RunResult{
		Spawned: asBool(raw["spawned"]), State: asString(raw["state"]), Exit: status, Signal: raw["signal"],
		DescendantsSurvived: truthy(raw["descendants_survived"]),
		DurationMS:          int64(asFloat(raw["duration_seconds"])*1000 + 0.5),
		StartedAt:           startedAt, FinishedAt: finishedAt,
		Stdout: streams["stdout"], Stderr: streams["stderr"],
		Logs: map[string]any{"stdout": raw["stdout"], "stderr": raw["stderr"]},
	}, nil
}

// ---------------------------------------------------------------- artifacts

func artifactRecord(path string) map[string]any {
	if !fileExists(path) {
		return map[string]any{"present": false, "bytes": nil, "sha256": nil}
	}
	data := readFile(path)
	return map[string]any{"present": true, "bytes": int64(len(data)), "sha256": sha256hex(data)}
}

// sourceMapSummary records the transpiler source map's schema version, its
// ORIGIN, the per-mapping source files, the mapping count and the GENERATION
// DIGEST it claims for the emitted Go.
func sourceMapSummary(path string) map[string]any {
	if !fileExists(path) {
		return nil
	}
	failed := map[string]any{"schema_version": nil, "origin": nil, "go_digest": nil, "mappings": nil,
		"source_files": []any{}, "positioned": false}
	parsed, err := parseJSON(readFile(path))
	if err != nil {
		return failed
	}
	data, ok := parsed.(map[string]any)
	if !ok {
		return failed
	}
	mappings := asList(data["mappings"])
	if _, isList := data["mappings"].([]any); !isList {
		mappings = []any{}
	}
	files := []string{}
	positioned := true
	for _, m := range mappings {
		mm, isMap := m.(map[string]any)
		if isMap {
			if sf, ok := mm["source_file"].(string); ok {
				files = append(files, sf)
			}
		}
		if !isMap {
			positioned = false
			continue
		}
		for _, k := range []string{"go_line", "go_col", "source_line", "source_col"} {
			n, isInt := mm[k].(int64)
			if !isInt || n <= 0 {
				positioned = false
			}
		}
	}
	return map[string]any{"schema_version": data["schema_version"], "origin": data["origin"],
		"go_digest": data["go_digest"], "mappings": int64(len(mappings)),
		"source_files": anyList(sortedCopy(uniqStrings(files))), "positioned": positioned}
}

// sourceMapFailures: the source map must describe THIS transpile.
func sourceMapFailures(stage map[string]any, sourcePath string) []string {
	m := asMap(dig(stage, "artifacts", "map"))
	if !truthy(m["present"]) {
		return []string{"source_map_missing"}
	}
	summary := asMap(m["source_map"])
	findings := []string{}
	if asString(summary["schema_version"]) != "bashy-transpile-map-v1" {
		findings = append(findings, "source_map_schema:"+toS(summary["schema_version"]))
	}
	if toI(summary["mappings"]) <= 0 {
		findings = append(findings, "source_map_empty")
	}
	if !truthy(summary["positioned"]) {
		findings = append(findings, "source_map_unpositioned")
	}
	if asString(summary["origin"]) != sourcePath {
		findings = append(findings, "source_map_origin:"+toS(summary["origin"]))
	}
	files := strList(summary["source_files"])
	if !(len(files) == 0 || (len(files) == 1 && files[0] == sourcePath)) {
		findings = append(findings, "source_map_source_files:"+inspect(files))
	}
	generated := asMap(dig(stage, "artifacts", "go"))
	if truthy(generated["present"]) {
		if asString(summary["go_digest"]) != "sha256:"+toS(generated["sha256"]) {
			findings = append(findings, "source_map_generation_digest")
		}
	}
	return findings
}

// consumedArtifacts: input artifacts a stage consumes from a predecessor.
func consumedArtifacts(spec Stage) []string {
	out := []string{}
	for _, name := range []string{"go", "bin"} {
		token := map[string]string{"go": "{OUT_GO}", "bin": "{BIN}"}[name]
		if containsString(spec.ArgvTemplate, token) && !containsString(spec.Produces, name) {
			out = append(out, name)
		}
	}
	return out
}

// ---------------------------------------------------------------- statuses

// stageFailure: whether one recorded stage met its own obligation. Returns ""
// on success or the failure token that makes it authoritative.
func stageFailure(stage map[string]any) string {
	if !truthy(stage["spawned"]) {
		return "launch_failure"
	}
	if asString(stage["state"]) == "deadline" {
		return "deadline"
	}
	if asString(stage["state"]) != "exited" {
		return "state:" + toS(stage["state"])
	}
	if truthy(stage["descendants_survived"]) {
		return "descendants_survived"
	}
	if exit, ok := asInt(stage["exit"]); !ok || exit != 0 {
		return "exit:" + toS(stage["exit"])
	}
	missing := []string{}
	artifacts := asMap(stage["artifacts"])
	for _, name := range sortedKeys(artifacts) {
		if !truthy(asMap(artifacts[name])["present"]) {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return "missing_artifact:" + strings.Join(missing, ",")
	}
	if !truthy(stage["execute_body"]) {
		if toI(dig(stage, "normalized", "stdout", "bytes")) != 0 {
			return "body_executed"
		}
	}
	if !truthy(dig(stage, "normalized", "stdout", "valid_utf8")) || !truthy(dig(stage, "normalized", "stderr", "valid_utf8")) {
		return "invalid_utf8"
	}
	return ""
}

// authoritativeIndex: the FIRST stage that failed, otherwise the last stage.
func authoritativeIndex(stages []any) int {
	for i, stage := range stages {
		if stageFailure(asMap(stage)) != "" {
			return i
		}
	}
	return len(stages) - 1
}

// observationStatus recomputes an observation's status purely from its own
// recorded stages, the contract recipe, the accepted baseline row, the
// reviewed semantic verdict (for a declared-volatile row) and, for the two
// product modes, the fresh baseline observation of the same source.
func observationStatus(observation map[string]any, recipe *Recipe, accepted Accepted, baselineObservation map[string]any,
	semanticRow *SemanticRow, semanticVersion string) string {
	stages := asList(observation["stages"])
	expected := recipe.Stages
	if len(stages) != len(expected) {
		return "FAIL:stage_contract"
	}
	for i, spec := range expected {
		got := asMap(stages[i])
		artifacts := sortedKeys(asMap(got["artifacts"]))
		if asString(got["stage"]) != spec.Stage || toI(got["index"]) != spec.Index || !isInteger(got["index"]) ||
			asBool(got["execute_body"]) != spec.ExecuteBody || !equalStrings(artifacts, sortedCopy(spec.Produces)) {
			return "FAIL:stage_contract"
		}
	}
	idx := authoritativeIndex(stages)
	final := asMap(stages[idx])
	if failure := stageFailure(final); failure != "" {
		return fmt.Sprintf("FAIL:%s:%s", asString(final["stage"]), failure)
	}

	if asString(observation["mode"]) == "baseline" {
		if !baselineMatchesAccepted(observation, accepted, semanticRow == nil) {
			return "FAIL:accepted_mismatch"
		}
		if semanticRow != nil {
			return semanticVerdict(observation, semanticRow, semanticVersion)
		}
		return "PASS"
	}

	// A non-body phase has no output to compare: succeeding at the declared
	// phase IS the obligation.
	if !truthy(final["execute_body"]) {
		return "PASS"
	}
	if semanticRow != nil {
		return semanticVerdict(observation, semanticRow, semanticVersion)
	}
	if baselineObservation == nil {
		return "FAIL:no_baseline"
	}
	baseStages := asList(baselineObservation["stages"])
	base := asMap(baseStages[authoritativeIndex(baseStages)])
	if !jsonEqual(final["exit"], base["exit"]) {
		return "FAIL:mismatch"
	}
	for _, stream := range []string{"stdout", "stderr"} {
		if !jsonEqual(dig(final, "normalized", stream, "sha256"), dig(base, "normalized", stream, "sha256")) {
			return "FAIL:mismatch"
		}
	}
	return "PASS"
}

// semanticWindow: the wall-clock interval a semantic comparison is
// adjudicated against — the stages of THAT observation together with the
// native oracle repeats it is compared to. Producer and gate both call this.
func semanticWindow(stages []any, oracleRuns []any, utcOffset any) map[string]any {
	stamps := []float64{}
	for _, s := range stages {
		for _, k := range []string{"started_at", "finished_at"} {
			if v := asMap(s)[k]; v != nil {
				stamps = append(stamps, asFloat(v))
			}
		}
	}
	for _, r := range oracleRuns {
		for _, k := range []string{"started_at", "finished_at"} {
			if v := asMap(r)[k]; v != nil {
				stamps = append(stamps, asFloat(v))
			}
		}
	}
	if len(stamps) == 0 {
		return nil
	}
	sort.Float64s(stamps)
	return map[string]any{"from": stamps[0], "to": stamps[len(stamps)-1], "utc_offset": utcOffset}
}

// semanticVerdict consumes the recorded semantic verdict.
func semanticVerdict(observation map[string]any, row *SemanticRow, version string) string {
	verdict, ok := observation["semantic"].(map[string]any)
	if !ok {
		return "FAIL:semantic_missing"
	}
	if asString(verdict["comparator"]) != row.Comparator {
		return "FAIL:semantic_comparator:" + toS(verdict["comparator"])
	}
	if asString(verdict["version"]) != version {
		return "FAIL:semantic_version:" + toS(verdict["version"])
	}
	if !truthy(verdict["ok"]) {
		findings := asList(verdict["findings"])
		first := ""
		if len(findings) > 0 {
			first = toS(findings[0])
		}
		return "FAIL:semantic:" + first
	}
	return "PASS"
}

// baselineMatchesAccepted: the fresh Go baseline must reproduce the pinned
// accepted observation in tests/tour/results.tsv.
func baselineMatchesAccepted(observation map[string]any, accepted Accepted, compareStreams bool) bool {
	if accepted == nil {
		return false
	}
	stages := asList(observation["stages"])
	find := func(name string) map[string]any {
		for _, s := range stages {
			if asString(asMap(s)["stage"]) == name {
				return asMap(s)
			}
		}
		return nil
	}
	build := find("build")
	if build == nil || !jsonEqual(build["exit"], accepted["build_exit"]) {
		return false
	}
	if asString(observation["applicability"]) == "build_only_go_program" {
		return len(stages) == 1 && accepted["run_exit"] == nil
	}
	runStage := find("run")
	if runStage == nil || !jsonEqual(runStage["exit"], accepted["run_exit"]) {
		return false
	}
	if !compareStreams {
		return true
	}
	return jsonEqual(dig(runStage, "normalized", "stdout", "bytes"), accepted["stdout_bytes"]) &&
		jsonEqual(dig(runStage, "normalized", "stdout", "sha256"), accepted["stdout_sha256"]) &&
		jsonEqual(dig(runStage, "normalized", "stderr", "bytes"), accepted["stderr_bytes"]) &&
		jsonEqual(dig(runStage, "normalized", "stderr", "sha256"), accepted["stderr_sha256"])
}

// ---------------------------------------------------------------- candidate

// loadCandidateContract: docs/tour/candidate.tsv rows as generic maps.
func loadCandidateContract(path string) []map[string]any {
	out := []map[string]any{}
	for _, row := range tsvRows(path) {
		var frozen any
		if field(row, 4) != "" {
			frozen = field(row, 4)
		}
		out = append(out, map[string]any{"component": field(row, 0), "role": field(row, 1),
			"go_module_path": field(row, 2), "replace_directive": field(row, 3), "frozen_commit": frozen})
	}
	return out
}

func loadCandidateManifest(path string) (map[string]any, error) {
	parsed, err := parseJSON(readFile(path))
	if err != nil {
		return nil, err
	}
	m, ok := parsed.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("candidate manifest is not a JSON object")
	}
	return m, nil
}

// authenticateCandidate authenticates the supplied manifest with the shared
// primitive and renders the ledger's candidate record.
func authenticateCandidate(bashyPath, manifestPath string, contract []map[string]any) (map[string]any, error) {
	manifest, err := loadCandidateManifest(manifestPath)
	if err != nil {
		return nil, err
	}
	authenticated, err := AuthenticateCandidate(bashyPath, manifest)
	if err != nil {
		return nil, err
	}
	versionOut, _ := combinedOutput(bashyPath, "--version")
	versionLine := strings.TrimSpace(firstLine(versionOut))
	repositories := []any{}
	for _, item := range asList(authenticated["repositories"]) {
		repo := asMap(item)
		repositories = append(repositories, map[string]any{"path": repo["path"], "commit": repo["commit"],
			"name": filepath.Base(asString(repo["path"]))})
	}
	components := []any{}
	for _, component := range contract {
		var found map[string]any
		for _, r := range repositories {
			if asString(asMap(r)["name"]) == asString(component["component"]) {
				found = asMap(r)
				break
			}
		}
		merged := map[string]any{}
		for k, v := range component {
			merged[k] = v
		}
		merged["bound"] = found != nil
		if found != nil {
			merged["dir"] = found["path"]
			merged["commit"] = found["commit"]
		} else {
			merged["dir"] = nil
			merged["commit"] = nil
		}
		components = append(components, merged)
	}
	launcher := asMap(authenticated["launcher"])
	payload := asMap(authenticated["payload"])
	return map[string]any{
		"binding":          "manifest:launcher+payload+repository-commits",
		"authenticated_by": "AuthenticateCandidate (tools/tour/capture.go)",
		"manifest_path":    manifestPath,
		"manifest_sha256":  shaFile(manifestPath),
		"frontend_version": manifest["frontend_version"],
		"build_recipe":     manifest["build_recipe"],
		"manifest_status":  manifest["status"],
		"version_line":     versionLine,
		"binaries": map[string]any{
			"launcher": map[string]any{"path": launcher["path"], "present": true, "bytes": launcher["bytes"], "sha256": launcher["sha256"]},
			"payload":  map[string]any{"path": payload["path"], "present": true, "expected": true, "bytes": payload["bytes"], "sha256": payload["sha256"]},
		},
		"repositories":    repositories,
		"components":      components,
		"contract_sha256": nil, // filled by the runner from the on-disk contract
	}, nil
}

// candidateFailures: the gate's candidate predicate. An empty list means the
// candidate is authenticated.
func candidateFailures(candidate map[string]any) []string {
	reasons := []string{}
	if asString(candidate["binding"]) != "manifest:launcher+payload+repository-commits" {
		reasons = append(reasons, "candidate:unauthenticated_manifest")
	}
	if len(toS(candidate["manifest_sha256"])) != 64 {
		reasons = append(reasons, "candidate:no_manifest_digest")
	}
	for _, which := range []string{"launcher", "payload"} {
		binary := asMap(dig(candidate, "binaries", which))
		if !truthy(binary["present"]) {
			reasons = append(reasons, "candidate:missing_"+which)
		}
		if len(toS(binary["sha256"])) != 64 {
			reasons = append(reasons, "candidate:unbound_"+which+"_digest")
		}
	}
	components := asList(candidate["components"])
	product := false
	for _, c := range components {
		if asString(asMap(c)["role"]) == "product" {
			product = true
		}
	}
	if !product {
		reasons = append(reasons, "candidate:no_product_component")
	}
	declared := []string{}
	for _, c := range components {
		component := asMap(c)
		name := asString(component["component"])
		declared = append(declared, name)
		if !(truthy(component["bound"]) && len(toS(component["commit"])) == 40) {
			reasons = append(reasons, "candidate:unbound:"+name)
		}
		if truthy(component["frozen_commit"]) && !jsonEqual(component["commit"], component["frozen_commit"]) {
			reasons = append(reasons, "candidate:frozen_mismatch:"+name)
		}
	}
	for _, r := range asList(candidate["repositories"]) {
		repo := asMap(r)
		name := asString(repo["name"])
		if !containsString(declared, name) {
			reasons = append(reasons, "candidate:undeclared_repository:"+name)
		}
		if len(toS(repo["commit"])) != 40 {
			reasons = append(reasons, "candidate:unbound_revision:"+name)
		}
	}
	return reasons
}

// runtimeDependency: generated artifacts may import the compiler's runtime.
// Bind its build dependency to the authenticated candidate source.
func runtimeDependency(candidate map[string]any) (map[string]any, error) {
	components, ok := candidate["components"]
	if !ok {
		return nil, fmt.Errorf("key not found: \"components\"")
	}
	for _, c := range asList(components) {
		component := asMap(c)
		if asString(component["component"]) == "sh" {
			if !truthy(component["bound"]) {
				break
			}
			for _, k := range []string{"dir", "commit"} {
				if _, present := component[k]; !present {
					return nil, fmt.Errorf("key not found: %q", k)
				}
			}
			return map[string]any{"module": "mvdan.cc/sh/v3", "require_version": "v3.0.0",
				"dir": component["dir"], "commit": component["commit"]}, nil
		}
	}
	return nil, contractError("candidate lacks sh runtime component")
}

// ---------------------------------------------------------------- ledger

func ledgerRoot(records []map[string]any) string {
	lines := make([]string, len(records))
	for i, record := range records {
		lines[i] = canonical(record)
	}
	return sha256hex([]byte(strings.Join(lines, "\n") + "\n"))
}

func writeLedger(path string, records []map[string]any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var b strings.Builder
	for _, record := range records {
		b.WriteString(canonical(record))
		b.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func readLedger(path string) ([]map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	records := []map[string]any{}
	text := string(data)
	if strings.HasSuffix(text, "\n") {
		text = text[:len(text)-1]
	}
	if text == "" {
		return records, nil
	}
	for i, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		parsed, err := parseJSON([]byte(line))
		if err != nil {
			return nil, fmt.Errorf("line %d: %v", i+1, err)
		}
		if canonical(parsed) != line {
			return nil, fmt.Errorf("non-canonical JSON on line %d", i+1)
		}
		record, ok := parsed.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("line %d is not an object", i+1)
		}
		records = append(records, record)
	}
	return records, nil
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return line
}

// combinedOutput mirrors Open3.capture2e: stdout+stderr as one string.
func combinedOutput(name string, args ...string) (string, error) {
	cmd := execCommand(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func execCommand(name string, args ...string) *exec.Cmd {
	return exec.Command(name, args...)
}

// shellOutput mirrors a backtick capture of one command's stdout, trimmed,
// with `env` overlaid on the ambient environment (stderr discarded).
func shellOutput(env map[string]string, name string, args ...string) string {
	cmd := exec.Command(name, args...)
	if env != nil {
		cmd.Env = append(os.Environ(), envSlice(env)...)
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// strictB64 mirrors Base64.strict_decode64.
func strictB64(s string) ([]byte, bool) {
	out, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, false
	}
	return out, true
}
