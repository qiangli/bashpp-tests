// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Authenticate a retained bounded diagnostic, ported from
// tools/go-by-example/validate-bounded-evidence.rb. This validator is
// intentionally separate from, and cannot select rows for, the production
// gate.
//
// It authenticates each reviewed bounded candidate independently, selected by
// the candidate manifest digest recorded in the evidence. Candidate024 (the
// two-row generic-receiver diagnostic) and Candidate025 (the one-row recursion
// diagnostic) are both covered. The shared docs/go-by-example/candidates.tsv is
// an append-only reviewed table, so each run authenticates the exact byte prefix
// ending at its selected manifest row before re-deriving that row through the
// shared primitives. Candidates024-027 are covered, and adding a newer reviewed
// candidate row therefore can never invalidate an older bounded run.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type boundedCase struct {
	sha256     string
	bytes      int64
	diagnostic string // interpreted mismatch diagnostic, "" when every mode passes
	exit       int64
	mismatch   bool
}

type boundedCandidate struct {
	label                 string
	rows                  int
	attempts              int
	evidenceSHA256        string
	inventorySHA256       string
	recordedCandidatesSHA string
	ledger                string
	ledgerSHA256          string
	rootDigest            string
	casePaths             []string
	cases                 map[string]boundedCase
}

// One immutable record per reviewed bounded candidate, keyed by the candidate
// manifest digest the evidence carries. `cases` maps a source path to its bound
// bytes/digest; a mismatch entry means that mode is a reviewed mismatch with
// the named diagnostic and exit, and its absence means every mode passes.
var boundedCandidates = map[string]boundedCandidate{
	"2aef622e6c5db1a04b168e1fc508dd125c80ab7ef10eacbeab8183bc37eefd01": {
		label: "Candidate024", rows: 2, attempts: 6,
		evidenceSHA256:        "487d225f2ff8fc0d7002dc294e7a2b2ffc7726f803a462f2d1840e86307a6dc2",
		inventorySHA256:       "e6dd7e665dab8dc3a2d5d86123edaf3e1734fcc4f096bcd7e0f72f7f2d9eba38",
		recordedCandidatesSHA: "6fb7829f5456f288f0eb06c7b33499f90ff69ae651e00db0d995f6404acaf02c",
		ledger:                "sprint118-candidate024-ledger.tsv",
		ledgerSHA256:          "134638c3beff5a0894dc9e99df98a3b0a1c0bfdd06610b5e88ddc3adf5fe8f04",
		rootDigest:            "07858fc7e7dce884e536538d4166de1e6c2670590262cdb3758e243627a011c5",
		casePaths:             []string{"examples/generics/generics.go", "examples/range-over-iterators/range-over-iterators.go"},
		cases: map[string]boundedCase{
			"examples/generics/generics.go": {sha256: "d070bee32f553632b83695063238193edb07d29ba609d12fb478d461dc352563", bytes: 2236,
				mismatch: true, diagnostic: "BASHPP-EGENERIC-CONSTRAINT: []string does not satisfy constraint for S in SlicesIndex", exit: 1},
			"examples/range-over-iterators/range-over-iterators.go": {sha256: "7ee6216ba19fe8e06821e1e46391a5040f3ae29c289f477d17c6a5f1b8f60717", bytes: 2667,
				mismatch: true, diagnostic: "BASHPP-ESELECTOR-TYPE: assignment parent is not struct storage", exit: 2},
		},
	},
	"3f74313ced28b23ee6e7bf738915db884ec7edb80015c191ad762241a390d213": {
		label: "Candidate025", rows: 1, attempts: 3,
		evidenceSHA256:        "9fc7ce20e0a4152c7af85a5df8bfb59e2a77b2f7b3bcbfd02b954d8d7afb6564",
		inventorySHA256:       "c8bdcbaccc3977211d339092b887eee84e17da6adfaff407e98e32f21529dd64",
		recordedCandidatesSHA: "cc3fc32dc2682209aa76355485b1707926d7fcdfe0e4b9e4d230cdbab4d072e1",
		ledger:                "sprint118-candidate025-ledger.tsv",
		ledgerSHA256:          "2bd1a8386e516bb2054c63a40e2588d99abff370a8576d11bab99da4679f1232",
		rootDigest:            "af459aa1743b6378c30539b1b28b5e13219ef65dc39b2e0f1f8215e90c89307a",
		casePaths:             []string{"examples/recursion/recursion.go"},
		cases: map[string]boundedCase{
			"examples/recursion/recursion.go": {sha256: "3e64a878e9dd7226620ed33e36c74318b0d75bf9d0119ce02094c95b78353ec2", bytes: 778},
		},
	},
	"ba070aae2debb02c231cedb3625ad54e04cc20b71ad99e2125d4c202f7771aa8": {
		label: "Candidate026", rows: 1, attempts: 3,
		evidenceSHA256:        "6ac6b399931c17e0eb2b96ec993ac56cfd06d6266ebc8ce57ae7db54e580b2b1",
		inventorySHA256:       "1b93b5bc0255f5c409f5e1f71c15b0f3d16c68e41bc1250d80ad8e9d3ca57257",
		recordedCandidatesSHA: "6a5555ceb2995730eb3ecd16a8282ab91eca85364f46fb613f19be1480bf6470",
		ledger:                "sprint118-candidate026-ledger.tsv",
		ledgerSHA256:          "0980dc4331f1599e3e6d622aef9c69a534b521d297c438f7c36292be54de142e",
		rootDigest:            "aaa7c16794ea3436252892abc21d17b62802133b9d9ab6efd91306ddd1a929dd",
		casePaths:             []string{"examples/generics/generics.go"},
		cases: map[string]boundedCase{
			"examples/generics/generics.go": {sha256: "d070bee32f553632b83695063238193edb07d29ba609d12fb478d461dc352563", bytes: 2236,
				mismatch: true, diagnostic: "BASHPP-ESELECTOR-TYPE: assignment parent is not struct storage", exit: 2},
		},
	},
	"f86c94dffe4d734e00be21cf15a622a24072427653f2caeba8bb440fc77ba279": {
		label: "Candidate027", rows: 1, attempts: 3,
		evidenceSHA256:        "0424321650327bb8b03ed61abce40626d6cc8d607db319752b772f034fc1363c",
		inventorySHA256:       "ea0c1d26fefb6693673963029d386c1287db248a7a466252490d7cf547dc6afd",
		recordedCandidatesSHA: "bd496738dac24ff1ef721a328640a250afb08ad0cf2749635ce0f2704d7501e0",
		ledger:                "sprint118-candidate027-ledger.tsv",
		ledgerSHA256:          "527e0827951af30033371665f8625568105a68758382821333c99cd784106459",
		rootDigest:            "1a5c5b733829aa611ad9f2658182f5dcd92a59255deb7f18c43fca727c852ee2",
		casePaths:             []string{"examples/range-over-iterators/range-over-iterators.go"},
		cases: map[string]boundedCase{
			"examples/range-over-iterators/range-over-iterators.go": {sha256: "7ee6216ba19fe8e06821e1e46391a5040f3ae29c289f477d17c6a5f1b8f60717", bytes: 2667},
		},
	},
}

