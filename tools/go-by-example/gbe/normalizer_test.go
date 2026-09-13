// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	if env := os.Getenv("GBE_ROOT"); env != "" {
		return env
	}
	wd, _ := os.Getwd()
	return filepath.Clean(filepath.Join(wd, "../../.."))
}

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(repoRoot(t), "tests/go-by-example/fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func mustNormalize(t *testing.T, data string, names []string, stream string) string {
	t.Helper()
	out, err := Normalize([]byte(data), names, stream)
	if err != nil {
		t.Fatalf("normalize %v %s: %v", names, stream, err)
	}
	return out
}

func jsonOutput(first, second string) string {
	return "true\n1\n2.34\n\"gopher\"\n[\"apple\",\"peach\",\"pear\"]\n" + first + "\n" +
		"{\"Page\":1,\"Fruits\":[\"apple\",\"peach\",\"pear\"]}\n{\"page\":1,\"fruits\":[\"apple\",\"peach\",\"pear\"]}\n" +
		"map[num:6.13 strs:[a b]]\n6.13\na\n{1 [apple peach]}\napple\n" + second + "\n{1 [apple peach]}\n"
}

// The reviewed json.go stream: exactly two map-derived objects may vary in key
// order; everything else stays byte-for-byte and changed members are refused.
func TestMapOrderCanonicalizesOnlyTheTwoJSONMapRegions(t *testing.T) {
	appleFirst := jsonOutput(`{"apple":5,"lettuce":7}`, `{"apple":5,"lettuce":7}`)
	lettuceFirst := jsonOutput(`{"lettuce":7,"apple":5}`, `{"lettuce":7,"apple":5}`)
	if mustNormalize(t, appleFirst, []string{"map_order"}, "stdout") != mustNormalize(t, lettuceFirst, []string{"map_order"}, "stdout") {
		t.Fatal("map order was not canonicalized")
	}
	if mustNormalize(t, appleFirst, []string{"map_order"}, "stdout") != appleFirst {
		t.Fatal("canonical output must be retained byte-for-byte")
	}
	good := jsonOutput(`{"apple":5,"lettuce":7}`, `{"lettuce":7,"apple":5}`)
	if _, err := Normalize([]byte(strings.Replace(good, `"lettuce":7`, `"lettuce":8`, 1)), []string{"map_order"}, "stdout"); err == nil {
		t.Fatal("changed map members must be refused")
	}
	if mustNormalize(t, good, []string{"map_order"}, "stdout") == mustNormalize(t, strings.Replace(good, "2.34\n", "9.99\n", 1), []string{"map_order"}, "stdout") {
		t.Fatal("deterministic lines must stay observable")
	}
	if _, err := Normalize([]byte(good+"unexpected\n"), []string{"map_order"}, "stdout"); err == nil {
		t.Fatal("extra output must be refused")
	}
	if _, err := Normalize([]byte("sum: 9\nindex: 1\na -> apple\nb -> banana\nkey: a\nkey: b\n0 103\n1 111\n"), []string{"map_order"}, "stdout"); err != nil {
		t.Fatal(err)
	}
}

// Every retained native closing-channels observation is admitted and reduces
// to the same canonical event list; a causal inversion is refused.
func TestClosingChannelOrder(t *testing.T) {
	expected := "sent job 1\nsent job 2\nsent job 3\nsent all jobs\nreceived job 1\nreceived job 2\nreceived job 3\nreceived all jobs\nreceived more jobs: false\n"
	for i := 0; i < 6; i++ {
		data := fixture(t, "closing-channels/native-0"+itoa(i)+".stdout.txt")
		if got := mustNormalize(t, string(data), []string{"closing_channel_order"}, "stdout"); got != expected {
			t.Fatalf("fixture %d normalized to %q", i, got)
		}
	}
	inverted := "received job 2\nsent job 1\nsent job 2\nsent job 3\nsent all jobs\nreceived job 1\nreceived job 3\nreceived all jobs\nreceived more jobs: false\n"
	if _, err := Normalize([]byte(inverted), []string{"closing_channel_order"}, "stdout"); err == nil || err.Error() != "closing channel causal order" {
		t.Fatalf("inverted order accepted: %v", err)
	}
	if _, err := Normalize([]byte(expected+"sent job 1\n"), []string{"closing_channel_order"}, "stdout"); err == nil || err.Error() != "closing channel event membership" {
		t.Fatalf("duplicate event accepted: %v", err)
	}
}

