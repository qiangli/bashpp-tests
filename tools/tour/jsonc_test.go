package main

import (
	"bufio"
	"os"
	"testing"
)

func TestCanonicalRoundTripsRubyLedgers(t *testing.T) {
	// The Go-produced executor ledger, the retired Ruby harness's candidate-002
	// executor ledger and its tour-evidence/v2 ledger: every line must re-render
	// to itself, or root digests across the port would not be comparable.
	for _, path := range []string{"../../tests/tour/executor-results.jsonl", "../../tests/tour/executor-results-published-candidate-002.jsonl", "../../tests/tour/evidence.jsonl"} {
		f, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 1<<20), 64<<20)
		n := 0
		for scanner.Scan() {
			line := scanner.Text()
			v, err := parseJSON([]byte(line))
			if err != nil {
				t.Fatalf("%s line %d: %v", path, n+1, err)
			}
			if got := canonical(v); got != line {
				t.Fatalf("%s line %d differs:\n got %.300s\nwant %.300s", path, n+1, got, line)
			}
			n++
		}
		f.Close()
		t.Logf("%s: %d lines round-trip", path, n)
	}
}

func TestRubyFloat(t *testing.T) {
	cases := map[float64]string{510: "510.0", 0.5: "0.5", 1788935979.5653892: "1788935979.5653892", 0.0001: "0.0001", 0.00001: "1.0e-05", 1e16: "1.0e+16", 1e15: "1000000000000000.0", 123456789012345680.0: "1.2345678901234568e+17", -2.5: "-2.5", 100: "100.0", 12.75: "12.75"}
	for f, want := range cases {
		if got := rubyFloat(f); got != want {
			t.Errorf("rubyFloat(%v) = %q want %q", f, got, want)
		}
	}
	if got := inspect([]string{"a\"b", "c\n"}); got != `["a\"b", "c\n"]` {
		t.Errorf("inspect = %s", got)
	}
}
