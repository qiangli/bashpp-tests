// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Diagnostic grouping only, ported from tools/go-by-example/
// summarize-evidence.rb. This never changes a verdict or certifies a run.
package main

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

var reSelectorFamily = regexp.MustCompile(`BASHPP-ESELECTOR-(?:ROOT|TYPE)`)

func summarizeDiagnostics(attempt *Object) (string, []byte) {
	stderr, _ := b64decode(attempt.Str("raw_stderr_b64"))
	var failed *Object
	for _, s := range attempt.Arr("stages") {
		stage, _ := s.(*Object)
		if stage == nil || stage.Str("stage") == "run" {
			continue
		}
		if stage.Str("state") != "complete" || !deepEqual(stage.Get("exit"), Int(0)) {
			failed = stage
			break
		}
	}
	if failed != nil {
		path := ""
		if capture := failed.Obj("capture"); capture != nil && capture.Obj("stderr") != nil {
			path = capture.Obj("stderr").Str("path")
		}
		if path != "" && isRegularFile(path) {
			stderr, _ = os.ReadFile(path)
		} else {
			stderr = []byte(failed.Str("stderr_head"))
		}
		return failed.Str("stage"), stderr
	}
	return "run", stderr
}

func summarizeFamily(attempt *Object, diagnosticBytes []byte) string {
	diagnostic := string(diagnosticBytes)
	has := func(s string) bool { return strings.Contains(diagnostic, s) }
	switch {
	case attempt.Str("verdict") == "pass":
		return "pass"
	case attempt.Str("state") == "input_mutation":
		return "phase-input-mutation"
	case contains([]string{"timeout", "leak", "cleanup_error", "adapter_error"}, attempt.Str("state")):
		return "deadline-or-descendant"
	case has("unsupported expression *ast.ArrayType"):
		return "source-conversion-array-type"
	case has("unsupported expression *ast.FuncType"):
		return "source-conversion-function-type"
	case has("unsupported type *ast.IndexExpr"):
		return "generic-type-index"
	case has("invalid receiver type"):
		return "generic-method-receiver"
	case has("__bpp0_popPanic"):
		return "recover-lowering"
	case has("cannot take address of"):
		return "addressable-aggregate-lowering"
	case has("MustValue"):
		return "native-generic-tuple-lowering"
	case has("unregistered bridge type"):
		return "local-named-bridge-type"
	case has("dependency process exited: exit status"):
		return "native-process-exit-propagation"
	case has("undefined type: __gosource_import"):
		return "imported-structured-type"
	case reSelectorFamily.MatchString(diagnostic):
		return "imported-aggregate-selector"
	case has("unsupported unary operator ILLEGAL"):
		return "channel-receive-expression"
	case has("unsupported scalar expression *syntax.BashPPCompositeLit"):
		return "aggregate-composite-expression"
	case has("unsupported scalar expression *syntax.BashPPAddressExpr"):
		return "address-argument"
	case has("BASHPP-ESTRUCT-UNKNOWN"):
		return "local-struct-field"
	case has("assignment mismatch:"):
		return "multiple-assignment-or-tuple"
	case has("not assignable to"):
		return "native-argument-type-identity"
	case has("BASHPP-EEXPR-UNDEFINED") || has("function literal"):
		return "callback-or-callable-value"
	case has("GOPROXY=off") || has("updates to go.mod needed"):
		return "offline-build-dependency"
	}
	for _, s := range attempt.Arr("stages") {
		if stage, _ := s.(*Object); stage != nil && stage.Str("state") == "invalid_source_map" {
			return "source-map-contract"
		}
	}
	switch {
	case attempt.Str("verdict") == "fail_effects":
		return "runtime-filesystem-effects"
	case attempt.Str("verdict") == "fail_normalization":
		return "comparator-shape-or-prior-error"
	case attempt.Str("state") == "unspawned":
		return "stage-unavailable"
	case diagnostic != "":
		return "program-diagnostic"
	}
	return "output-or-status-mismatch"
}

