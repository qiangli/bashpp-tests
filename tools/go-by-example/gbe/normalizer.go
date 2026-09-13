// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Repository-versioned normalization semantics shared by evidence production
// and verification, ported from tools/go-by-example/normalizer.rb (VERSION 7), now at VERSION 8.
// Bump NormalizerVersion whenever these transformations change.
//
// VERSION 2 (Sprint 118) dropped `goexit_status`. It existed only because the
// oracle used to be `go run`, whose wrapper turns a non-zero program status
// into an "exit status N" line on ITS stderr while exiting 1 itself. The gate
// now builds a native binary with the pinned toolchain and runs it directly, so
// the real status and the real stderr are compared without reinterpretation --
// which is also what stops `os.Exit(3)` and a panic from being conflated.
// VERSION 3 (Sprint 118, Story #3) widened `wallclock` to three further
// renderings of the SAME unavoidable reading, all measured against the pinned
// toolchain on real cross-mode evidence:
//
//   - the monotonic component `m=+0.000044210` that `time.Time.String()` appends
//     — `examples/time` and `examples/epoch`;
//   - the ANSIC layout `Wed Sep  9 04:34:13 2026`, which the pre-existing rule
//     only matched when it ended in `UTC` — `examples/time-formatting-parsing`;
//   - the Kitchen layout `4:34AM` — same row.
//
// Each is a wall-clock reading two separate invocations cannot make agree, which
// is the only thing a normalization is licensed to cancel. None of them widens
// to anything else: `examples/logging` still fails on `logging.go:40` becoming
// `main.go:24`, which is a real source-position defect and not a clock.
// VERSION 4 rejects extra interleaved output and unlicensed worker/job IDs;
// ordering normalization never licenses discarding additional observable events.
// VERSION 6 licenses only the pinned closing-channels program's proven
// partial order; exact event membership and both streams remain checked.
// VERSION 7 (Sprint 118, Story #18) adds the reviewed json.go stream:
// exactly two map-derived JSON objects may vary in key order; the remaining
// thirteen lines and the object membership remain observable.
// VERSION 8 (Sprint 155, S155.10) corrects the wallclock day-class rule to the
// pinned switch.go bytes: the program prints `It's the weekend` on Saturdays and
// Sundays and `It's a weekday` otherwise, while VERSION 7 only matched
// `It's a weekend`, a string the program never prints, so every weekend replay
// failed the row as fail_normalization in all three modes (measured on
// 2026-09-12, a Saturday, by the first replay of this port). The day class and
// the noon class are still the only two lines cancelled; both remain a single
// token per line, and the other four lines stay byte-for-byte.
//
// The Ruby regular expressions are reproduced with Go's RE2 engine, whose
// leftmost-first alternation and greedy-quantifier match selection coincide
// with Onigmo's for these patterns; the two lookaround assertions Ruby used
// (`(?<![\w.])\d{10,19}(?![\w.])` and `(?<=:)\d{2,5}\b`) are implemented as
// explicit boundary scans with the same acceptance set.
package main

