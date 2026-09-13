// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Narrow semantic comparators for the declared-volatile tour rows — the Go
// port of tools/tour/semantics.rb (Sprint 118 / Story #4 / Story-ID
// 759341a95870), unchanged in contract: `tour-semantics/v2`, with the v1
// sampled-range rule reproduced exactly for authenticating retained ledgers.
//
// WHAT THIS IS NOT. It is not a mask. No comparator returns true
// unconditionally, none of them widens the normalizer, and none of them hides
// a value, a count, an order or a status: exit status and stderr are compared
// EXACTLY against the oracle in every case; only stdout is adjudicated
// semantically, and only for the elements docs/tour/semantics.tsv names as
// volatile; every invariant is also applied to every ORACLE observation, so a
// comparator that does not describe the real program fails on the oracle
// before it can excuse a candidate.
//
// Every finding string is sealed into the ledger and recomputed by the gate,
// so the renderings (`inspect`, Ruby float formatting) are reproduced byte
// for byte.
package main

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	semanticsVersion       = "tour-semantics/v2"
	semanticsLegacyVersion = "tour-semantics/v1"
	// Fewer repeats than this cannot establish a range or a multiplicity, so a
	// thin oracle is a failure rather than a licence.
	minOracleRuns = 5
	// A native program prints its error/clock line immediately; a monotonic
	// reading far from zero means the recorded line did not come from this run.
	maxMonotonicSeconds = 60.0
	// Slack around the recorded window for a wall-clock comparison.
	clockSlackSeconds = 120.0
)

var (
	comparators    = []string{"rand_intn_line", "say_interleaving", "channel_sum_order", "tick_boom_sequence", "weekday_switch", "hour_greeting", "go_time_error_line", "line_set", "webcrawler_crawl", "sandbox_time"}
	burstVariation = []string{"required", "not_required"}
	// Go's time.Time default layout, as printed by fmt for a native run:
	//   2026-09-08 21:19:44.164138 -0700 PDT m=+0.000073835
	goTimeRE   = regexp.MustCompile(`\A(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,9})? [+-]\d{4}) (\S+)(?: m=([+-]\d+(?:\.\d+)?))?\z`)
	durationRE = regexp.MustCompile(`\A(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m)\z`)
	tickLineRE = regexp.MustCompile(`\A\[\s*([0-9][^\]]*)\]\s+(tick\.|BOOM!|\.)\z`)
	intRE      = regexp.MustCompile(`\A-?\d+\z`)

	crawlFoundRE   = regexp.MustCompile(`\AFound: (\S+) "(.*)"\z`)
	crawlChildRE   = regexp.MustCompile(`\A-> Crawling child (\d+)/(\d+) of (\S+) : (\S+)\.\z`)
	crawlWaitRE    = regexp.MustCompile(`\A<- \[(\S+)\] (\d+)/(\d+) Waiting for child (\S+)\.\z`)
	crawlErrorRE   = regexp.MustCompile(`\A<- Error on (.+?): (.+)\z`)
	crawlAlreadyRE = regexp.MustCompile(`\A<- Done with (\S+), already fetched\.\z`)
	crawlDepth0RE  = regexp.MustCompile(`\A<- Done with (\S+), depth 0\.\z`)
	crawlDoneRE    = regexp.MustCompile(`\A<- Done with (\S+)\z`)
)

// TableError is the loader's refusal.
type TableError struct{ msg string }

func (e *TableError) Error() string { return e.msg }

// SemanticRow is one row of docs/tour/semantics.tsv.
type SemanticRow struct {
	Path, Comparator, SourceSHA256, BurstVariation, VolatileElement string
	Params                                                          map[string]any
	ParamsOrder                                                     map[string][]string
}

// loadSemanticsTable binds each comparator to ONE pinned program. When
// `inventory` is supplied (path -> sha256) the digest is checked against it.
func loadSemanticsTable(path string, inventory map[string]string) (map[string]*SemanticRow, error) {
	table := map[string]*SemanticRow{}
	for _, row := range tsvRows(path) {
		source, comparator, sha, variation, element, params := field(row, 0), field(row, 1), field(row, 2), field(row, 3), field(row, 4), field(row, 5)
		if !containsString(comparators, comparator) {
			return nil, &TableError{fmt.Sprintf("semantics: unknown comparator %s", inspectString(comparator))}
		}
		if !containsString(burstVariation, variation) {
			return nil, &TableError{fmt.Sprintf("semantics: bad burst_variation %s", inspectString(variation))}
		}
		if _, dup := table[source]; dup {
			return nil, &TableError{fmt.Sprintf("semantics: duplicate row %s", source)}
		}
		if len(sha) != 64 {
			return nil, &TableError{fmt.Sprintf("semantics: %s has no source digest", source)}
		}
		if inventory != nil {
			expected, ok := inventory[source]
			if !ok {
				return nil, &TableError{fmt.Sprintf("semantics: %s is not an executable inventory row", source)}
			}
			if expected != sha {
				return nil, &TableError{fmt.Sprintf("semantics: %s digest does not match the inventory", source)}
			}
		}
		decoded, orders, err := parseJSONOrdered([]byte(params))
		if err != nil {
			return nil, &TableError{fmt.Sprintf("semantics: %s params are not JSON: %v", source, err)}
		}
		pm, _ := decoded.(map[string]any)
		table[source] = &SemanticRow{Path: source, Comparator: comparator, SourceSHA256: sha,
			BurstVariation: variation, VolatileElement: element, Params: pm, ParamsOrder: orders}
	}
	return table, nil
}