func summarizeMain(args []string) {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: summarize EVIDENCE_JSONL OUTPUT_DIRECTORY")
		os.Exit(1)
	}
	input, output := args[0], args[1]
	bytes, err := os.ReadFile(input)
	if err != nil {
		fatal(err.Error())
	}
	lines := rubyLines(string(bytes))
	if !strings.HasSuffix(string(bytes), "\n") && strings.HasSuffix(input, ".progress.jsonl") && len(lines) > 0 {
		lines = lines[:len(lines)-1]
	}
	var records []*Object
	for _, line := range lines {
		v, err := Parse([]byte(line))
		if err != nil {
			fatal("unexpected token: " + err.Error())
		}
		o, _ := v.(*Object)
		records = append(records, o)
	}
	if len(records) == 0 || records[0] == nil || records[0].Str("type") != "manifest" {
		fatal("missing manifest")
	}
	manifest := records[0]
	binding := sha256Hex([]byte(Generate(manifest)))
	var attempts []*Object
	var summary *Object
	for _, r := range records {
		if r == nil {
			continue
		}
		if r.Str("type") == "attempt" {
			attempts = append(attempts, r)
		}
		if r.Str("type") == "summary" && summary == nil {
			summary = r
		}
	}
	for _, attempt := range attempts {
		body := attempt.Without("evidence_sha256")
		if attempt.Str("binding_sha256") != binding || sha256Hex([]byte(Generate(body))) != attempt.Str("evidence_sha256") {
			fatal("invalid attempt integrity")
		}
	}

	var rows []*Object
	for _, attempt := range attempts {
		phase, diagnostic := summarizeDiagnostics(attempt)
		captures := []any{}
		for _, s := range attempt.Arr("stages") {
			stage, _ := s.(*Object)
			if stage == nil || stage.Obj("capture") == nil {
				continue
			}
			capture := stage.Obj("capture")
			sliced := NewObject()
			for _, key := range []string{"argv", "cwd", "environment", "stdout", "stderr", "timeout_seconds"} {
				if capture.Has(key) {
					sliced.Set(key, capture.Get(key))
				}
			}
			captures = append(captures, sliced)
		}
		stdout, _ := b64decode(attempt.Str("raw_stdout_b64"))
		rows = append(rows, Obj(
			"path", attempt.Get("path"), "mode", attempt.Get("mode"),
			"verdict", attempt.Get("verdict"), "state", attempt.Get("state"), "exit", attempt.Get("exit"),
			"phase", phase, "family", summarizeFamily(attempt, diagnostic),
			"diagnostic", string(diagnostic), "stdout", string(stdout),
			"effects_delta", attempt.Get("effects_delta"),
			"captures", captures,
		))
	}
	var summaryValue any
	if summary != nil {
		summaryValue = summary
	}
	var expectedAttempts any
	if d := manifest.Obj("denominator"); d != nil {
		expectedAttempts = d.Get("attempts")
	}
	var candidateSHA any
	if c := manifest.Obj("candidate"); c != nil {
		candidateSHA = c.Get("manifest_sha256")
	}
	seenPaths := map[string]bool{}
	for _, a := range attempts {
		seenPaths[a.Str("path")] = true
	}
	// modes: per mode, verdict counts in first-seen order (group_by semantics).
	modes := NewObject()
	for _, a := range attempts {
		mode := a.Str("mode")
		if !modes.Has(mode) {
			modes.Set(mode, NewObject())
		}
		counts := modes.Obj(mode)
		n, _ := counts.Int(a.Str("verdict"))
		counts.Set(a.Str("verdict"), Int(n+1))
	}
	type familyKey struct{ mode, family string }
	familyPaths := map[familyKey][]any{}
	var familyOrder []familyKey
	for _, row := range rows {
		key := familyKey{row.Str("mode"), row.Str("family")}
		if _, ok := familyPaths[key]; !ok {
			familyOrder = append(familyOrder, key)
		}
		familyPaths[key] = append(familyPaths[key], row.Get("path"))
	}
	sort.Slice(familyOrder, func(i, j int) bool {
		if familyOrder[i].mode != familyOrder[j].mode {
			return familyOrder[i].mode < familyOrder[j].mode
		}
		return familyOrder[i].family < familyOrder[j].family
	})
	families := []any{}
	for _, key := range familyOrder {
		families = append(families, Obj("mode", key.mode, "family", key.family, "count", Int(int64(len(familyPaths[key]))), "paths", familyPaths[key]))
	}
	report := Obj(
		"purpose", "failure taxonomy; original execution verdicts preserved",
		"input", expandPath(input), "input_sha256", sha256Hex(bytes),
		"candidate_manifest_sha256", candidateSHA,
		"complete_ledger", summary != nil, "expected_attempts", expectedAttempts,
		"recorded_attempts", Int(int64(len(attempts))), "recorded_rows", Int(int64(len(seenPaths))),
		"summary", summaryValue,
		"modes", modes,
		"families", families,
	)
	os.MkdirAll(output, 0o755)
	os.WriteFile(output+"/taxonomy.json", []byte(Pretty(report)+"\n"), 0o644)
	var failures []string
	var ledger []string
	ledger = append(ledger, strings.Join([]string{"path", "mode", "verdict", "state", "exit", "phase", "family"}, "\t"))
	for _, row := range rows {
		if row.Str("verdict") != "pass" {
			failures = append(failures, Generate(row))
		}
		exit := ""
		if n, ok := row.Get("exit").(Number); ok {
			exit = n.String()
		}
		ledger = append(ledger, strings.Join([]string{row.Str("path"), row.Str("mode"), row.Str("verdict"), row.Str("state"), exit, row.Str("phase"), row.Str("family")}, "\t"))
	}
	os.WriteFile(output+"/failures.jsonl", []byte(strings.Join(failures, "\n")+"\n"), 0o644)
	os.WriteFile(output+"/ledger.tsv", []byte(strings.Join(ledger, "\n")+"\n"), 0o644)
	fmt.Println(Generate(Obj("complete_ledger", summary != nil, "recorded_rows", Int(int64(len(seenPaths))), "recorded_attempts", Int(int64(len(attempts))), "modes", modes)))
}