func checkedFile(path, description string) string {
	if !isRegularFile(path) {
		fatal(description + " missing")
	}
	real, err := realPath(path)
	if err != nil {
		fatal(description + " unavailable: " + err.Error())
	}
	return real
}

// authenticatedCandidatePrefix authenticates the exact historical table
// prefix, rather than the mutable whole table. The selected manifest must
// occur in exactly one complete TSV row; its newline is part of the
// authenticated prefix.
func authenticatedCandidatePrefix(tablePath, manifestSHA, recordedSHA string) string {
	table, err := os.ReadFile(tablePath)
	if err != nil {
		fatal("candidate table unavailable")
	}
	offset := 0
	var matches []int
	for _, line := range rubyLines(string(table)) {
		offset += len(line)
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(strings.TrimSuffix(line, "\n"), "\t")
		if len(fields) > 2 && fields[2] == manifestSHA {
			matches = append(matches, offset)
		}
	}
	if len(matches) != 1 {
		fatal("candidate manifest row is not unique in candidate table")
	}
	prefix := string(table[:matches[0]])
	if !strings.HasSuffix(prefix, "\n") {
		fatal("candidate manifest row is not newline-terminated")
	}
	if sha256Hex([]byte(prefix)) != recordedSHA {
		fatal("candidate table binding changed")
	}
	if !strings.HasPrefix(string(table), prefix) {
		fatal("current candidate table does not begin with authenticated prefix")
	}
	return prefix
}