// Observation is one decoded stream set: exit (int64 or nil), stdout, stderr.
type Observation struct {
	Exit           any
	Stdout, Stderr string
}

// Facts are the comparator-specific facts plus findings for one stdout.
type Facts map[string]any

func factFindings(f Facts) []string {
	return f["findings"].([]string)
}

func addFinding(f Facts, s string) {
	f["findings"] = append(f["findings"].([]string), s)
}

// compareSemantic runs one comparator: status/stderr exactness, invariants on
// every oracle observation and the candidate, cross-observation
// reconciliation, and the burst-variation check.
func compareSemantic(row *SemanticRow, candidate Observation, oracle []Observation, window map[string]any, version string) map[string]any {
	if version != semanticsVersion && version != semanticsLegacyVersion {
		panic(fmt.Sprintf("unsupported semantic contract %s", inspectString(version)))
	}
	comparator := row.Comparator
	params := withOrder(row)
	// v1 had only the upper source bound in facts_say_interleaving; its lower
	// bound came entirely from reconcile_say_interleaving_v1's oracle sample.
	factParams := params
	if version == semanticsLegacyVersion && comparator == "say_interleaving" {
		factParams = map[string]any{}
		for k, v := range params {
			factParams[k] = v
		}
		factParams["goroutine_min"] = int64(0)
	}
	findings := []string{}
	if len(oracle) < minOracleRuns {
		findings = append(findings, fmt.Sprintf("oracle:insufficient_runs:%d<%d", len(oracle), minOracleRuns))
	}

	// 1. status and stderr are never adjudicated semantically.
	exits := []any{}
	seenExit := map[string]bool{}
	for _, o := range oracle {
		key := canonical(o.Exit)
		if !seenExit[key] {
			seenExit[key] = true
			exits = append(exits, o.Exit)
		}
	}
	if len(exits) != 1 {
		findings = append(findings, "oracle:unstable_exit:"+inspect(exits))
	}
	if !(len(exits) == 1 && jsonEqual(candidate.Exit, exits[0])) {
		var first any
		if len(exits) > 0 {
			first = exits[0]
		}
		findings = append(findings, fmt.Sprintf("status:exit_mismatch:%s!=%s", inspect(candidate.Exit), inspect(first)))
	}
	stderrs := []string{}
	for _, o := range oracle {
		stderrs = append(stderrs, o.Stderr)
	}
	stderrs = uniqStrings(stderrs)
	if len(stderrs) != 1 {
		findings = append(findings, "oracle:unstable_stderr")
	}
	if !(len(stderrs) == 1 && candidate.Stderr == stderrs[0]) {
		findings = append(findings, "stderr:mismatch")
	}

	// 2. the comparator must describe every oracle observation.
	oracleFacts := make([]Facts, len(oracle))
	oracleClean := true
	for i, o := range oracle {
		facts := semanticFacts(comparator, o.Stdout, factParams)
		for _, f := range factFindings(facts) {
			findings = append(findings, fmt.Sprintf("oracle:invariant_violation:%d:%s", i, f))
			oracleClean = false
		}
		oracleFacts[i] = facts
	}

	// 3. the candidate's own invariants.
	candidateFacts := semanticFacts(comparator, candidate.Stdout, factParams)
	for _, f := range factFindings(candidateFacts) {
		findings = append(findings, "stdout:"+f)
	}

	// 4. cross-observation reconciliation.
	if len(factFindings(candidateFacts)) == 0 && oracleClean {
		findings = append(findings, reconcile(comparator, candidateFacts, oracleFacts, params, window, version)...)
	}

	// 5. a comparator is only warranted where nondeterminism is real.
	stdouts := []string{}
	for _, o := range oracle {
		stdouts = append(stdouts, o.Stdout)
	}
	distinct := len(uniqStrings(stdouts))
	variation := row.BurstVariation
	if version == semanticsLegacyVersion && comparator == "say_interleaving" {
		variation = "required"
	}
	if variation == "required" && distinct < 2 && len(oracle) >= minOracleRuns {
		findings = append(findings, fmt.Sprintf("oracle:no_variation_observed:%d", distinct))
	}

	sort.Strings(findings)
	oracleSummaries := make([]any, len(oracleFacts))
	for i, f := range oracleFacts {
		oracleSummaries[i] = summarize(f)
	}
	return map[string]any{"comparator": comparator, "version": version, "ok": len(findings) == 0,
		"findings": anyList(findings),
		"evidence": map[string]any{"oracle_runs": int64(len(oracle)), "oracle_distinct_stdout": int64(distinct),
			"candidate": summarize(candidateFacts), "oracle": oracleSummaries}}
}