import (
	"fmt"
	"math"
	"math/big"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const NormalizerVersion = 8

var NormalizerNames = []string{"none", "argv0_path", "env_listing", "file_metadata", "tmp_path", "ephemeral_port", "wallclock", "duration", "panic_trace", "random_stream", "map_order", "interleave_order", "closing_channel_order", "throughput_count", "pointer_address"}
var stdoutNames = []string{"argv0_path", "env_listing", "file_metadata", "tmp_path", "ephemeral_port", "duration", "random_stream", "map_order", "interleave_order", "closing_channel_order", "throughput_count", "pointer_address"}
var stderrNames = []string{"panic_trace"}

// NormalizeError is the RuntimeError a comparator raises when the observed
// output does not have the shape its licence describes.
type NormalizeError struct{ msg string }

func (e *NormalizeError) Error() string { return e.msg }
func normErr(msg string) error          { return &NormalizeError{msg: msg} }

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

var (
	reArgv0        = regexp.MustCompile(`\A\[[^\] ]+`)
	reEnvKey       = regexp.MustCompile(`\A[A-Za-z_][A-Za-z0-9_]*\n?\z`)
	reTmpPath      = regexp.MustCompile(`(?:/[^\s]+/)?sample(?:dir)?\d+`)
	rePointer      = regexp.MustCompile(`0x[0-9a-fA-F]+`)
	reWallclock    = regexp.MustCompile(`\bm=[+-][\d.]+|\b\d{4}[-/]\d\d[-/]\d\d(?:T| )[0-9:.+\-Z ]+|\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\w+\s+\d+\s+\d\d:\d\d:\d\d\s+(?:UTC\s+)?\d{4}\b|\b\d{1,2}:\d\d(?:AM|PM)\b`)
	reDayClass     = regexp.MustCompile(`It's (?:the weekend|a weekday)`)
	reNoonClass    = regexp.MustCompile(`It's (?:before|after) noon`)
	reNoonPresent  = regexp.MustCompile(`It's before noon|It's after noon`)
	reAllDigits    = regexp.MustCompile(`\A\d+\z`)
	reDuration     = regexp.MustCompile(`\b\d+(?:\.\d+)?(?:ns|µs|us|ms|s)\b`)
	reGoroutine    = regexp.MustCompile(`\Agoroutine : [012]\n\z`)
	reWorkerEvent  = regexp.MustCompile(`\AWorker (\d+) (starting|done)\n\z`)
	rePoolEvent    = regexp.MustCompile(`\Aworker (\d+) (started |finished) job (\d+)\n\z`)
	reThroughput   = regexp.MustCompile(`\A(readOps|writeOps): (\d+)\n?\z`)
	reMetaLine     = regexp.MustCompile(`\A[-dl][rwx-]{9}[@+]?\s+`)
	reMetaFields   = regexp.MustCompile(`\A([-dl][rwx-]{9})[@+]?\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+\d+\s+\d\d:\d\d`)
	reMonotonicTag = regexp.MustCompile(` m=[+-][\d.]+\z`)
	reGoDuration   = regexp.MustCompile(`\A(?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)s\z`)
)

// rubyChomp is String#chomp: one trailing "\r\n", "\n" or "\r" removed.
func rubyChomp(s string) string {
	if strings.HasSuffix(s, "\r\n") {
		return s[:len(s)-2]
	}
	if strings.HasSuffix(s, "\n") || strings.HasSuffix(s, "\r") {
		return s[:len(s)-1]
	}
	return s
}

// rubySplitComma is String#split(","): trailing empty fields dropped.
func rubySplitComma(s string) []string {
	parts := strings.Split(s, ",")
	for len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

var reRubyInteger = regexp.MustCompile(`\A[+-]?(?:0[xX][0-9a-fA-F][0-9a-fA-F_]*|0[bB][01][01_]*|0[oO]?[0-7][0-7_]*|0[dD][0-9][0-9_]*|[1-9][0-9_]*|0)\z`)

// rubyInteger is Kernel#Integer(String): strict, radix prefixes honoured,
// surrounding whitespace tolerated, anything else an ArgumentError.
func rubyInteger(s string) (*big.Int, error) {
	t := rubyStrip(s)
	if !reRubyInteger.MatchString(t) || strings.Contains(t, "__") || strings.HasSuffix(t, "_") {
		return nil, fmt.Errorf("invalid value for Integer(): %q", s)
	}
	neg := strings.HasPrefix(t, "-")
	t = strings.TrimLeft(t, "+-")
	t = strings.ReplaceAll(t, "_", "")
	base := 10
	switch {
	case strings.HasPrefix(t, "0x") || strings.HasPrefix(t, "0X"):
		base, t = 16, t[2:]
	case strings.HasPrefix(t, "0b") || strings.HasPrefix(t, "0B"):
		base, t = 2, t[2:]
	case strings.HasPrefix(t, "0o") || strings.HasPrefix(t, "0O"):
		base, t = 8, t[2:]
	case strings.HasPrefix(t, "0d") || strings.HasPrefix(t, "0D"):
		t = t[2:]
	case len(t) > 1 && t[0] == '0':
		base = 8
	}
	v, ok := new(big.Int).SetString(t, base)
	if !ok {
		return nil, fmt.Errorf("invalid value for Integer(): %q", s)
	}
	if neg {
		v.Neg(v)
	}
	return v, nil
}

var reRubyFloat = regexp.MustCompile(`\A[+-]?(?:\d[\d_]*)(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?\z`)

// rubyFloatParse is Kernel#Float(String).
func rubyFloatParse(s string) (float64, error) {
	t := rubyStrip(s)
	if !reRubyFloat.MatchString(t) || strings.Contains(t, "__") || strings.HasSuffix(t, "_") {
		return 0, fmt.Errorf("invalid value for Float(): %q", s)
	}
	return strconv.ParseFloat(strings.ReplaceAll(t, "_", ""), 64)
}

// --- Time.parse -----------------------------------------------------------------

var (
	reTimeISO     = regexp.MustCompile(`\A\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?(.*)\z`)
	reTimeANSIC   = regexp.MustCompile(`\A\s*(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+([A-Za-z]+)\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(?:UTC\s+)?(\d{4})\s*\z`)
	reTimeKitchen = regexp.MustCompile(`\A\s*(\d{1,2}):(\d{2})(AM|PM)\s*\z`)
	reZone        = regexp.MustCompile(`(?:\A|\s)(Z|[+-]\d{2}:?\d{2})(?:\s|\z)`)
)

var monthNames = []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}

// rubyTimeParse is the subset of Time.parse the wallclock comparator can meet:
// the ISO-like layouts of time.Time.String()/RFC3339, the ANSIC layout, and the
// Kitchen layout. It reports the same accept/reject decision Ruby makes
// (component ranges are Time.new's), which is all the comparator records.
func rubyTimeParse(text string) (time.Time, bool) {
	if m := reTimeISO.FindStringSubmatch(text); m != nil {
		year, _ := strconv.Atoi(m[1])
		month, _ := strconv.Atoi(m[2])
		day, _ := strconv.Atoi(m[3])
		hour, minute, second, nanos := 0, 0, 0, 0
		if m[4] != "" {
			hour, _ = strconv.Atoi(m[4])
			minute, _ = strconv.Atoi(m[5])
			if m[6] != "" {
				second, _ = strconv.Atoi(m[6])
			}
			if m[7] != "" {
				frac := m[7]
				if len(frac) > 9 {
					frac = frac[:9]
				}
				nanos, _ = strconv.Atoi(frac + strings.Repeat("0", 9-len(frac)))
			}
		}
		if month < 1 || month > 12 || day < 1 || day > 31 || hour > 24 || minute > 59 || second > 60 {
			return time.Time{}, false
		}
		loc := time.Local
		rest := m[8]
		if z := reZone.FindStringSubmatch(rest); z != nil {
			loc = zoneFor(z[1])
		} else if strings.Contains(rest, "UTC") || strings.Contains(rest, "GMT") {
			loc = time.UTC
		}
		return time.Date(year, time.Month(month), day, hour, minute, second, nanos, loc), true
	}
	if m := reTimeANSIC.FindStringSubmatch(text); m != nil {
		month := 1
		for i, name := range monthNames {
			if strings.HasPrefix(strings.ToLower(m[1]), name) {
				month = i + 1
			}
		}
		day, _ := strconv.Atoi(m[2])
		hour, _ := strconv.Atoi(m[3])
		minute, _ := strconv.Atoi(m[4])
		second, _ := strconv.Atoi(m[5])
		year, _ := strconv.Atoi(m[6])
		if day < 1 || day > 31 || hour > 24 || minute > 59 || second > 60 {
			return time.Time{}, false
		}
		loc := time.Local
		if strings.Contains(text, "UTC") {
			loc = time.UTC
		}
		return time.Date(year, time.Month(month), day, hour, minute, second, 0, loc), true
	}
	if m := reTimeKitchen.FindStringSubmatch(text); m != nil {
		hour, _ := strconv.Atoi(m[1])
		minute, _ := strconv.Atoi(m[2])
		if hour > 12 || minute > 59 {
			return time.Time{}, false
		}
		if m[3] == "PM" && hour < 12 {
			hour += 12
		}
		if m[3] == "AM" && hour == 12 {
			hour = 0
		}
		now := time.Now()
		return time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, time.Local), true
	}
	return time.Time{}, false
}