// Retained oracle/compiled observations of the wallclock and file_metadata rows
// normalize to identical comparator inputs, exactly as the gate compares them.
func TestRetainedObservationsAgreeAfterNormalization(t *testing.T) {
	cases := []struct {
		name  string
		names []string
	}{
		{"time", []string{"wallclock"}},
		{"execing-processes", []string{"file_metadata"}},
		{"stateful-goroutines", []string{"throughput_count"}},
	}
	for _, c := range cases {
		for _, stream := range []string{"stdout", "stderr"} {
			oracle := fixture(t, "observations/"+c.name+".oracle."+stream+".txt")
			compiled := fixture(t, "observations/"+c.name+".compiled."+stream+".txt")
			a, err := Normalize(oracle, c.names, stream)
			if err != nil {
				t.Fatalf("%s oracle %s: %v", c.name, stream, err)
			}
			b, err := Normalize(compiled, c.names, stream)
			if err != nil {
				t.Fatalf("%s compiled %s: %v", c.name, stream, err)
			}
			if a != b {
				t.Fatalf("%s %s differs after normalization:\n%s\n---\n%s", c.name, stream, a, b)
			}
		}
	}
}

// The retained logging pair is the documented source-position defect: the
// wallclock rule cancels the five timestamps and nothing else, so
// `logging.go:40` against `main.go:24` stays a real mismatch.
func TestLoggingDefectStaysObservable(t *testing.T) {
	a := mustNormalize(t, string(fixture(t, "observations/logging.oracle.stderr.txt")), []string{"wallclock"}, "stderr")
	b := mustNormalize(t, string(fixture(t, "observations/logging.compiled.stderr.txt")), []string{"wallclock"}, "stderr")
	if a == b || !strings.Contains(a, "logging.go:40") || !strings.Contains(b, "main.go:24") {
		t.Fatalf("logging defect was cancelled:\n%s\n%s", a, b)
	}
	if strings.Replace(a, "logging.go:40", "main.go:24", 1) != b {
		t.Fatalf("only the source position may differ:\n%s\n%s", a, b)
	}
}

func TestTimeExampleShape(t *testing.T) {
	out := mustNormalize(t, string(fixture(t, "observations/time.oracle.stdout.txt")), []string{"wallclock"}, "stdout")
	want := `{"fixed":["2009-11-17 20:34:58.651387237 +0000 UTC","2009","November","17","20","34","58","651387237","UTC","Tuesday"],"comparisons":["true","false","false"],"duration_units":"consistent","additions":"consistent"}`
	if out != want {
		t.Fatalf("time example normalized to %s", out)
	}
	broken := strings.Replace(string(fixture(t, "observations/time.oracle.stdout.txt")), "530445847962032763", "530445847962032764", 1)
	if _, err := Normalize([]byte(broken), []string{"wallclock"}, "stdout"); err == nil || err.Error() != "time duration arithmetic" {
		t.Fatalf("inconsistent duration accepted: %v", err)
	}
}