func summarize(f Facts) map[string]any {
	out := map[string]any{}
	for k, v := range f {
		if k != "findings" {
			out[k] = v
		}
	}
	return out
}

// -------------------------------------------------------------- utilities

func splitLines(text string, f Facts) []string {
	if text == "" {
		return []string{}
	}
	if !strings.HasSuffix(text, "\n") {
		addFinding(f, "unterminated_output")
		return strings.Split(text, "\n")
	}
	return strings.Split(text[:len(text)-1], "\n")
}

func durationMS(token string) (float64, bool) {
	m := durationRE.FindStringSubmatch(token)
	if m == nil {
		return 0, false
	}
	scale := map[string]float64{"ns": 1e-6, "us": 1e-3, "µs": 1e-3, "ms": 1.0, "s": 1000.0, "m": 60000.0}
	value, _ := strconv.ParseFloat(m[1], 64)
	return value * scale[m[2]], true
}

type goTime struct {
	epoch     float64
	zone      string
	monotonic *float64
}

// parseGoTime parses the wall-clock half of a Go time.Time rendering into an
// epoch and returns it with the monotonic reading, or nil when the layout is
// wrong.
func parseGoTime(token string) *goTime {
	m := goTimeRE.FindStringSubmatch(token)
	if m == nil {
		return nil
	}
	wall, err := time.Parse("2006-01-02 15:04:05 -0700", m[1])
	if err != nil {
		return nil
	}
	out := &goTime{epoch: float64(wall.UnixNano()) / 1e9, zone: m[2]}
	if m[3] != "" {
		mono, _ := strconv.ParseFloat(m[3], 64)
		out.monotonic = &mono
	}
	return out
}

func clockFindings(stamp string, window map[string]any, label string) []string {
	findings := []string{}
	parsed := parseGoTime(stamp)
	if parsed == nil {
		return []string{fmt.Sprintf("%s:not_a_go_timestamp:%s", label, inspectString(stamp))}
	}
	if parsed.monotonic == nil {
		findings = append(findings, label+":no_monotonic_reading")
	}
	if parsed.monotonic != nil && absFloat(*parsed.monotonic) > maxMonotonicSeconds {
		findings = append(findings, fmt.Sprintf("%s:monotonic_out_of_range:%s", label, rubyFloat(*parsed.monotonic)))
	}
	from := asFloat(window["from"]) - clockSlackSeconds
	to := asFloat(window["to"]) + clockSlackSeconds
	if !(parsed.epoch >= from && parsed.epoch <= to) {
		findings = append(findings, fmt.Sprintf("%s:outside_run_window:%s", label, rubyFloat(parsed.epoch)))
	}
	return findings
}