func zoneFor(z string) *time.Location {
	if z == "Z" {
		return time.UTC
	}
	sign := 1
	if z[0] == '-' {
		sign = -1
	}
	digits := strings.ReplaceAll(z[1:], ":", "")
	hh, _ := strconv.Atoi(digits[:2])
	mm, _ := strconv.Atoi(digits[2:])
	return time.FixedZone("", sign*(hh*3600+mm*60))
}

// --- the time example -------------------------------------------------------------

// normalizeTimeExample: the pinned time example prints one volatile instant and
// values derived from it. Validate every arithmetic relationship before
// removing that instant; fixed date fields, comparisons and all output
// structure remain observable.
func normalizeTimeExample(output string) (string, error) {
	raw := rubyLines(output)
	lines := make([]string, len(raw))
	for i, l := range raw {
		lines[i] = rubyChomp(l)
	}
	expected := []string{"2009", "November", "17", "20", "34", "58", "651387237", "UTC", "Tuesday"}
	if len(lines) < 21 || strings.Join(lines[2:11], "\x00") != strings.Join(expected, "\x00") {
		return "", normErr("time fixed components")
	}
	parseNS := func(text string) (*big.Int, bool) {
		t, ok := rubyTimeParse(reMonotonicTag.ReplaceAllString(text, ""))
		if !ok {
			return nil, false
		}
		ns := new(big.Int).Mul(big.NewInt(t.Unix()), big.NewInt(1_000_000_000))
		return ns.Add(ns, big.NewInt(int64(t.Nanosecond()))), true
	}
	now, ok := parseNS(lines[0])
	if !ok {
		return "", normErr("time fixed instant")
	}
	fixed := new(big.Int).Mul(big.NewInt(time.Date(2009, 11, 17, 20, 34, 58, 0, time.UTC).Unix()), big.NewInt(1_000_000_000))
	fixed.Add(fixed, big.NewInt(651_387_237))
	if v, ok := parseNS(lines[1]); !ok || v.Cmp(fixed) != 0 {
		return "", normErr("time fixed instant")
	}
	cmp := fixed.Cmp(now)
	comparisons := []string{strconv.FormatBool(cmp < 0), strconv.FormatBool(cmp > 0), strconv.FormatBool(cmp == 0)}
	if strings.Join(lines[11:14], "\x00") != strings.Join(comparisons, "\x00") {
		return "", normErr("time comparisons")
	}
	difference := new(big.Int).Sub(now, fixed)
	dm := reGoDuration.FindStringSubmatch(lines[14])
	if dm == nil {
		return "", normErr("time duration shape")
	}
	rendered := new(big.Int)
	if dm[1] != "" {
		h, _ := new(big.Int).SetString(dm[1], 10)
		rendered.Add(rendered, h.Mul(h, big.NewInt(3_600_000_000_000)))
	}
	if dm[2] != "" {
		m, _ := new(big.Int).SetString(dm[2], 10)
		rendered.Add(rendered, m.Mul(m, big.NewInt(60_000_000_000)))
	}
	secNS, exact := rationalSecondsToNS(dm[3])
	if !exact {
		return "", normErr("time duration arithmetic")
	}
	rendered.Add(rendered, secNS)
	nanos, err := rubyInteger(lines[18])
	if err != nil || rendered.Cmp(difference) != 0 || nanos.Cmp(difference) != 0 {
		return "", normErr("time duration arithmetic")
	}
	diffFloat, _ := new(big.Float).SetInt(difference).Float64()
	for index, divisor := range []float64{3_600_000_000_000, 60_000_000_000, 1_000_000_000} {
		actual, err := rubyFloatParse(lines[15+index])
		if err != nil {
			return "", normErr("time duration units")
		}
		expectedValue := diffFloat / divisor
		tolerance := math.Max(math.Abs(expectedValue)*1e-14, 1e-9)
		if math.IsInf(actual, 0) || math.IsNaN(actual) || math.Abs(actual-expectedValue) > tolerance {
			return "", normErr("time duration units")
		}
	}
	twice := new(big.Int).Mul(fixed, big.NewInt(2))
	twice.Sub(twice, now)
	if v, ok := parseNS(lines[19]); !ok || v.Cmp(now) != 0 {
		return "", normErr("time addition arithmetic")
	}
	if v, ok := parseNS(lines[20]); !ok || v.Cmp(twice) != 0 {
		return "", normErr("time addition arithmetic")
	}
	return Generate(Obj("fixed", lines[1:11], "comparisons", lines[11:14], "duration_units", "consistent", "additions", "consistent")), nil
}