func validateBoundedEvidenceMain(args []string) {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: validate-bounded-evidence EVIDENCE INVENTORY")
		os.Exit(1)
	}
	die := fatal
	evidencePath := checkedFile(args[0], "bounded evidence")
	inventoryPath := checkedFile(args[1], "bounded inventory")
	candidateTable := checkedFile(DOCS+"/candidates.tsv", "candidate table")

	records, err := readEvidence(evidencePath)
	if err != nil {
		die("bounded evidence is not JSONL: " + err.Error())
	}
	if len(records) < 3 || records[0].Str("type") != "manifest" || records[len(records)-1].Str("type") != "summary" {
		die("evidence shape is not manifest, attempts, summary")
	}
	manifest, attempts, summary := records[0], records[1:len(records)-1], records[len(records)-1]
	candidate := manifest.Obj("candidate")
	if candidate == nil {
		die("candidate record missing")
	}
	selected := candidate.Str("manifest_sha256")
	entry, ok := boundedCandidates[selected]
	if !ok {
		die("evidence names an unreviewed bounded candidate: " + selected)
	}
	ledgerPath := checkedFile(DOCS+"/"+entry.ledger, fmt.Sprintf("%d-row summary", entry.attempts))

	if sha(inventoryPath) != entry.inventorySHA256 {
		die("bounded inventory digest changed")
	}
	inventory, _ := readTSV(inventoryPath)
	var inventoryPaths []string
	for _, row := range inventory {
		inventoryPaths = append(inventoryPaths, row[0])
	}
	if strings.Join(inventoryPaths, "\n") != strings.Join(entry.casePaths, "\n") {
		die("bounded inventory is not exactly the reviewed diagnostic set")
	}
	for _, row := range inventory {
		path := row[0]
		expected := entry.cases[path]
		if len(row) != 8 || strings.Join(row[1:6], "\t") != "program\tdeterministic\tnone\tnone\tnone" {
			die("malformed bounded inventory row: " + path)
		}
		if row[6] != fmt.Sprint(expected.bytes) || row[7] != expected.sha256 {
			die("bounded inventory source binding changed: " + path)
		}
		source := checkedFile(ROOT+"/"+path, "bounded source "+path)
		if fileSize(source) != expected.bytes || sha(source) != expected.sha256 {
			die("bounded source changed: " + path)
		}
	}

	if len(records) != entry.attempts+2 {
		die(fmt.Sprintf("evidence shape is not manifest, %d attempts, summary", entry.attempts))
	}
	if !deepEqual(manifest.Get("schema"), Int(8)) || manifest.Str("story") != "Sprint118/Story3/fa07603b71dc" {
		die("wrong evidence schema or originating corpus story")
	}
	if !deepEqual(manifest.Get("denominator"), Obj("rows", Int(int64(entry.rows)), "modes_per_row", Int(3), "attempts", Int(int64(entry.attempts)))) || !deepEqual(manifest.Get("modes"), MODES) {
		die(fmt.Sprintf("bounded denominator is not exactly %d x 3", entry.rows))
	}
	if manifest.Str("corpus_sha256") != entry.inventorySHA256 {
		die("manifest inventory binding changed")
	}
	var corpusRootText strings.Builder
	for _, row := range inventory {
		corpusRootText.WriteString(row[0] + "\x00" + row[7] + "\n")
	}
	if manifest.Str("corpus_root_sha256") != sha256Hex([]byte(corpusRootText.String())) {
		die("manifest inventory root changed")
	}

	if candidate.Str("candidates_sha256") != entry.recordedCandidatesSHA {
		die("candidate table digest recorded by this run changed")
	}
	if candidate.Str("manifest_sha256") != selected {
		die("candidate manifest binding changed")
	}
	authenticatedCandidatePrefix(candidateTable, selected, entry.recordedCandidatesSHA)
	candidatePath, err := manifestPath(candidate.Str("manifest_path"))
	if err != nil {
		die("candidate authentication failed: " + err.Error())
	}
	reviewed, err := reviewedCandidate(DOCS+"/candidates.tsv", candidate.Str("manifest_sha256"))
	if err != nil {
		die("candidate authentication failed: " + err.Error())
	}
	toolchain, err := toolchainPin(DOCS + "/toolchain.tsv")
	if err != nil {
		die("candidate authentication failed: " + err.Error())
	}
	provenance, err := authenticateManifest(candidatePath, candidate.Str("launcher_path"), reviewed, toolchain, DOCS)
	if err != nil {
		die("candidate authentication failed: " + err.Error())
	}
	for _, key := range []string{"manifest_sha256", "launcher_sha256", "payload_sha256", "frontend_version", "build_recipe", "go_identity"} {
		if !deepEqual(candidate.Get(key), reviewed.Fields[key]) {
			die("candidate " + key + " differs from reviewed row")
		}
	}
	if !deepEqual(candidate.Get("repositories"), reviewed.RepositoryRecords()) {
		die("candidate repositories differ from reviewed row")
	}
	if provenance.Obj("manifest").Str("sha256") != selected {
		die("authenticated candidate provenance changed")
	}

	var expectedPairs, actualPairs []string
	for _, path := range entry.casePaths {
		for _, mode := range MODES {
			expectedPairs = append(expectedPairs, path+"\x00"+mode)
		}
	}
	for _, attempt := range attempts {
		actualPairs = append(actualPairs, attempt.Str("path")+"\x00"+attempt.Str("mode"))
	}
	if strings.Join(actualPairs, "\n") != strings.Join(expectedPairs, "\n") {
		die("attempt scope or order changed")
	}
	binding := sha256Hex([]byte(Generate(manifest)))
	retainedRoot := filepath.Dir(candidatePath) + "/"
	seenStreams := map[string]bool{}
	for _, attempt := range attempts {
		label := attempt.Str("path") + ":" + attempt.Str("mode")
		body := attempt.Without("evidence_sha256")
		if attempt.Str("binding_sha256") != binding {
			die("attempt binding changed: " + label)
		}
		if attempt.Str("evidence_sha256") != sha256Hex([]byte(Generate(body))) {
			die("attempt self-hash changed: " + label)
		}
		if !attempt.Bool("spawned") || attempt.Str("state") != "complete" {
			die("attempt was not executed completely: " + label)
		}
		for _, stream := range []string{"stdout", "stderr"} {
			if !deepEqual(attempt.Get("normalized_"+stream+"_b64"), attempt.Get("raw_"+stream+"_b64")) {
				die("stored normalized output differs from deterministic raw bytes: " + label)
			}
		}
		delta, hasDelta := attempt.Get("effects_delta").(string)
		if !hasDelta {
			die("key not found: \"effects_delta\"")
		}
		if attempt.Str("effects_sha256") != sha256Hex([]byte(delta)) {
			die("stored effect digest differs from recorded delta")
		}
		stages := stageList(attempt)
		if len(stages) == 0 || stages[len(stages)-1] == nil || stages[len(stages)-1].Str("stage") != "run" {
			die("missing run stage: " + label)
		}
		for _, stage := range stages {
			capture := stage.Obj("capture")
			if capture == nil {
				continue
			}
			for _, stream := range []string{"stdout", "stderr"} {
				artifact := capture.Obj(stream)
				if artifact == nil {
					die("missing retained " + stream + " record")
				}
				path := checkedFile(artifact.Str("path"), "retained "+stream)
				if !strings.HasPrefix(path, retainedRoot) {
					die("retained stream escaped the " + entry.label + " root")
				}
				if seenStreams[path] {
					die("duplicate retained stream path")
				}
				seenStreams[path] = true
				actualSHA, actualBytes := sha(path), fileSize(path)
				if !deepEqual(artifact.Get("sha256"), actualSHA) || !deepEqual(artifact.Get("bytes"), Int(actualBytes)) || stage.Str(stream+"_sha256") != actualSHA {
					die("retained " + stream + " changed")
				}
				if stage.Str("stage") == "run" {
					raw, err := b64decode(attempt.Str("raw_" + stream + "_b64"))
					data, _ := os.ReadFile(path)
					if err != nil || string(data) != string(raw) {
						die("run " + stream + " differs from retained raw bytes")
					}
				}
			}
		}
		run := stages[len(stages)-1]
		if !deepEqual(run.Get("spawned"), attempt.Get("spawned")) || !deepEqual(run.Get("state"), attempt.Get("state")) || !deepEqual(run.Get("exit"), attempt.Get("exit")) {
			die("run-stage result differs from attempt")
		}
	}

	find := func(path, mode string) *Object {
		for _, attempt := range attempts {
			if attempt.Str("path") == path && attempt.Str("mode") == mode {
				return attempt
			}
		}
		return nil
	}
	for _, path := range entry.casePaths {
		expected := entry.cases[path]
		oracle, interpreted, compiled := find(path, "oracle"), find(path, "interpreted"), find(path, "compiled")
		for _, attempt := range []*Object{oracle, compiled} {
			if !deepEqual(attempt.Get("exit"), Int(0)) || attempt.Str("verdict") != "pass" {
				die("expected successful observation changed: " + path + ":" + attempt.Str("mode"))
			}
			if attempt.Str("mode") == "compiled" {
				for _, key := range []string{"normalized_stdout_b64", "normalized_stderr_b64", "effects_sha256"} {
					if !deepEqual(attempt.Get(key), oracle.Get(key)) {
						die("compiled observation differs from oracle: " + path)
					}
				}
			}
		}
		if expected.mismatch {
			diagnostic, err := b64decode(interpreted.Str("raw_stderr_b64"))
			if err != nil || !deepEqual(interpreted.Get("exit"), Int(expected.exit)) || interpreted.Str("verdict") != "fail_mismatch" || !strings.Contains(string(diagnostic), expected.diagnostic) {
				die("interpreted diagnostic changed: " + path)
			}
		} else {
			if !deepEqual(interpreted.Get("exit"), Int(0)) || interpreted.Str("verdict") != "pass" {
				die("expected passing interpreted observation changed: " + path)
			}
			for _, key := range []string{"normalized_stdout_b64", "normalized_stderr_b64", "effects_sha256"} {
				if !deepEqual(interpreted.Get(key), oracle.Get(key)) {
					die("interpreted observation differs from oracle: " + path)
				}
			}
		}
	}

	failures := []any{}
	for _, attempt := range attempts {
		if attempt.Str("verdict") != "pass" {
			failures = append(failures, attempt.Str("path")+":"+attempt.Str("mode")+":"+attempt.Str("verdict"))
		}
	}
	verdict := "pass"
	if len(failures) > 0 {
		verdict = "fail"
	}
	derived := Obj("verdict", verdict, "denominator", Int(int64(entry.attempts)), "attempt_records", Int(int64(entry.attempts)),
		"executed", Int(int64(entry.attempts)), "missing_or_unspawned", Int(0), "failures", failures)
	for _, key := range derived.Keys() {
		if !deepEqual(summary.Get(key), derived.Get(key)) {
			die("summary counts or failures changed")
		}
	}
	summaryBody := summary.Without("root_digest")
	chain := []string{binding}
	for _, attempt := range attempts {
		chain = append(chain, attempt.Str("evidence_sha256"))
	}
	chain = append(chain, sha256Hex([]byte(Generate(summaryBody))))
	calculatedRoot := sha256Hex([]byte(strings.Join(chain, "\n")))
	if summary.Str("root_digest") != calculatedRoot {
		die("summary-bound root digest changed")
	}
	if calculatedRoot != entry.rootDigest {
		die("bounded root is not the reviewed " + entry.label + " root")
	}

	ledger, _ := readTSV(ledgerPath)
	if sha(ledgerPath) != entry.ledgerSHA256 {
		die(fmt.Sprintf("%d-row summary digest changed", entry.attempts))
	}
	var expectedLedger []string
	for _, attempt := range attempts {
		exit := ""
		if n, ok := attempt.Get("exit").(Number); ok {
			exit = n.String()
		}
		fields := []string{attempt.Str("path"), attempt.Str("mode"), attempt.Str("verdict"), attempt.Str("state"), exit}
		c := entry.cases[attempt.Str("path")]
		if attempt.Str("mode") == "interpreted" && c.mismatch {
			fields = append(fields, c.diagnostic)
		}
		expectedLedger = append(expectedLedger, strings.Join(fields, "\t"))
	}
	var actualLedger []string
	for _, row := range ledger {
		actualLedger = append(actualLedger, strings.Join(row, "\t"))
	}
	if strings.Join(actualLedger, "\n") != strings.Join(expectedLedger, "\n") {
		die(fmt.Sprintf("%d-row summary differs from retained attempts", entry.attempts))
	}
	if sha(evidencePath) != entry.evidenceSHA256 {
		die("bounded evidence bytes are not the reviewed " + entry.label + " ledger")
	}

	passes := entry.attempts - len(failures)
	tail := "no parity claim"
	if len(failures) > 0 {
		tail = fmt.Sprintf("%d interpreted fail, no parity claim", len(failures))
	}
	rowsWord := "rows"
	if entry.rows == 1 {
		rowsWord = "row"
	}
	fmt.Printf("PASS: bounded %s evidence: %d %s, %d attempts, %d pass, %s, root %s\n", entry.label, entry.rows, rowsWord, entry.attempts, passes, tail, calculatedRoot)
}