func absFloat(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

// windowTimes: the window endpoints as local times in the recorded offset.
func windowTimes(window map[string]any) []time.Time {
	out := []time.Time{}
	for _, key := range []string{"from", "to"} {
		epoch := asFloat(window[key])
		sec := int64(epoch)
		nsec := int64((epoch - float64(sec)) * 1e9)
		t := time.Unix(sec, nsec)
		if window["utc_offset"] != nil {
			t = t.In(time.FixedZone("", int(toI(window["utc_offset"]))))
		} else {
			t = t.Local()
		}
		out = append(out, t)
	}
	return out
}

func rangeFindingInt(label string, value int64, values []int64) []string {
	if len(values) == 0 {
		return []string{}
	}
	low, high := values[0], values[0]
	for _, v := range values {
		if v < low {
			low = v
		}
		if v > high {
			high = v
		}
	}
	if value >= low && value <= high {
		return []string{}
	}
	return []string{fmt.Sprintf("%s:%d_outside_native_range_%d..%d", label, value, low, high)}
}

func intsOf(facts []Facts, key string) []int64 {
	out := []int64{}
	for _, f := range facts {
		out = append(out, toI(f[key]))
	}
	return out
}

// ------------------------------------------------------------ invariants

func semanticFacts(comparator, text string, params map[string]any) Facts {
	result := Facts{"findings": []string{}}
	lines := splitLines(text, result)
	switch comparator {
	case "rand_intn_line":
		factsRandIntnLine(lines, params, result)
	case "say_interleaving":
		factsSayInterleaving(lines, params, result)
	case "channel_sum_order":
		factsChannelSumOrder(lines, params, result)
	case "tick_boom_sequence":
		factsTickBoomSequence(lines, params, result)
	case "weekday_switch":
		factsWeekdaySwitch(lines, params, result)
	case "hour_greeting":
		factsHourGreeting(lines, params, result)
	case "go_time_error_line":
		factsGoTimeErrorLine(lines, params, result)
	case "sandbox_time":
		factsSandboxTime(lines, params, result)
	case "line_set":
		factsLineSet(lines, params, result)
	case "webcrawler_crawl":
		factsWebcrawlerCrawl(lines, params, result)
	default:
		panic("unknown comparator " + comparator)
	}
	return result
}

func reconcile(comparator string, candidate Facts, oracle []Facts, params map[string]any, window map[string]any, version string) []string {
	if version == semanticsLegacyVersion && comparator == "say_interleaving" {
		return rangeFindingInt("goroutine_multiplicity", toI(candidate["goroutine_count"]), intsOf(oracle, "goroutine_count"))
	}
	switch comparator {
	case "tick_boom_sequence":
		findings := rangeFindingInt("tick_count", toI(candidate["tick_count"]), intsOf(oracle, "tick_count"))
		findings = append(findings, rangeFindingInt("default_count", toI(candidate["default_count"]), intsOf(oracle, "default_count"))...)
		ceiling := 0.0
		for i, o := range oracle {
			v := asFloat(o["boom_ms"])
			if i == 0 || v > ceiling {
				ceiling = v
			}
		}
		ceiling += asFloat(params["boom_slack_ms"])
		if asFloat(candidate["boom_ms"]) > ceiling {
			findings = append(findings, fmt.Sprintf("boom_late:%s>%s", toS(candidate["boom_ms"]), rubyFloat(ceiling)))
		}
		return findings
	case "weekday_switch":
		findings := []string{}
		answers := uniqStrings(stringsOf(oracle, "answer"))
		if len(answers) != 1 {
			findings = append(findings, "oracle:disagreement:"+inspect(answers))
		}
		if !(len(answers) == 1 && answers[0] == asString(candidate["answer"])) {
			findings = append(findings, "answer_disagrees_with_oracle:"+inspectString(asString(candidate["answer"])))
		}
		expected := []string{}
		for _, t := range windowTimes(window) {
			answer := map[time.Weekday]string{time.Saturday: "Today.", time.Friday: "Tomorrow.", time.Thursday: "In two days."}[t.Weekday()]
			if answer == "" {
				answer = "Too far away."
			}
			expected = append(expected, answer)
		}
		expected = uniqStrings(expected)
		if !containsString(expected, asString(candidate["answer"])) {
			findings = append(findings, fmt.Sprintf("answer_disagrees_with_run_clock:%s!=%s", inspectString(asString(candidate["answer"])), inspect(expected)))
		}
		return findings
	case "hour_greeting":
		findings := []string{}
		greetings := uniqStrings(stringsOf(oracle, "greeting"))
		if len(greetings) != 1 {
			findings = append(findings, "oracle:disagreement:"+inspect(greetings))
		}
		if !(len(greetings) == 1 && greetings[0] == asString(candidate["greeting"])) {
			findings = append(findings, "greeting_disagrees_with_oracle:"+inspectString(asString(candidate["greeting"])))
		}
		values := strList(params["values"])
		expected := []string{}
		for _, t := range windowTimes(window) {
			hour := int64(t.Hour())
			switch {
			case hour < toI(params["morning_before"]):
				expected = append(expected, values[0])
			case hour < toI(params["afternoon_before"]):
				expected = append(expected, values[1])
			default:
				expected = append(expected, values[2])
			}
		}
		expected = uniqStrings(expected)
		if !containsString(expected, asString(candidate["greeting"])) {
			findings = append(findings, fmt.Sprintf("greeting_disagrees_with_run_clock:%s!=%s", inspectString(asString(candidate["greeting"])), inspect(expected)))
		}
		return findings
	case "go_time_error_line", "sandbox_time":
		return clockFindings(asString(candidate["timestamp"]), window, "timestamp")
	case "webcrawler_crawl":
		findings := rangeFindingInt("already_fetched", toI(candidate["already_fetched"]), intsOf(oracle, "already_fetched"))
		findings = append(findings, rangeFindingInt("depth_exhausted", toI(candidate["depth_exhausted"]), intsOf(oracle, "depth_exhausted"))...)
		findings = append(findings, rangeFindingInt("edges", toI(candidate["edges"]), intsOf(oracle, "edges"))...)
		return findings
	default:
		// rand_intn_line, say_interleaving, channel_sum_order, line_set: the
		// declared support (or the facts themselves) is the whole contract.
		return []string{}
	}
}

func stringsOf(facts []Facts, key string) []string {
	out := []string{}
	for _, f := range facts {
		out = append(out, asString(f[key]))
	}
	return out
}

// -- basics/packages.go: `fmt.Println("My favorite number is", rand.Intn(10))`
func factsRandIntnLine(lines []string, params map[string]any, result Facts) {
	prefix := asString(params["prefix"])
	if len(lines) != 1 {
		addFinding(result, fmt.Sprintf("line_count:%d!=1", len(lines)))
		return
	}
	re := regexp.MustCompile(`\A` + regexp.QuoteMeta(prefix) + `(0|[1-9]\d*)\z`)
	m := re.FindStringSubmatch(lines[0])
	if m == nil {
		addFinding(result, "shape:"+inspectString(lines[0]))
		return
	}
	value, _ := strconv.ParseInt(m[1], 10, 64)
	result["value"] = value
	bound := toI(params["modulus"])
	if !(value >= 0 && value < bound) {
		addFinding(result, fmt.Sprintf("value_outside_support:%d_not_in_0...%d", value, bound))
	}
}

// -- concurrency/goroutines.go: `go say("world"); say("hello")`
func factsSayInterleaving(lines []string, params map[string]any, result Facts) {
	values := strList(params["values"])
	counts := map[string]int64{}
	order := []string{}
	for _, line := range lines {
		if _, seen := counts[line]; !seen {
			order = append(order, line)
		}
		counts[line]++
	}
	unknown := []string{}
	for _, line := range order {
		if !containsString(values, line) {
			unknown = append(unknown, line)
		}
	}
	if len(unknown) > 0 {
		addFinding(result, "unknown_line:"+inspect(sortedCopy(unknown)))
	}
	countMap := map[string]any{}
	for _, value := range values {
		countMap[value] = counts[value]
	}
	result["counts"] = countMap
	main, expected := asString(params["main"]), toI(params["main_count"])
	if counts[main] != expected {
		addFinding(result, fmt.Sprintf("main_multiplicity:%d!=%d", counts[main], expected))
	}
	goroutine := counts[asString(params["goroutine"])]
	minimum := toI(params["goroutine_min"])
	result["goroutine_count"] = goroutine
	if !(goroutine >= minimum && goroutine <= expected) {
		addFinding(result, fmt.Sprintf("goroutine_multiplicity_outside_bound:%d_not_in_%d..%d", goroutine, minimum, expected))
	}
}

// -- concurrency/channels.go: two independent sums on ONE unbuffered channel.
func factsChannelSumOrder(lines []string, params map[string]any, result Facts) {
	halves := []int64{}
	for _, h := range asList(params["halves"]) {
		halves = append(halves, toI(h))
	}
	if len(lines) != 1 {
		addFinding(result, fmt.Sprintf("line_count:%d!=1", len(lines)))
		return
	}
	tokens := strings.Fields(lines[0])
	ok := len(tokens) == 3
	for _, t := range tokens {
		if !intRE.MatchString(t) {
			ok = false
		}
	}
	if !ok {
		addFinding(result, "shape:"+inspectString(lines[0]))
		return
	}
	values := make([]int64, 3)
	for i, t := range tokens {
		values[i], _ = strconv.ParseInt(t, 10, 64)
	}
	result["values"] = []any{values[0], values[1], values[2]}
	if values[0]+values[1] != values[2] {
		addFinding(result, fmt.Sprintf("sum:%d+%d!=%d", values[0], values[1], values[2]))
	}
	if values[2] != toI(params["sum"]) {
		addFinding(result, fmt.Sprintf("sum:%d!=%d", values[2], toI(params["sum"])))
	}
	got := []int64{values[0], values[1]}
	sort.Slice(got, func(i, j int) bool { return got[i] < got[j] })
	want := append([]int64{}, halves...)
	sort.Slice(want, func(i, j int) bool { return want[i] < want[j] })
	if !(len(got) == len(want) && got[0] == want[0] && got[1] == want[1]) {
		addFinding(result, fmt.Sprintf("halves:%s!=%s", inspectInts(got), inspectInts(want)))
	}
	result["output"] = lines[0]
	if !containsString(strList(params["outputs"]), lines[0]) {
		addFinding(result, "output_not_in_declared_set:"+inspectString(lines[0]))
	}
}

func inspectInts(v []int64) string {
	parts := make([]string, len(v))
	for i, n := range v {
		parts[i] = strconv.FormatInt(n, 10)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// -- concurrency/default-selection.go: a 100ms tick, a 500ms boom, a default
//
//	branch that sleeps 50ms, all stamped with the rounded elapsed time.
type tickEvent struct {
	ms   float64
	kind string
}

func factsTickBoomSequence(lines []string, params map[string]any, result Facts) {
	if len(lines) == 0 {
		addFinding(result, "no_output")
		return
	}
	events := []tickEvent{}
	for i, line := range lines {
		m := tickLineRE.FindStringSubmatch(line)
		if m == nil {
			addFinding(result, fmt.Sprintf("unparsed_line:%d:%s", i, inspectString(line)))
			continue
		}
		ms, ok := durationMS(m[1])
		if !ok {
			addFinding(result, fmt.Sprintf("unparsed_elapsed:%d:%s", i, inspectString(m[1])))
			continue
		}
		events = append(events, tickEvent{ms, map[string]string{"tick.": "tick", "BOOM!": "boom", ".": "default"}[m[2]]})
	}
	if len(factFindings(result)) > 0 {
		return
	}
	var ticks, defaults, booms int64
	for _, e := range events {
		switch e.kind {
		case "tick":
			ticks++
		case "default":
			defaults++
		case "boom":
			booms++
		}
	}
	result["tick_count"] = ticks
	result["default_count"] = defaults
	if booms != 1 {
		addFinding(result, fmt.Sprintf("boom_multiplicity:%d!=1", booms))
	}
	if events[len(events)-1].kind != "boom" {
		addFinding(result, "boom_not_final")
	}
	if defaults == 0 {
		addFinding(result, "no_default_selection")
	}
	for i := 0; i+1 < len(events); i++ {
		if events[i].ms > events[i+1].ms {
			addFinding(result, fmt.Sprintf("elapsed_not_monotonic:%d:%s>%s", i, rubyFloat(events[i].ms), rubyFloat(events[i+1].ms)))
		}
	}
	for i := 0; i+1 < len(events); i++ {
		if events[i].kind != "default" {
			continue
		}
		floor := toI(params["default_sleep_ms"]) - toI(params["rounding_slack_ms"])
		gap := events[i+1].ms - events[i].ms
		if gap < float64(floor) {
			addFinding(result, fmt.Sprintf("default_sleep_missing:%d:%s<%d", i, rubyFloat(gap), floor))
		}
	}
	tickIndex := 0
	for _, e := range events {
		if e.kind != "tick" {
			continue
		}
		floor := toI(params["tick_ms"]) * int64(tickIndex+1)
		if e.ms < float64(floor) {
			addFinding(result, fmt.Sprintf("tick_early:%d:%s<%d", tickIndex, rubyFloat(e.ms), floor))
		}
		tickIndex++
	}
	for _, e := range events {
		if e.kind == "boom" {
			result["boom_ms"] = e.ms
			if e.ms < float64(toI(params["boom_ms"])) {
				addFinding(result, fmt.Sprintf("boom_early:%s<%d", rubyFloat(e.ms), toI(params["boom_ms"])))
			}
			break
		}
	}
	result["line_count"] = int64(len(lines))
}

// -- flowcontrol/switch-evaluation-order.go: prints the distance to Saturday.
func factsWeekdaySwitch(lines []string, params map[string]any, result Facts) {
	prompt, values := asString(params["prompt"]), strList(params["values"])
	if len(lines) != 2 {
		addFinding(result, fmt.Sprintf("line_count:%d!=2", len(lines)))
		return
	}
	if lines[0] != prompt {
		addFinding(result, "prompt:"+inspectString(lines[0]))
	}
	result["answer"] = lines[1]
	if !containsString(values, lines[1]) {
		addFinding(result, "answer_outside_value_set:"+inspectString(lines[1]))
	}
}

// -- flowcontrol/switch-with-no-condition.go: the hour-of-day greeting.
func factsHourGreeting(lines []string, params map[string]any, result Facts) {
	values := strList(params["values"])
	if len(lines) != 1 {
		addFinding(result, fmt.Sprintf("line_count:%d!=1", len(lines)))
		return
	}
	result["greeting"] = lines[0]
	if !containsString(values, lines[0]) {
		addFinding(result, "greeting_outside_value_set:"+inspectString(lines[0]))
	}
}

// -- methods/errors.go: `at <time.Now()>, it didn't work`.
func factsGoTimeErrorLine(lines []string, params map[string]any, result Facts) {
	if len(lines) != 1 {
		addFinding(result, fmt.Sprintf("line_count:%d!=1", len(lines)))
		return
	}
	re := regexp.MustCompile(`\A` + regexp.QuoteMeta(asString(params["prefix"])) + `(.+)` + regexp.QuoteMeta(asString(params["suffix"])) + `\z`)
	m := re.FindStringSubmatch(lines[0])
	if m == nil {
		addFinding(result, "shape:"+inspectString(lines[0]))
		return
	}
	result["timestamp"] = m[1]
	if parseGoTime(m[1]) == nil {
		addFinding(result, "timestamp:not_a_go_timestamp:"+inspectString(m[1]))
	}
}

// -- welcome/sandbox.go: a fixed greeting plus `The time is <time.Now()>`.
func factsSandboxTime(lines []string, params map[string]any, result Facts) {
	if len(lines) != 2 {
		addFinding(result, fmt.Sprintf("line_count:%d!=2", len(lines)))
		return
	}
	if lines[0] != asString(params["greeting"]) {
		addFinding(result, "greeting:"+inspectString(lines[0]))
	}
	prefix := asString(params["prefix"])
	if !strings.HasPrefix(lines[1], prefix) {
		addFinding(result, "shape:"+inspectString(lines[1]))
		return
	}
	stamp := strings.TrimPrefix(lines[1], prefix)
	result["timestamp"] = stamp
	if parseGoTime(stamp) == nil {
		addFinding(result, "timestamp:not_a_go_timestamp:"+inspectString(stamp))
	}
}

// -- methods/exercise-stringer.go and solutions/stringers.go: a range over a
//
//	two-entry map, whose iteration order Go randomizes per process.
func factsLineSet(lines []string, params map[string]any, result Facts) {
	expected := strList(params["lines"])
	counts := map[string]int64{}
	for _, line := range lines {
		counts[line]++
	}
	result["line_count"] = int64(len(lines))
	if len(lines) != len(expected) {
		addFinding(result, fmt.Sprintf("line_count:%d!=%d", len(lines), len(expected)))
	}
	duplicated := []string{}
	for line, n := range counts {
		if n > 1 {
			duplicated = append(duplicated, line)
		}
	}
	sort.Strings(duplicated)
	if len(duplicated) > 0 {
		addFinding(result, "duplicate_lines:"+inspect(duplicated))
	}
	missing := subtract(expected, lines)
	extra := subtract(lines, expected)
	if len(missing) > 0 {
		addFinding(result, "missing_lines:"+inspect(missing))
	}
	if len(extra) > 0 {
		addFinding(result, "unexpected_lines:"+inspect(extra))
	}
	result["order"] = anyList(lines)
}

// -- solutions/webcrawler.go: a concurrent crawl of a canned fetcher.
type crawlKey [4]string

func (k crawlKey) inspect() string {
	return inspect([]string{k[0], k[1], k[2], k[3]})
}

func factsWebcrawlerCrawl(lines []string, params map[string]any, result Facts) {
	bodies := asMap(params["bodies"])
	bodyURLs := jsonObjectKeyOrder(params, "bodies")
	missingURLs := strList(params["missing"])
	known := append(append([]string{}, bodyURLs...), missingURLs...)
	links := asMap(params["links"])
	expectedEdges := []crawlKey{}
	for _, parent := range jsonObjectKeyOrder(params, "links") {
		targets := strList(links[parent])
		for i, child := range targets {
			expectedEdges = append(expectedEdges, crawlKey{parent, strconv.Itoa(i), strconv.Itoa(len(targets)), child})
		}
	}
	alreadyURLs := map[string]int64{}
	foundAt, doneAt, waitAt := map[string]int{}, map[string]int{}, map[crawlKey]int{}
	header := strList(params["stats_header"])
	index := []int{}
	for i, line := range lines {
		if line == header[0] {
			index = append(index, i)
		}
	}
	if !(len(index) == 1 && index[0]+1 < len(lines) && lines[index[0]+1] == header[1]) {
		addFinding(result, fmt.Sprintf("stats_header:%d", len(index)))
		return
	}
	crawl := lines[:index[0]]
	stats := []string{}
	if index[0]+2 <= len(lines) {
		stats = lines[index[0]+2:]
	}

	// -- the statistics block is fully determined: exact set, no repeats.
	expectedStats := []string{}
	for _, url := range bodyURLs {
		expectedStats = append(expectedStats, url+" was fetched")
	}
	for _, url := range missingURLs {
		expectedStats = append(expectedStats, fmt.Sprintf("%s failed: not found: %s", url, url))
	}
	statsCounts := map[string]int64{}
	for _, line := range stats {
		statsCounts[line]++
	}
	duplicated := []string{}
	for line, n := range statsCounts {
		if n > 1 {
			duplicated = append(duplicated, line)
		}
	}
	sort.Strings(duplicated)
	if len(duplicated) > 0 {
		addFinding(result, "stats_duplicate:"+inspect(duplicated))
	}
	if missingStats := subtract(expectedStats, stats); len(missingStats) > 0 {
		addFinding(result, "stats_missing:"+inspect(missingStats))
	}
	if extraStats := subtract(stats, expectedStats); len(extraStats) > 0 {
		addFinding(result, "stats_unexpected:"+inspect(extraStats))
	}

	found, done, errorsSeen := map[string]int64{}, map[string]int64{}, map[string]int64{}
	var already, depth0 int64
	children, waits := map[crawlKey]int64{}, map[crawlKey]int64{}
	childOrder := []crawlKey{}
	childAt := map[crawlKey]int{}
	for i, line := range crawl {
		if m := crawlFoundRE.FindStringSubmatch(line); m != nil {
			url, body := m[1], m[2]
			found[url]++
			if _, seen := foundAt[url]; !seen {
				foundAt[url] = i
			}
			if !containsString(known, url) {
				addFinding(result, "unknown_url:"+url)
			}
			if b, ok := bodies[url]; !ok || asString(b) != body {
				addFinding(result, fmt.Sprintf("found_body:%s:%s", url, inspectString(body)))
			}
		} else if m := crawlChildRE.FindStringSubmatch(line); m != nil {
			key := crawlKey{m[3], m[1], m[2], m[4]}
			if _, seen := children[key]; !seen {
				childOrder = append(childOrder, key)
			}
			children[key]++
			if _, seen := childAt[key]; !seen {
				childAt[key] = i
			}
			if !containsString(known, key[3]) {
				addFinding(result, "unknown_url:"+key[3])
			}
		} else if m := crawlWaitRE.FindStringSubmatch(line); m != nil {
			key := crawlKey{m[1], m[2], m[3], m[4]}
			waits[key]++
			if _, seen := waitAt[key]; !seen {
				waitAt[key] = i
			}
			at, ok := childAt[key]
			if !ok || at > i {
				addFinding(result, "causal_order:wait_before_crawl:"+key.inspect())
			}
		} else if m := crawlAlreadyRE.FindStringSubmatch(line); m != nil {
			url := m[1]
			already++
			alreadyURLs[url]++
			if !containsString(known, url) {
				addFinding(result, "unknown_url:"+url)
			}
		} else if crawlDepth0RE.MatchString(line) {
			depth0++
			addFinding(result, "unexpected_depth_zero") // This pinned graph first visits every body at depth >= 2.
		} else if m := crawlErrorRE.FindStringSubmatch(line); m != nil {
			url, message := m[1], m[2]
			errorsSeen[url]++
			if !containsString(missingURLs, url) {
				addFinding(result, "unexpected_error_url:"+url)
			}
			if message != "not found: "+url {
				addFinding(result, fmt.Sprintf("error_message:%s:%s", url, inspectString(message)))
			}
		} else if m := crawlDoneRE.FindStringSubmatch(line); m != nil {
			url := m[1]
			done[url]++
			if _, seen := doneAt[url]; !seen {
				doneAt[url] = i
			}
			if _, ok := bodies[url]; !ok {
				addFinding(result, "unknown_done_url:"+url)
			}
		} else {
			addFinding(result, fmt.Sprintf("unparsed_line:%d:%s", i, inspectString(line)))
		}
	}

	for _, url := range bodyURLs {
		if found[url] != 1 {
			addFinding(result, fmt.Sprintf("found_multiplicity:%s:%d!=1", url, found[url]))
		}
		if done[url] != 1 {
			addFinding(result, fmt.Sprintf("done_multiplicity:%s:%d!=1", url, done[url]))
		}
	}
	for _, url := range missingURLs {
		if errorsSeen[url] != 1 {
			addFinding(result, fmt.Sprintf("error_multiplicity:%s:%d!=1", url, errorsSeen[url]))
		}
		if found[url] > 0 {
			addFinding(result, "found_unfetchable:"+url)
		}
	}
	union := []crawlKey{}
	seen := map[crawlKey]bool{}
	for _, k := range childOrder {
		if !seen[k] {
			seen[k] = true
			union = append(union, k)
		}
	}
	for _, k := range sortedCrawlKeys(waits) {
		if !seen[k] {
			seen[k] = true
			union = append(union, k)
		}
	}
	unpaired := []crawlKey{}
	for _, k := range union {
		if !(children[k] == 1 && waits[k] == 1) {
			unpaired = append(unpaired, k)
		}
	}
	if len(unpaired) > 0 {
		addFinding(result, "child_wait_pairing:"+inspectCrawlKeys(sortCrawlKeys(unpaired)))
	}
	if !equalCrawlKeys(sortCrawlKeys(childOrder), sortCrawlKeys(expectedEdges)) {
		addFinding(result, "crawl_topology")
	}
	for _, key := range expectedEdges {
		parent := key[0]
		if at, ok := childAt[key]; ok {
			if fa, ok := foundAt[parent]; !ok || at < fa {
				addFinding(result, "causal_order:crawl_before_parent_found:"+key.inspect())
			}
		}
		if at, ok := waitAt[key]; ok {
			if da, ok := doneAt[parent]; !ok || at > da {
				addFinding(result, "causal_order:parent_done_before_wait:"+key.inspect())
			}
		}
	}
	for _, url := range known {
		visits := int64(0)
		for _, edge := range expectedEdges {
			if edge[3] == url {
				visits++
			}
		}
		if url == asString(params["root"]) {
			visits++
		}
		if alreadyURLs[url] != visits-1 {
			addFinding(result, "already_multiplicity:"+url)
		}
	}
	var edges int64
	for _, n := range children {
		edges += n
	}
	result["already_fetched"] = already
	result["depth_exhausted"] = depth0
	result["edges"] = edges
	result["crawl_lines"] = int64(len(crawl))
}

func sortCrawlKeys(keys []crawlKey) []crawlKey {
	out := append([]crawlKey{}, keys...)
	sort.Slice(out, func(i, j int) bool {
		for k := 0; k < 4; k++ {
			if out[i][k] != out[j][k] {
				return out[i][k] < out[j][k]
			}
		}
		return false
	})
	return out
}

func sortedCrawlKeys(m map[crawlKey]int64) []crawlKey {
	keys := []crawlKey{}
	for k := range m {
		keys = append(keys, k)
	}
	return sortCrawlKeys(keys)
}

func equalCrawlKeys(a, b []crawlKey) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func inspectCrawlKeys(keys []crawlKey) string {
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k.inspect()
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// paramsOrderKey carries the declared key order of nested param objects
// through the generic params map, so renderings follow the table's own order
// exactly as Ruby's insertion-ordered hashes did.
const paramsOrderKey = "__key_order__"

func withOrder(row *SemanticRow) map[string]any {
	out := map[string]any{}
	for k, v := range row.Params {
		out[k] = v
	}
	out[paramsOrderKey] = row.ParamsOrder
	return out
}

func jsonObjectKeyOrder(params map[string]any, name string) []string {
	if orders, ok := params[paramsOrderKey].(map[string][]string); ok {
		if keys, ok := orders[name]; ok {
			return keys
		}
	}
	return sortedKeys(asMap(params[name]))
}