// rationalSecondsToNS is Rational(text) * 1_000_000_000 when that product is
// an Integer; a fraction finer than a nanosecond can never equal one.
func rationalSecondsToNS(text string) (*big.Int, bool) {
	whole, frac, _ := strings.Cut(text, ".")
	if len(frac) > 9 {
		if strings.Trim(frac[9:], "0") != "" {
			return nil, false
		}
		frac = frac[:9]
	}
	frac += strings.Repeat("0", 9-len(frac))
	v, ok := new(big.Int).SetString(whole+frac, 10)
	return v, ok
}

// --- lookaround stand-ins -----------------------------------------------------------

func isWordOrDot(c byte) bool {
	return c == '.' || c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isWord(c byte) bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// epochRuns finds every match of `(?<![\w.])\d{10,19}(?![\w.])`: a maximal
// digit run of 10-19 digits bounded on both sides by a non-word, non-dot
// character (or the text edge).
func epochRuns(s string) [][2]int {
	var out [][2]int
	i := 0
	for i < len(s) {
		if !isDigit(s[i]) {
			i++
			continue
		}
		start := i
		for i < len(s) && isDigit(s[i]) {
			i++
		}
		n := i - start
		if n >= 10 && n <= 19 && (start == 0 || !isWordOrDot(s[start-1])) && (i == len(s) || !isWordOrDot(s[i])) {
			out = append(out, [2]int{start, i})
		}
	}
	return out
}

// wallclockScan is `output.scan(...)` for the five-alternative wallclock
// pattern: leftmost match wins, alternatives 1-4 are tried by the RE2 engine,
// and the epoch alternative is merged by position.
func wallclockScan(s string) []string {
	regexMatches := reWallclock.FindAllStringIndex(s, -1)
	runs := epochRuns(s)
	var values []string
	pos, ri, ei := 0, 0, 0
	for {
		for ri < len(regexMatches) && regexMatches[ri][0] < pos {
			ri++
		}
		for ei < len(runs) && runs[ei][0] < pos {
			ei++
		}
		if ri >= len(regexMatches) && ei >= len(runs) {
			return values
		}
		var next [2]int
		switch {
		case ri >= len(regexMatches):
			next = runs[ei]
		case ei >= len(runs):
			next = [2]int{regexMatches[ri][0], regexMatches[ri][1]}
		case regexMatches[ri][0] <= runs[ei][0]:
			next = [2]int{regexMatches[ri][0], regexMatches[ri][1]}
		default:
			next = runs[ei]
		}
		values = append(values, s[next[0]:next[1]])
		pos = next[1]
	}
}

// replacePorts is `gsub(/(?<=:)\d{2,5}\b/, "<port>")`.
func replacePorts(s string) string {
	var b strings.Builder
	i := 0
	for i < len(s) {
		if s[i] == ':' && i+1 < len(s) && isDigit(s[i+1]) {
			j := i + 1
			for j < len(s) && isDigit(s[j]) {
				j++
			}
			n := j - (i + 1)
			if n >= 2 && n <= 5 && (j == len(s) || !isWord(s[j])) {
				b.WriteByte(':')
				b.WriteString("<port>")
				i = j
				continue
			}
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}

// --- the registry ---------------------------------------------------------------

// Normalize applies the row's licensed normalizations to one stream. It is
// GoByExampleNormalizer.normalize: a stdout-only rule is an exact no-op for
// stderr and vice versa, and every shape violation is an error the gate turns
// into fail_normalization.
func Normalize(data []byte, names []string, stream string) (string, error) {
	if !utf8.Valid(data) {
		return "", normErr("invalid UTF-8 " + stream)
	}
	output := string(data)
	for _, name := range names {
		if name == "none" || (stream == "stdout" && contains(stderrNames, name)) || (stream == "stderr" && contains(stdoutNames, name)) {
			continue
		}
		var err error
		switch name {
		case "argv0_path":
			lines := rubyLines(output)
			if len(lines) == 0 || !strings.HasPrefix(lines[0], "[") {
				return "", normErr("argv0_path shape")
			}
			if loc := reArgv0.FindStringIndex(lines[0]); loc != nil {
				lines[0] = "[<argv0>" + lines[0][loc[1]:]
			}
			output = strings.Join(lines, "")
		case "env_listing":
			lines := rubyLines(output)
			separator := -1
			for i, l := range lines {
				if l == "\n" {
					separator = i
					break
				}
			}
			if separator < 0 || len(lines) < 2 || !strings.HasPrefix(lines[0], "FOO:") || !strings.HasPrefix(lines[1], "BAR:") {
				return "", normErr("env_listing shape")
			}
			keys := append([]string(nil), lines[separator+1:]...)
			for _, line := range keys {
				if !reEnvKey.MatchString(line) {
					return "", normErr("env key shape")
				}
			}
			sort.Strings(keys)
			output = strings.Join(lines[:separator+1], "") + strings.Join(keys, "")
		case "tmp_path":
			output = reTmpPath.ReplaceAllLiteralString(output, "<tmp>")
		case "pointer_address":
			output = rePointer.ReplaceAllLiteralString(output, "<ptr>")
		case "wallclock":
			if output == "" {
				continue
			}
			lines := rubyLines(output)
			if stream == "stdout" && len(lines) == 21 && strings.HasPrefix(lines[1], "2009-11-17 ") {
				output, err = normalizeTimeExample(output)
				if err != nil {
					return "", err
				}
				continue
			}
			values := wallclockScan(output)
			if len(values) == 0 {
				if !reDayClass.MatchString(output) || !reNoonPresent.MatchString(output) {
					return "", normErr("wallclock shape")
				}
				output = reNoonClass.ReplaceAllLiteralString(reDayClass.ReplaceAllLiteralString(output, "<volatile:day-class>"), "<volatile:noon-class>")
			} else {
				types := make([]any, len(values))
				var previous *big.Int
				for i, value := range values {
					switch {
					case reAllDigits.MatchString(value):
						n, _ := new(big.Int).SetString(value, 10)
						if previous != nil && n.Cmp(previous) < 0 {
							return "", normErr("wallclock order")
						}
						previous = n
						types[i] = "Integer"
					case strings.HasPrefix(value, "m="):
						types[i] = "String"
					default:
						if _, ok := rubyTimeParse(strings.ReplaceAll(value, "/", "-")); ok {
							types[i] = "Time"
						} else {
							types[i] = "String"
						}
					}
				}
				shape := output
				for index, value := range values {
					shape = strings.Replace(shape, value, "<volatile:time:"+itoa(index)+">", 1)
				}
				output = Generate(Obj("shape", shape, "types", types, "ordered", true))
			}
		case "duration":
			values := reDuration.FindAllString(output, -1)
			if len(values) == 0 {
				return "", normErr("duration shape")
			}
			output = Generate(Obj("text", output, "values", values))
		case "panic_trace":
			if !strings.Contains(output, "panic:") {
				return "", normErr("panic trace shape")
			}
			var kept []string
			for _, line := range rubyLines(output) {
				if strings.HasPrefix(line, "goroutine ") {
					break
				}
				kept = append(kept, line)
			}
			output = strings.Join(kept, "")
		case "random_stream":
			lines := rubyLines(output)
			if len(lines) != 5 {
				return "", normErr("random stream arity")
			}
			ints, err := parseIntList(rubyStrip(lines[0]))
			if err != nil {
				return "", err
			}
			unit, err := rubyFloatParse(lines[1])
			if err != nil {
				return "", err
			}
			floats, err := parseFloatList(rubyStrip(lines[2]))
			if err != nil {
				return "", err
			}
			tail := make([][]*big.Int, 0, 2)
			for _, line := range lines[3:] {
				row, err := parseIntList(rubyStrip(line))
				if err != nil {
					return "", err
				}
				tail = append(tail, row)
			}
			ok := len(ints) == 2 && len(floats) == 2 && len(tail) == 2 && unit >= 0.0 && unit < 1.0
			for _, v := range ints {
				ok = ok && v.Sign() >= 0 && v.Cmp(big.NewInt(100)) < 0
			}
			for _, v := range floats {
				ok = ok && v >= 5.0 && v < 10.0
			}
			ok = ok && bigListEqual(tail[0], tail[1])
			if !ok {
				return "", normErr("random range")
			}
			tailValues := make([]any, len(tail[0]))
			for i, v := range tail[0] {
				tailValues[i] = Number{Big: v.String()}
			}
			output = Generate(Obj("shape", []string{"int<100,int<100", "float[0,1)", "float[5,10),float[5,10)", "seeded-pair", "same-seeded-pair"}, "tail", tailValues))
		case "map_order":
			lines := rubyLines(output)
			switch {
			case len(lines) == 8 && lines[0] == "sum: 9\n" && lines[1] == "index: 1\n" && lines[6] == "0 103\n" && lines[7] == "1 111\n":
				pairs := []string{lines[2], lines[3]}
				keys := []string{lines[4], lines[5]}
				sort.Strings(pairs)
				sort.Strings(keys)
				if strings.Join(pairs, "") != "a -> apple\nb -> banana\n" || strings.Join(keys, "") != "key: a\nkey: b\n" {
					return "", normErr("map members")
				}
				output = lines[0] + lines[1] + strings.Join(pairs, "") + strings.Join(keys, "") + lines[6] + lines[7]
			case len(lines) == 15:
				// encoding/json/v2 emits these two map[string]int values in map
				// iteration order. Every other line is retained byte-for-byte.
				for _, index := range []int{5, 13} {
					value := lines[index]
					if value != "{\"apple\":5,\"lettuce\":7}\n" && value != "{\"lettuce\":7,\"apple\":5}\n" {
						return "", normErr("json map members")
					}
					lines[index] = "{\"apple\":5,\"lettuce\":7}\n"
				}
				output = strings.Join(lines, "")
			default:
				return "", normErr("map shape")
			}
		case "closing_channel_order":
			// Each log follows its send/receive, not the other goroutine's log.
			// Capacity 5 exceeds the three jobs: no additional buffer-full edge.
			producer := []string{"sent job 1\n", "sent job 2\n", "sent job 3\n", "sent all jobs\n"}
			consumer := []string{"received job 1\n", "received job 2\n", "received job 3\n", "received all jobs\n"}
			final := "received more jobs: false\n"
			expected := append(append(append([]string{}, producer...), consumer...), final)
			lines := rubyLines(output)
			sortedLines := append([]string(nil), lines...)
			sortedExpected := append([]string(nil), expected...)
			sort.Strings(sortedLines)
			sort.Strings(sortedExpected)
			if strings.Join(sortedLines, "") != strings.Join(sortedExpected, "") || len(sortedLines) != len(sortedExpected) {
				return "", normErr("closing channel event membership")
			}
			positions := map[string]int{}
			for i, l := range lines {
				positions[l] = i
			}
			var edges [][2]string
			for i := 0; i+1 < len(producer); i++ {
				edges = append(edges, [2]string{producer[i], producer[i+1]})
			}
			for i := 0; i+1 < len(consumer); i++ {
				edges = append(edges, [2]string{consumer[i], consumer[i+1]})
			}
			edges = append(edges, [2]string{producer[0], consumer[1]}, [2]string{producer[1], consumer[2]},
				[2]string{producer[2], consumer[3]}, [2]string{producer[3], final}, [2]string{consumer[3], final})
			for _, e := range edges {
				if !(positions[e[0]] < positions[e[1]]) {
					return "", normErr("closing channel causal order")
				}
			}
			output = strings.Join(expected, "")
		case "interleave_order":
			lines := rubyLines(output)
			if len(lines) == 0 {
				return "", normErr("interleave shape")
			}
			anyPrefix := func(prefix string) bool {
				for _, l := range lines {
					if strings.HasPrefix(l, prefix) {
						return true
					}
				}
				return false
			}
			switch {
			case anyPrefix("direct"):
				if len(lines) < 4 || strings.Join(lines[:3], "") != "direct : 0\ndirect : 1\ndirect : 2\n" || lines[len(lines)-1] != "done\n" {
					return "", normErr("direct causal order")
				}
				middle := lines[3 : len(lines)-1]
				if len(middle) != 4 {
					return "", normErr("unexpected interleave output")
				}
				var goroutine []string
				going := 0
				for _, line := range middle {
					if line == "going\n" {
						going++
					} else if reGoroutine.MatchString(line) {
						goroutine = append(goroutine, line)
					} else {
						return "", normErr("unexpected interleave output")
					}
				}
				if strings.Join(goroutine, "") != "goroutine : 0\ngoroutine : 1\ngoroutine : 2\n" || going != 1 {
					return "", normErr("goroutine subsequence")
				}
				output = Generate(Obj("prefix", lines[:3], "chains", []any{goroutine, []string{"going\n"}}, "suffix", []string{lines[len(lines)-1]}))
			case anyPrefix("Worker"):
				type event struct {
					id    int
					state string
				}
				var events []event
				for _, line := range lines {
					m := reWorkerEvent.FindStringSubmatch(line)
					if m == nil {
						return "", normErr("worker event shape")
					}
					id, _ := strconv.Atoi(m[1])
					events = append(events, event{id, m[2]})
				}
				if len(events) != 10 {
					return "", normErr("worker event shape")
				}
				for _, e := range events {
					if e.id < 1 || e.id > 5 {
						return "", normErr("worker event shape")
					}
				}
				for id := 1; id <= 5; id++ {
					var positions []int
					for i, e := range events {
						if e.id == id {
							positions = append(positions, i)
						}
					}
					if len(positions) != 2 || events[positions[0]].state != "starting" || events[positions[1]].state != "done" {
						return "", normErr("worker causal order")
					}
				}
				workers := make([]any, 0, 5)
				for id := 1; id <= 5; id++ {
					workers = append(workers, []any{Int(int64(id)), "starting", "done"})
				}
				output = Generate(Obj("workers", workers))
			default:
				type event struct {
					worker int
					state  string
					job    int
				}
				var events []event
				for _, line := range lines {
					m := rePoolEvent.FindStringSubmatch(line)
					if m == nil {
						return "", normErr("pool event shape")
					}
					worker, _ := strconv.Atoi(m[1])
					job, _ := strconv.Atoi(m[3])
					events = append(events, event{worker, m[2], job})
				}
				if len(events) != 10 {
					return "", normErr("pool event shape")
				}
				for _, e := range events {
					if e.worker < 1 || e.worker > 3 || e.job < 1 || e.job > 5 {
						return "", normErr("pool event shape")
					}
				}
				for job := 1; job <= 5; job++ {
					var positions []int
					for i, e := range events {
						if e.job == job {
							positions = append(positions, i)
						}
					}
					if len(positions) != 2 || !strings.HasPrefix(events[positions[0]].state, "started") || events[positions[1]].state != "finished" || events[positions[0]].worker != events[positions[1]].worker {
						return "", normErr("pool causal order")
					}
				}
				output = Generate(Obj("jobs", []any{Int(1), Int(2), Int(3), Int(4), Int(5)}, "constraint", "same-worker start-before-finish"))
			}
		case "throughput_count":
			lines := rubyLines(output)
			if len(lines) != 2 {
				return "", normErr("throughput shape")
			}
			var names []string
			for _, line := range lines {
				m := reThroughput.FindStringSubmatch(line)
				if m == nil {
					return "", normErr("throughput shape")
				}
				v, err := rubyInteger(m[2])
				if err != nil || v.Sign() <= 0 {
					return "", normErr("throughput shape")
				}
				names = append(names, m[1])
			}
			if strings.Join(names, ",") != "readOps,writeOps" {
				return "", normErr("throughput shape")
			}
			output = Generate(Obj("readOps", "positive integer", "writeOps", "positive integer"))
		case "file_metadata":
			lines := rubyLines(output)
			for i, line := range lines {
				if !reMetaLine.MatchString(line) {
					continue
				}
				if loc := reMetaFields.FindStringSubmatchIndex(line); loc != nil {
					lines[i] = line[loc[2]:loc[3]] + " <metadata>" + line[loc[1]:]
				}
			}
			output = strings.Join(lines, "")
		case "ephemeral_port":
			output = replacePorts(output)
		default:
			return "", normErr("normalizer has no implementation: " + name)
		}
	}
	return output, nil
}

func parseIntList(s string) ([]*big.Int, error) {
	var out []*big.Int
	for _, part := range rubySplitComma(s) {
		v, err := rubyInteger(part)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func parseFloatList(s string) ([]float64, error) {
	var out []float64
	for _, part := range rubySplitComma(s) {
		v, err := rubyFloatParse(part)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

func bigListEqual(a, b []*big.Int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Cmp(b[i]) != 0 {
			return false
		}
	}
	return true
}
