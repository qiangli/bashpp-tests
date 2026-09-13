// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Negative-first selftests for the reviewed semantic comparators — the port of
// tools/tour/semantics-selftests.rb. Every comparator is driven with a
// real-shaped accepted case, wrong VALUES, wrong COUNTS, wrong ORDER, wrong
// STATUS, wrong TIMING, a degenerate ORACLE and ANOTHER ROW'S output, and the
// table bindings are tested too.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type selftestSuite struct {
	passed []string
	failed []string
}

func (s *selftestSuite) check(name string, fn func() any) {
	defer func() {
		if r := recover(); r != nil {
			s.failed = append(s.failed, fmt.Sprintf("%s: raised %v", name, r))
		}
	}()
	result := fn()
	if b, ok := result.(bool); ok && b {
		s.passed = append(s.passed, name)
	} else {
		s.failed = append(s.failed, fmt.Sprintf("%s: %v", name, result))
	}
}

func expect(condition bool, message string) any {
	if condition {
		return true
	}
	return message
}

func cmdSemanticsSelftests(root string) int {
	suite := &selftestSuite{}
	table, err := loadSemanticsTable(filepath.Join(root, "docs/tour/semantics.tsv"), nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		return 1
	}

	// A fixed window: Tuesday 2026-09-08, 21:19 local. Tuesday is neither
	// Saturday nor the day before nor two days before, and 21:19 is after
	// 17:00, so the clock-derived expectations are "Too far away." and
	// "Good evening.".
	windowFrom := time.Date(2026, 9, 8, 21, 19, 0, 0, time.Local)
	_, windowOffset := windowFrom.Zone()
	window := map[string]any{"from": float64(windowFrom.Unix()), "to": float64(windowFrom.Unix()) + 12.0, "utc_offset": int64(windowOffset)}

	goStamp := func(offsetSeconds float64, monotonic string) string {
		t := time.Unix(0, int64((asFloat(window["from"])+offsetSeconds)*1e9)).In(time.Local)
		stamp := t.Format("2006-01-02 15:04:05.000000 -0700 MST")
		if monotonic != "" {
			return stamp + " m=+" + monotonic
		}
		return stamp
	}
	obs := func(stdout string) Observation { return Observation{Exit: int64(0), Stdout: stdout, Stderr: ""} }
	withExit := func(o Observation, exit int64) Observation { o.Exit = exit; return o }
	withStderr := func(o Observation, stderr string) Observation { o.Stderr = stderr; return o }
	findings := func(path string, candidate Observation, oracle []Observation, w map[string]any) []string {
		row, ok := table[path]
		if !ok {
			panic("no table row for " + path)
		}
		return strList(compareSemantic(row, candidate, oracle, w, semanticsVersion)["findings"])
	}
	accepts := func(name, path string, candidate Observation, oracle []Observation) {
		suite.check(name, func() any {
			got := findings(path, candidate, oracle, window)
			return expect(len(got) == 0, "expected acceptance, got "+inspect(got))
		})
	}
	rejects := func(name, path string, candidate Observation, oracle []Observation, token string) {
		suite.check(name, func() any {
			got := findings(path, candidate, oracle, window)
			if len(got) == 0 {
				return fmt.Sprintf("expected rejection (%s), got acceptance", token)
			}
			for _, f := range got {
				if strings.Contains(f, token) {
					return true
				}
			}
			return fmt.Sprintf("expected a finding containing %s, got %s", inspectString(token), inspect(got))
		})
	}
	repeat := func(n int, o Observation) []Observation {
		out := make([]Observation, n)
		for i := range out {
			out[i] = o
		}
		return out
	}

	// ============================================================ packages
	const PACKAGES = "_content/tour/basics/packages.go"
	packagesLine := func(value any) Observation { return obs(fmt.Sprintf("My favorite number is %v\n", value)) }
	packagesOracle := []Observation{}
	for _, v := range []int{2, 7, 0, 9, 4, 7, 1} {
		packagesOracle = append(packagesOracle, packagesLine(v))
	}
	accepts("rand_intn_line: a draw inside the declared support", PACKAGES, packagesLine(3), packagesOracle)
	accepts("rand_intn_line: a draw the oracle never produced is still in support", PACKAGES, packagesLine(5), packagesOracle)
	rejects("rand_intn_line: rejects a draw OUTSIDE rand.Intn(10) support", PACKAGES, packagesLine(10), packagesOracle, "value_outside_support")
	rejects("rand_intn_line: rejects a negative draw", PACKAGES, packagesLine(-1), packagesOracle, "shape")
	rejects("rand_intn_line: rejects a non-numeric value", PACKAGES, packagesLine("seven"), packagesOracle, "shape")
	rejects("rand_intn_line: rejects altered surrounding text", PACKAGES, obs("My lucky number is 3\n"), packagesOracle, "shape")
	rejects("rand_intn_line: rejects an extra line", PACKAGES, obs("My favorite number is 3\nextra\n"), packagesOracle, "line_count")
	rejects("rand_intn_line: rejects empty output", PACKAGES, obs(""), packagesOracle, "line_count")
	rejects("rand_intn_line: STATUS is never semantic — a nonzero exit fails", PACKAGES, withExit(packagesLine(3), 1), packagesOracle, "status:exit_mismatch")
	rejects("rand_intn_line: STDERR is never semantic — unexpected stderr fails", PACKAGES, withStderr(packagesLine(3), "warning\n"), packagesOracle, "stderr:mismatch")
	rejects("rand_intn_line: a too-thin oracle cannot establish anything", PACKAGES, packagesLine(3), packagesOracle[:3], "oracle:insufficient_runs")
	rejects("rand_intn_line: an oracle with NO variation means the comparator is not needed", PACKAGES, packagesLine(3), repeat(7, packagesLine(3)), "oracle:no_variation_observed")
	rejects("rand_intn_line: an oracle observation outside support fails the comparator itself", PACKAGES, packagesLine(3), append(append([]Observation{}, packagesOracle[:6]...), packagesLine(11)), "oracle:invariant_violation")

	// ========================================================== goroutines
	const GOROUTINES = "_content/tour/concurrency/goroutines.go"
	say := func(words ...string) Observation {
		var b strings.Builder
		for _, w := range words {
			b.WriteString(w + "\n")
		}
		return obs(b.String())
	}
	times := func(word string, n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = word
		}
		return out
	}
	goroutinesOracle := []Observation{
		say("hello", "world", "world", "hello", "world", "hello", "hello", "world", "hello"),
		say("world", "hello", "world", "hello", "world", "hello", "world", "hello", "hello", "world"),
		say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello"),
		say("world", "hello", "hello", "world", "world", "hello", "world", "hello", "hello", "world"),
		say("hello", "hello", "world", "world", "hello", "world", "hello", "world", "hello"),
		say("hello", "world", "world", "hello", "hello", "world", "hello", "world", "hello", "world"),
		say("world", "world", "hello", "hello", "hello", "world", "world", "hello", "hello"),
	}
	rejects("say_interleaving: rejects missing hello even with a complete world call", GOROUTINES,
		say("hello", "hello", "hello", "hello", "world", "world", "world", "world", "world"), goroutinesOracle, "main_multiplicity")
	rejects("say_interleaving: rejects too MANY main lines", GOROUTINES,
		say(append(times("hello", 6), times("world", 4)...)...), goroutinesOracle, "main_multiplicity")
	rejects("say_interleaving: rejects a goroutine count above its own bound", GOROUTINES,
		say(append(times("hello", 5), times("world", 6)...)...), goroutinesOracle, "goroutine_multiplicity_outside_bound")
	rejects("say_interleaving: rejects an unknown line", GOROUTINES,
		say("hello", "world", "hola", "hello", "world", "hello", "world", "hello", "world", "hello"), goroutinesOracle, "unknown_line")
	rejects("say_interleaving: rejects joined events instead of treating them as ordered lines", GOROUTINES,
		obs("helloworld\nhello\nhello\nhello\nhello\n"), goroutinesOracle, "unknown_line")
	rejects("say_interleaving: rejects an unterminated final event", GOROUTINES,
		obs("hello\nworld\nhello\nworld\nhello\nworld\nhello\nhello"), goroutinesOracle, "unterminated_output")
	rejects("say_interleaving: rejects a wrong exit status", GOROUTINES,
		withExit(say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello"), 2), goroutinesOracle, "status:exit_mismatch")
	suite.check("say_interleaving v1: authenticates the historical sampled-range rejection", func() any {
		allFive := repeat(7, say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello", "world"))
		verdict := compareSemantic(table[GOROUTINES], say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello"), allFive, window, semanticsLegacyVersion)
		ok := !truthy(verdict["ok"])
		found := false
		for _, f := range strList(verdict["findings"]) {
			if strings.Contains(f, "outside_native_range_5..5") {
				found = true
			}
		}
		return expect(ok && found, canonical(verdict))
	})
	accepts("say_interleaving: any interleaving with the right source-derived prefixes", GOROUTINES,
		say("world", "hello", "world", "hello", "hello", "world", "hello", "world", "hello"), goroutinesOracle)
	accepts("say_interleaving: zero world lines are legal without a scheduler-progress guarantee", GOROUTINES,
		say("hello", "hello", "hello", "hello", "hello"), goroutinesOracle)
	accepts("say_interleaving: four world lines remain legal when a seven-run burst happens to show five", GOROUTINES,
		say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello"),
		repeat(7, say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello", "world")))

	// ============================================================== channels
	const CHANNELS = "_content/tour/concurrency/channels.go"
	channelsLine := func(order string) Observation { return obs(order + "\n") }
	minusFirst := channelsLine("-5 17 12")
	seventeenFirst := channelsLine("17 -5 12")
	channelsOracle := []Observation{minusFirst, minusFirst, minusFirst, seventeenFirst, minusFirst, minusFirst, minusFirst}
	accepts("channel_sum_order: accepts the dominant arrival order", CHANNELS, minusFirst, channelsOracle)
	accepts("channel_sum_order: accepts the OTHER legal arrival order", CHANNELS, seventeenFirst, channelsOracle)
	accepts("channel_sum_order: an order the oracle never drew is still legal (declared support)", CHANNELS, seventeenFirst, repeat(7, minusFirst))
	accepts("channel_sum_order: a one-order burst is LEGAL here — not_required, measured flip rate ~1/400", CHANNELS, minusFirst, repeat(7, minusFirst))
	rejects("channel_sum_order: rejects a WRONG SUM", CHANNELS, channelsLine("-5 17 13"), channelsOracle, "sum:")
	rejects("channel_sum_order: rejects values that are not the two computed halves", CHANNELS, channelsLine("-17 5 -12"), channelsOracle, "halves:")
	rejects("channel_sum_order: rejects wrong multiplicity — the line twice", CHANNELS, obs("17 -5 12\n17 -5 12\n"), channelsOracle, "line_count")
	rejects("channel_sum_order: rejects an extra trailing line", CHANNELS, obs("17 -5 12\nextra\n"), channelsOracle, "line_count")
	rejects("channel_sum_order: rejects empty output", CHANNELS, obs(""), channelsOracle, "line_count")
	rejects("channel_sum_order: rejects missing trailing bytes (unterminated line)", CHANNELS, obs("17 -5 12"), channelsOracle, "unterminated_output")
	rejects("channel_sum_order: rejects ADDITIONAL BYTES between the values", CHANNELS, channelsLine("-5  17 12"), channelsOracle, "output_not_in_declared_set")
	rejects("channel_sum_order: rejects a non-numeric rendering", CHANNELS, channelsLine("seventeen minus five twelve"), channelsOracle, "shape")
	rejects("channel_sum_order: STATUS is never semantic — a nonzero exit fails", CHANNELS, withExit(minusFirst, 2), channelsOracle, "status:exit_mismatch")
	rejects("channel_sum_order: STDERR is never semantic — unexpected stderr fails", CHANNELS, withStderr(minusFirst, "warning\n"), channelsOracle, "stderr:mismatch")
	rejects("channel_sum_order: a too-thin oracle cannot establish anything", CHANNELS, minusFirst, channelsOracle[:3], "oracle:insufficient_runs")
	rejects("channel_sum_order: an oracle observation with a wrong sum fails the comparator itself", CHANNELS, minusFirst, append(append([]Observation{}, channelsOracle[:6]...), channelsLine("-5 17 13")), "oracle:invariant_violation")

	// ==================================================== default-selection
	const SELECT = "_content/tour/concurrency/default-selection.go"
	type ev struct {
		ms   int
		kind string
	}
	tickLine := func(ms int, kind string) string {
		body := map[string]string{"tick": "tick.", "boom": "BOOM!", "default": "    ."}[kind]
		return fmt.Sprintf("[%6s] %s\n", fmt.Sprintf("%dms", ms), body)
	}
	tickRun := func(events []ev) Observation {
		var b strings.Builder
		for _, e := range events {
			b.WriteString(tickLine(e.ms, e.kind))
		}
		return obs(b.String())
	}
	selectGood := []ev{{0, "default"}, {51, "default"}, {101, "tick"}, {101, "default"}, {153, "default"},
		{205, "tick"}, {205, "default"}, {257, "default"}, {309, "tick"}, {309, "default"},
		{361, "default"}, {413, "tick"}, {413, "default"}, {465, "default"}, {517, "tick"},
		{517, "boom"}}
	selectOracle := []Observation{}
	for i := 0; i < 7; i++ {
		shifted := []ev{}
		for _, e := range selectGood {
			shifted = append(shifted, ev{e.ms + i, e.kind})
		}
		selectOracle = append(selectOracle, tickRun(shifted))
	}
	accepts("tick_boom_sequence: a real tick/default/BOOM sequence", SELECT, tickRun(selectGood), selectOracle)
	rejects("tick_boom_sequence: rejects BOOM that is not terminal (causal order)", SELECT,
		tickRun(append(append([]ev{}, selectGood[:14]...), ev{517, "boom"}, ev{520, "tick"})), selectOracle, "boom_not_final")
	rejects("tick_boom_sequence: rejects two BOOMs (event multiplicity)", SELECT,
		tickRun(append(append([]ev{}, selectGood...), ev{518, "boom"})), selectOracle, "boom_multiplicity")
	rejects("tick_boom_sequence: rejects a BOOM before its 500ms timer (timing condition)", SELECT,
		tickRun([]ev{{0, "default"}, {101, "tick"}, {205, "tick"}, {309, "tick"}, {413, "tick"}, {430, "boom"}}), selectOracle, "boom_early")
	rejects("tick_boom_sequence: rejects elapsed time going backwards", SELECT,
		tickRun([]ev{{0, "default"}, {101, "tick"}, {90, "default"}, {205, "tick"}, {309, "tick"}, {413, "tick"}, {517, "tick"}, {517, "boom"}}), selectOracle, "elapsed_not_monotonic")
	rejects("tick_boom_sequence: rejects a first tick before 100ms (timing condition)", SELECT,
		tickRun([]ev{{0, "default"}, {40, "tick"}, {205, "tick"}, {309, "tick"}, {413, "tick"}, {517, "tick"}, {517, "boom"}}), selectOracle, "tick_early")
	rejects("tick_boom_sequence: rejects a run with no default selection at all", SELECT,
		tickRun([]ev{{101, "tick"}, {205, "tick"}, {309, "tick"}, {413, "tick"}, {517, "tick"}, {517, "boom"}}), selectOracle, "no_default_selection")
	rejects("tick_boom_sequence: rejects a tick count outside the NATIVE observed range", SELECT,
		tickRun([]ev{{0, "default"}, {101, "tick"}, {205, "tick"}, {517, "boom"}}), selectOracle, "tick_count")
	rejects("tick_boom_sequence: rejects an unparseable line", SELECT, obs(tickRun(selectGood).Stdout+"surprise\n"), selectOracle, "unparsed_line")

	// ============================================================ weekday
	const WEEKDAY = "_content/tour/flowcontrol/switch-evaluation-order.go"
	weekday := func(answer string) Observation { return obs("When's Saturday?\n" + answer + "\n") }
	weekdayOracle := repeat(7, weekday("Too far away."))
	accepts("weekday_switch: the answer the recorded run clock implies", WEEKDAY, weekday("Too far away."), weekdayOracle)
	rejects("weekday_switch: rejects a value-set member that disagrees with the run clock", WEEKDAY, weekday("Today."), weekdayOracle, "answer_disagrees")
	rejects("weekday_switch: rejects a value outside the closed set", WEEKDAY, weekday("Someday."), weekdayOracle, "answer_outside_value_set")
	rejects("weekday_switch: rejects an altered prompt line", WEEKDAY, obs("When is Saturday?\nToo far away.\n"), weekdayOracle, "prompt")
	rejects("weekday_switch: rejects a missing line", WEEKDAY, obs("Too far away.\n"), weekdayOracle, "line_count")
	suite.check(`weekday_switch: a Saturday window implies "Today."`, func() any {
		saturday := time.Date(2026, 9, 12, 10, 0, 0, 0, time.Local)
		_, off := saturday.Zone()
		w := map[string]any{"from": float64(saturday.Unix()), "to": float64(saturday.Unix()) + 5, "utc_offset": int64(off)}
		ok := findings(WEEKDAY, weekday("Today."), repeat(7, weekday("Today.")), w)
		no := findings(WEEKDAY, weekday("Too far away."), repeat(7, weekday("Too far away.")), w)
		return expect(len(ok) == 0 && anyContains(no, "answer_disagrees_with_run_clock"), inspect(ok)+" / "+inspect(no))
	})

	// ============================================================ greeting
	const GREETING = "_content/tour/flowcontrol/switch-with-no-condition.go"
	greeting := func(text string) Observation { return obs(text + "\n") }
	greetingOracle := repeat(7, greeting("Good evening."))
	accepts("hour_greeting: the greeting the recorded run clock implies", GREETING, greeting("Good evening."), greetingOracle)
	rejects("hour_greeting: rejects a value-set member that disagrees with the run clock", GREETING, greeting("Good morning!"), greetingOracle, "greeting_disagrees")
	rejects("hour_greeting: rejects a value outside the closed set", GREETING, greeting("Hi."), greetingOracle, "greeting_outside_value_set")
	suite.check(`hour_greeting: a morning window implies "Good morning!"`, func() any {
		morning := time.Date(2026, 9, 8, 8, 30, 0, 0, time.Local)
		_, off := morning.Zone()
		w := map[string]any{"from": float64(morning.Unix()), "to": float64(morning.Unix()) + 5, "utc_offset": int64(off)}
		ok := findings(GREETING, greeting("Good morning!"), repeat(7, greeting("Good morning!")), w)
		no := findings(GREETING, greeting("Good evening."), repeat(7, greeting("Good evening.")), w)
		return expect(len(ok) == 0 && anyContains(no, "greeting_disagrees_with_run_clock"), inspect(ok)+" / "+inspect(no))
	})

	// ============================================================== errors
	const ERRORS = "_content/tour/methods/errors.go"
	errorLine := func(stamp string) Observation { return obs("at " + stamp + ", it didn't work\n") }
	errorsOracle := []Observation{}
	for i := 0; i < 7; i++ {
		errorsOracle = append(errorsOracle, errorLine(goStamp(float64(i)*0.5, fmt.Sprintf("0.00007%d", i))))
	}
	accepts("go_time_error_line: a timestamp inside the recorded run window", ERRORS, errorLine(goStamp(2.0, "0.000073835")), errorsOracle)
	rejects("go_time_error_line: rejects altered surrounding text", ERRORS, obs("at "+goStamp(2.0, "0.000073835")+", it worked\n"), errorsOracle, "shape")
	rejects("go_time_error_line: rejects a timestamp OUTSIDE the recorded run window", ERRORS, errorLine(goStamp(-86400.0, "0.000073835")), errorsOracle, "outside_run_window")
	rejects("go_time_error_line: rejects a missing monotonic reading", ERRORS, errorLine(goStamp(2.0, "")), errorsOracle, "no_monotonic_reading")
	rejects("go_time_error_line: rejects an implausible monotonic reading", ERRORS, errorLine(goStamp(2.0, "3600.0")), errorsOracle, "monotonic_out_of_range")
	rejects("go_time_error_line: rejects a value that is not a Go timestamp at all", ERRORS, errorLine("some time yesterday"), errorsOracle, "not_a_go_timestamp")
	rejects("go_time_error_line: rejects an extra line", ERRORS, obs("at "+goStamp(2.0, "0.000073835")+", it didn't work\nand again\n"), errorsOracle, "line_count")

	// ============================================================= sandbox
	const SANDBOX = "_content/tour/welcome/sandbox.go"
	sandbox := func(stamp, greetingText string) Observation {
		return obs(greetingText + "\nThe time is " + stamp + "\n")
	}
	const playground = "Welcome to the playground!"
	sandboxOracle := []Observation{}
	for i := 0; i < 7; i++ {
		sandboxOracle = append(sandboxOracle, sandbox(goStamp(float64(i)*0.5, fmt.Sprintf("0.00008%d", i)), playground))
	}
	accepts("sandbox_time: greeting plus a timestamp inside the run window", SANDBOX, sandbox(goStamp(3.0, "0.000073835"), playground), sandboxOracle)
	rejects("sandbox_time: rejects an altered greeting", SANDBOX, sandbox(goStamp(3.0, "0.000073835"), "Welcome to the sandbox!"), sandboxOracle, "greeting")
	rejects("sandbox_time: rejects a timestamp outside the run window", SANDBOX, sandbox(goStamp(99999.0, "0.000073835"), playground), sandboxOracle, "outside_run_window")
	rejects("sandbox_time: rejects a non-timestamp", SANDBOX, sandbox("now", playground), sandboxOracle, "not_a_go_timestamp")

	// ============================================================ line_set
	const STRINGER = "_content/tour/methods/exercise-stringer.go"
	const STRINGERS = "_content/tour/solutions/stringers.go"
	const LOOPBACK = "loopback: [127 0 0 1]"
	const GOOGLE = "googleDNS: [8 8 8 8]"
	two := func(lines ...string) Observation {
		var b strings.Builder
		for _, l := range lines {
			b.WriteString(l + "\n")
		}
		return obs(b.String())
	}
	stringerOracle := []Observation{}
	for i := 0; i < 4; i++ {
		stringerOracle = append(stringerOracle, two(LOOPBACK, GOOGLE), two(GOOGLE, LOOPBACK))
	}
	accepts("line_set: accepts either map iteration order", STRINGER, two(GOOGLE, LOOPBACK), stringerOracle)
	accepts("line_set: accepts the other order too", STRINGER, two(LOOPBACK, GOOGLE), stringerOracle)
	rejects("line_set: rejects a duplicated line", STRINGER, two(LOOPBACK, LOOPBACK), stringerOracle, "duplicate_lines")
	rejects("line_set: rejects a missing line", STRINGER, two(LOOPBACK), stringerOracle, "line_count")
	rejects("line_set: rejects an extra line", STRINGER, two(LOOPBACK, GOOGLE, "extra: [1 2 3 4]"), stringerOracle, "line_count")
	rejects("line_set: rejects a WRONG VALUE, not just a wrong order", STRINGER, two(LOOPBACK, "googleDNS: [8 8 8 9]"), stringerOracle, "unexpected_lines")
	rejects("line_set: rejects the sibling row's rendering (String() vs raw array)", STRINGER, two("loopback: 127.0.0.1", "googleDNS: 8.8.8.8"), stringerOracle, "unexpected_lines")
	suite.check("line_set: the two bound rows expect DIFFERENT renderings", func() any {
		stringersOracle := repeat(8, two("loopback: 127.0.0.1", "googleDNS: 8.8.8.8"))
		ok := findings(STRINGERS, two("googleDNS: 8.8.8.8", "loopback: 127.0.0.1"), stringersOracle, window)
		crossed := findings(STRINGERS, two(LOOPBACK, GOOGLE), stringersOracle, window)
		return expect(len(ok) == 0 && anyContains(crossed, "unexpected_lines"), inspect(ok)+" / "+inspect(crossed))
	})

	// ========================================================== webcrawler
	const CRAWLER = "_content/tour/solutions/webcrawler.go"
	crawlSample := `Found: https://golang.org/ "The Go Programming Language"
-> Crawling child 0/2 of https://golang.org/ : https://golang.org/pkg/.
-> Crawling child 1/2 of https://golang.org/ : https://golang.org/cmd/.
<- [https://golang.org/] 0/2 Waiting for child https://golang.org/pkg/.
Found: https://golang.org/pkg/ "Packages"
-> Crawling child 0/4 of https://golang.org/pkg/ : https://golang.org/.
<- Error on https://golang.org/cmd/: not found: https://golang.org/cmd/
<- [https://golang.org/] 1/2 Waiting for child https://golang.org/cmd/.
-> Crawling child 1/4 of https://golang.org/pkg/ : https://golang.org/cmd/.
-> Crawling child 2/4 of https://golang.org/pkg/ : https://golang.org/pkg/fmt/.
-> Crawling child 3/4 of https://golang.org/pkg/ : https://golang.org/pkg/os/.
<- [https://golang.org/pkg/] 0/4 Waiting for child https://golang.org/.
Found: https://golang.org/pkg/os/ "Package os"
-> Crawling child 0/2 of https://golang.org/pkg/os/ : https://golang.org/.
-> Crawling child 1/2 of https://golang.org/pkg/os/ : https://golang.org/pkg/.
<- [https://golang.org/pkg/os/] 0/2 Waiting for child https://golang.org/.
<- Done with https://golang.org/pkg/, already fetched.
<- [https://golang.org/pkg/os/] 1/2 Waiting for child https://golang.org/pkg/.
<- Done with https://golang.org/, already fetched.
<- Done with https://golang.org/pkg/os/
<- [https://golang.org/pkg/] 1/4 Waiting for child https://golang.org/cmd/.
<- Done with https://golang.org/, already fetched.
<- [https://golang.org/pkg/] 2/4 Waiting for child https://golang.org/pkg/fmt/.
<- Done with https://golang.org/cmd/, already fetched.
<- [https://golang.org/pkg/] 3/4 Waiting for child https://golang.org/pkg/os/.
Found: https://golang.org/pkg/fmt/ "Package fmt"
-> Crawling child 0/2 of https://golang.org/pkg/fmt/ : https://golang.org/.
-> Crawling child 1/2 of https://golang.org/pkg/fmt/ : https://golang.org/pkg/.
<- [https://golang.org/pkg/fmt/] 0/2 Waiting for child https://golang.org/.
<- Done with https://golang.org/pkg/, already fetched.
<- [https://golang.org/pkg/fmt/] 1/2 Waiting for child https://golang.org/pkg/.
<- Done with https://golang.org/, already fetched.
<- Done with https://golang.org/pkg/fmt/
<- Done with https://golang.org/pkg/
<- Done with https://golang.org/
Fetching stats
--------------
https://golang.org/ was fetched
https://golang.org/cmd/ failed: not found: https://golang.org/cmd/
https://golang.org/pkg/ was fetched
https://golang.org/pkg/os/ was fetched
https://golang.org/pkg/fmt/ was fetched
`
	crawl := func(text string) Observation { return obs(text) }
	sub := func(text, from, to string) string { return strings.Replace(text, from, to, 1) }
	// Native variation changes independent event/statistics order, never graph edges.
	crawlOracle := []Observation{}
	for i := 0; i < 7; i++ {
		lines := strings.SplitAfter(crawlSample, "\n")
		lines = lines[:len(lines)-1]
		if i%2 == 1 {
			n := len(lines)
			tail := append([]string{}, lines[n-5:]...)
			for j := 0; j < 5; j++ {
				lines[n-5+j] = tail[4-j]
			}
		}
		crawlOracle = append(crawlOracle, crawl(strings.Join(lines, "")))
	}
	accepts("webcrawler_crawl: a real concurrent crawl", CRAWLER, crawl(crawlSample), crawlOracle)
	rejects("webcrawler_crawl: rejects a missing statistics entry", CRAWLER, crawl(sub(crawlSample, "https://golang.org/pkg/os/ was fetched\n", "")), crawlOracle, "stats_missing")
	rejects("webcrawler_crawl: rejects an invented statistics entry", CRAWLER, crawl(crawlSample+"https://golang.org/doc/ was fetched\n"), crawlOracle, "stats_unexpected")
	rejects("webcrawler_crawl: rejects a duplicated statistics entry", CRAWLER, crawl(crawlSample+"https://golang.org/ was fetched\n"), crawlOracle, "stats_duplicate")
	rejects("webcrawler_crawl: rejects a WRONG PAGE BODY", CRAWLER, crawl(sub(crawlSample, `"Package fmt"`, `"Package format"`)), crawlOracle, "found_body")
	rejects("webcrawler_crawl: rejects a page found twice (multiplicity)", CRAWLER,
		crawl(sub(crawlSample, "Found: https://golang.org/pkg/ \"Packages\"\n", "Found: https://golang.org/pkg/ \"Packages\"\nFound: https://golang.org/pkg/ \"Packages\"\n")), crawlOracle, "found_multiplicity")
	rejects("webcrawler_crawl: rejects waiting for a child that was never crawled (causal order)", CRAWLER,
		crawl(sub(crawlSample, "-> Crawling child 0/2 of https://golang.org/ : https://golang.org/pkg/.\n", "")), crawlOracle, "causal_order")
	rejects("webcrawler_crawl: rejects an unpaired crawl/wait edge", CRAWLER,
		crawl(sub(crawlSample, "<- [https://golang.org/] 1/2 Waiting for child https://golang.org/cmd/.\n", "")), crawlOracle, "child_wait_pairing")
	rejects("webcrawler_crawl: rejects an unknown URL", CRAWLER,
		crawl(sub(crawlSample, `Found: https://golang.org/pkg/os/ "Package os"`, `Found: https://golang.org/pkg/net/ "Package os"`)), crawlOracle, "unknown_url")
	rejects("webcrawler_crawl: rejects an unparseable line", CRAWLER, crawl(sub(crawlSample, "Fetching stats\n", "surprise\nFetching stats\n")), crawlOracle, "unparsed_line")
	rejects("webcrawler_crawl: rejects a missing error observation for the unfetchable URL", CRAWLER,
		crawl(sub(crawlSample, "<- Error on https://golang.org/cmd/: not found: https://golang.org/cmd/\n", "")), crawlOracle, "error_multiplicity")

	zeroDefaults := []ev{}
	for i := 0; i < 100; i++ {
		zeroDefaults = append(zeroDefaults, ev{0, "default"})
	}
	rejects("tick: rejects 100 zero-time default events", SELECT, tickRun(append(zeroDefaults, selectGood...)), selectOracle, "default_sleep_missing")
	compressed := append([]ev{}, selectGood...)
	compressed[1] = ev{1, "default"}
	rejects("tick: rejects compressed sleep even with legal counts", SELECT, tickRun(compressed), selectOracle, "default_sleep_missing")
	rejects("crawler: rejects unknown already-fetched URL", CRAWLER,
		crawl(sub(crawlSample, "<- Done with https://golang.org/pkg/, already fetched.", "<- Done with https://wrong.invalid/, already fetched.")), crawlOracle, "unknown_url")
	rejects("crawler: rejects paired but impossible topology", CRAWLER,
		crawl(sub(sub(crawlSample, "0/2 of https://golang.org/ :", "99/200 of https://wrong.invalid/ :"), "[https://golang.org/] 0/2 Waiting", "[https://wrong.invalid/] 99/200 Waiting")), crawlOracle, "crawl_topology")
	rejects("crawler: rejects an extra terminal event for an unknown URL", CRAWLER,
		crawl(sub(crawlSample, "Fetching stats\n", "<- Done with https://wrong.invalid/\nFetching stats\n")), crawlOracle, "unknown_done_url")
	rejects("crawler: rejects duplicate already-fetched event", CRAWLER,
		crawl(sub(crawlSample, "Fetching stats", "<- Done with https://golang.org/pkg/, already fetched.\nFetching stats")), crawlOracle, "already_multiplicity")

	// ====================================================== cross-rejection
	type sample struct {
		path   string
		obs    Observation
		oracle []Observation
	}
	samples := []sample{
		{PACKAGES, packagesLine(3), packagesOracle},
		{GOROUTINES, say("hello", "world", "hello", "world", "hello", "world", "hello", "world", "hello"), goroutinesOracle},
		{CHANNELS, channelsLine("-5 17 12"), channelsOracle},
		{SELECT, tickRun(selectGood), selectOracle},
		{WEEKDAY, weekday("Too far away."), weekdayOracle},
		{GREETING, greeting("Good evening."), greetingOracle},
		{ERRORS, errorLine(goStamp(2.0, "0.000073835")), errorsOracle},
		{STRINGER, two(LOOPBACK, GOOGLE), stringerOracle},
		{CRAWLER, crawl(crawlSample), crawlOracle},
		{SANDBOX, sandbox(goStamp(3.0, "0.000073835"), playground), sandboxOracle},
	}
	for _, target := range samples {
		for _, other := range samples {
			if other.path == target.path {
				continue
			}
			t := target
			o := other
			suite.check(fmt.Sprintf("cross: %s rejects the output of %s", table[t.path].Comparator, filepath.Base(o.path)), func() any {
				got := findings(t.path, o.obs, t.oracle, window)
				return expect(len(got) != 0, "accepted another row's output")
			})
		}
	}

	// ========================================================= table binding
	suite.check("table: every declared-volatile row has exactly one comparator", func() any {
		return expect(len(table) == 11, fmt.Sprintf("%d rows", len(table)))
	})
	suite.check("table: a comparator cannot be bound to a row whose pinned digest differs", func() any {
		inventory := map[string]string{}
		for path := range table {
			inventory[path] = strings.Repeat("f", 64)
		}
		_, err := loadSemanticsTable(filepath.Join(root, "docs/tour/semantics.tsv"), inventory)
		if _, ok := err.(*TableError); ok {
			return true
		}
		return "accepted a mismatched source digest"
	})
	suite.check("table: an unknown comparator name is rejected", func() any {
		dir, _ := os.MkdirTemp("", "tour-semantics-selftest")
		defer os.RemoveAll(dir)
		path := filepath.Join(dir, "semantics.tsv")
		os.WriteFile(path, []byte("a.go\tmagic_pass\t"+strings.Repeat("a", 64)+"\trequired\tx\t{}\n"), 0o644)
		_, err := loadSemanticsTable(path, nil)
		if _, ok := err.(*TableError); ok {
			return true
		}
		return "accepted an unknown comparator"
	})
	suite.check("table: a row outside the executable inventory is rejected", func() any {
		_, err := loadSemanticsTable(filepath.Join(root, "docs/tour/semantics.tsv"), map[string]string{})
		if _, ok := err.(*TableError); ok {
			return true
		}
		return "accepted a row that is not an executable inventory row"
	})

	fmt.Printf("tour semantic comparator selftests: %d passed, %d failed\n", len(suite.passed), len(suite.failed))
	for _, f := range suite.failed {
		fmt.Fprintf(os.Stderr, "  FAIL %s\n", f)
	}
	if len(suite.failed) == 0 {
		return 0
	}
	return 1
}

func anyContains(list []string, token string) bool {
	for _, item := range list {
		if strings.Contains(item, token) {
			return true
		}
	}
	return false
}