func TestWallclockScan(t *testing.T) {
	text := "now 2026-09-12 04:34:13.123 +0000 UTC m=+0.000044210 at 1757651653 ms 1757651653123 ns 1757651653123456789 kitchen 4:34AM ansic Sat Sep 12 04:34:13 2026 mylog 2026/09/12 04:34:13 done\n"
	values := wallclockScan(text)
	want := []string{"2026-09-12 04:34:13.123 +0000 ", "m=+0.000044210", "1757651653", "1757651653123", "1757651653123456789", "4:34AM", "Sat Sep 12 04:34:13 2026", "2026/09/12 04:34:13 "}
	if strings.Join(values, "|") != strings.Join(want, "|") {
		t.Fatalf("scan produced %q", values)
	}
	out := mustNormalize(t, text, []string{"wallclock"}, "stdout")
	if !strings.Contains(out, `"types":["Time","String","Integer","Integer","Integer","Time","Time","Time"]`) {
		t.Fatalf("unexpected types: %s", out)
	}
	if !strings.Contains(out, "now <volatile:time:0>UTC <volatile:time:1> at <volatile:time:2> ms <volatile:time:3>") {
		t.Fatalf("unexpected shape: %s", out)
	}
	if _, err := Normalize([]byte("later 1757651653123 then 1757651653\n"), []string{"wallclock"}, "stdout"); err == nil || err.Error() != "wallclock order" {
		t.Fatalf("decreasing epoch accepted: %v", err)
	}
	if _, err := Normalize([]byte("no clock here\n"), []string{"wallclock"}, "stdout"); err == nil || err.Error() != "wallclock shape" {
		t.Fatalf("clockless output accepted: %v", err)
	}
	if got := mustNormalize(t, "It's a weekday\nIt's before noon\n", []string{"wallclock"}, "stdout"); got != "<volatile:day-class>\n<volatile:noon-class>\n" {
		t.Fatalf("switch example normalized to %q", got)
	}
	// Epoch runs keep the lookaround semantics: a run glued to a word or a dot
	// is not a reading, nor is one longer than nineteen digits.
	if v := wallclockScan("x1234567890 1234567890.5 12345678901234567890 1234567890"); strings.Join(v, "|") != "1234567890" {
		t.Fatalf("epoch boundaries: %q", v)
	}
}

func TestStreamAwareness(t *testing.T) {
	if got := mustNormalize(t, "0x1234 0xabc\n", []string{"pointer_address"}, "stderr"); got != "0x1234 0xabc\n" {
		t.Fatalf("stdout-only rule touched stderr: %q", got)
	}
	if got := mustNormalize(t, "0x1234 0xabc\n", []string{"pointer_address"}, "stdout"); got != "<ptr> <ptr>\n" {
		t.Fatalf("pointer_address: %q", got)
	}
	if got := mustNormalize(t, "", []string{"pointer_address", "wallclock"}, "stderr"); got != "" {
		t.Fatalf("empty stderr must stay empty: %q", got)
	}
	if _, err := Normalize([]byte("\xff\xfe"), []string{}, "stdout"); err == nil || err.Error() != "invalid UTF-8 stdout" {
		t.Fatalf("invalid UTF-8 accepted: %v", err)
	}
	if got := mustNormalize(t, "panic: boom\n\ngoroutine 1 [running]:\nmain.main()\n", []string{"panic_trace"}, "stderr"); got != "panic: boom\n\n" {
		t.Fatalf("panic_trace: %q", got)
	}
	if got := mustNormalize(t, "panic: boom\ngoroutine 1\n", []string{"panic_trace"}, "stdout"); got != "panic: boom\ngoroutine 1\n" {
		t.Fatalf("stderr-only rule touched stdout: %q", got)
	}
}

func TestPortsTmpPathsAndListings(t *testing.T) {
	if got := mustNormalize(t, "listening on :8090 and 127.0.0.1:54321 not :123456 nor :80a\n", []string{"ephemeral_port"}, "stdout"); got != "listening on :<port> and 127.0.0.1:<port> not :123456 nor :80a\n" {
		t.Fatalf("ephemeral_port: %q", got)
	}
	if got := mustNormalize(t, "/var/folders/x/sampledir123/file sample456\n", []string{"tmp_path"}, "stdout"); got != "<tmp>/file <tmp>\n" {
		t.Fatalf("tmp_path: %q", got)
	}
	if got := mustNormalize(t, "[/tmp/bin/prog foo bar]\nsecond\n", []string{"argv0_path"}, "stdout"); got != "[<argv0> foo bar]\nsecond\n" {
		t.Fatalf("argv0_path: %q", got)
	}
	if got := mustNormalize(t, "FOO:1\nBAR:\n\nZ\nA\n", []string{"env_listing"}, "stdout"); got != "FOO:1\nBAR:\n\nA\nZ\n" {
		t.Fatalf("env_listing: %q", got)
	}
	if got := mustNormalize(t, "total 0\ndrwxr-xr-x@ 4 qiangli  staff   128B Sep  9 06:36 .\n", []string{"file_metadata"}, "stdout"); got != "total 0\ndrwxr-xr-x <metadata> .\n" {
		t.Fatalf("file_metadata: %q", got)
	}
	if got := mustNormalize(t, "took 1.5ms and 20µs\n", []string{"duration"}, "stdout"); got != "{\"text\":\"took 1.5ms and 20µs\\n\",\"values\":[\"1.5ms\",\"20µs\"]}" {
		t.Fatalf("duration: %q", got)
	}
	if got := mustNormalize(t, "81,87\n0.6645600532184904\n5.166,6.9\n94,60\n94,60\n", []string{"random_stream"}, "stdout"); got != `{"shape":["int<100,int<100","float[0,1)","float[5,10),float[5,10)","seeded-pair","same-seeded-pair"],"tail":[94,60]}` {
		t.Fatalf("random_stream: %q", got)
	}
}

func TestInterleaveOrder(t *testing.T) {
	direct := "direct : 0\ndirect : 1\ndirect : 2\ngoroutine : 0\ngoing\ngoroutine : 1\ngoroutine : 2\ndone\n"
	if got := mustNormalize(t, direct, []string{"interleave_order"}, "stdout"); got != `{"prefix":["direct : 0\n","direct : 1\n","direct : 2\n"],"chains":[["goroutine : 0\n","goroutine : 1\n","goroutine : 2\n"],["going\n"]],"suffix":["done\n"]}` {
		t.Fatalf("direct: %s", got)
	}
	if _, err := Normalize([]byte(strings.Replace(direct, "going\n", "going\ngoing\n", 1)), []string{"interleave_order"}, "stdout"); err == nil {
		t.Fatal("extra interleaved output accepted")
	}
	workers := "Worker 1 starting\nWorker 3 starting\nWorker 2 starting\nWorker 5 starting\nWorker 4 starting\nWorker 1 done\nWorker 3 done\nWorker 2 done\nWorker 5 done\nWorker 4 done\n"
	if got := mustNormalize(t, workers, []string{"interleave_order"}, "stdout"); got != `{"workers":[[1,"starting","done"],[2,"starting","done"],[3,"starting","done"],[4,"starting","done"],[5,"starting","done"]]}` {
		t.Fatalf("workers: %s", got)
	}
	if _, err := Normalize([]byte(strings.Replace(workers, "Worker 4 done", "Worker 6 done", 1)), []string{"interleave_order"}, "stdout"); err == nil {
		t.Fatal("unlicensed worker id accepted")
	}
	pool := "worker 1 started  job 1\nworker 2 started  job 2\nworker 3 started  job 3\nworker 1 finished job 1\nworker 1 started  job 4\nworker 2 finished job 2\nworker 2 started  job 5\nworker 3 finished job 3\nworker 1 finished job 4\nworker 2 finished job 5\n"
	if got := mustNormalize(t, pool, []string{"interleave_order"}, "stdout"); got != `{"jobs":[1,2,3,4,5],"constraint":"same-worker start-before-finish"}` {
		t.Fatalf("pool: %s", got)
	}
}
