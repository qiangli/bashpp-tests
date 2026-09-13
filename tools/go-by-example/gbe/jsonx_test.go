// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
package main

import (
	"math"
	"testing"
)

// Float#to_s renderings measured against Ruby: fixed inside 1e-4..1e16,
// exponential outside, always with a fractional digit.
func TestRubyFloat(t *testing.T) {
	cases := map[float64]string{
		0: "0.0", 1: "1.0", 20: "20.0", 0.1: "0.1", 0.5: "0.5", 1e15: "1000000000000000.0", 1e16: "1.0e+16",
		1234.5: "1234.5", 0.0001: "0.0001", 0.00001: "1.0e-05", 8840764.132700546: "8840764.132700546",
		0.012345678: "0.012345678", -2.5: "-2.5", 123456789.123: "123456789.123", 1.5e-7: "1.5e-07", 1e100: "1.0e+100",
	}
	for f, want := range cases {
		if got := rubyFloat(f); got != want {
			t.Errorf("rubyFloat(%v) = %q, want %q", f, got, want)
		}
	}
	if got := rubyFloat(math.Copysign(0, -1)); got != "-0.0" {
		t.Errorf("negative zero: %q", got)
	}
}

// JSON.generate escapes only quotes, backslashes and C0 controls, keeps
// insertion order, and distinguishes 20 from 20.0.
func TestGenerateMatchesRubyJSON(t *testing.T) {
	o := Obj("b", "x\"y\\z\n\t\x01/é ", "a", Int(20), "f", Flt(20), "n", nil, "t", true, "arr", []any{Int(1), "two"}, "e", []string{})
	want := "{\"b\":\"x\\\"y\\\\z\\n\\t\\u0001/é \",\"a\":20,\"f\":20.0,\"n\":null,\"t\":true,\"arr\":[1,\"two\"],\"e\":[]}"
	if got := Generate(o); got != want {
		t.Fatalf("Generate = %s\nwant       %s", got, want)
	}
	parsed, err := ParseObject([]byte(want))
	if err != nil {
		t.Fatal(err)
	}
	if got := Generate(parsed); got != want {
		t.Fatalf("round trip = %s", got)
	}
	if n, ok := parsed.Get("f").(Number); !ok || !n.Float {
		t.Fatal("20.0 must parse as a Float")
	}
	if n, ok := parsed.Get("a").(Number); !ok || n.Float {
		t.Fatal("20 must parse as an Integer")
	}
	big, err := Parse([]byte("[12345678901234567890123, 1e2, \"\\ud83d\\ude00\", \"\\/\"]"))
	if err != nil {
		t.Fatal(err)
	}
	if got := Generate(big); got != "[12345678901234567890123,100.0,\"\U0001F600\",\"/\"]" {
		t.Fatalf("big/exp/surrogate = %s", got)
	}
	if Canonical(Obj("z", Int(1), "a", Obj("y", Int(2), "b", Int(3)))) != `{"a":{"b":3,"y":2},"z":1}` {
		t.Fatal("canonical must sort keys recursively")
	}
	if Pretty(Obj("failures", []any{}, "x", Obj())) != "{\n  \"failures\": [\n\n  ],\n  \"x\": {}\n}" {
		t.Fatalf("pretty = %q", Pretty(Obj("failures", []any{}, "x", Obj())))
	}
}

func TestObjectOrderOperations(t *testing.T) {
	o := Obj("a", Int(1), "b", Int(2), "c", nil)
	o.Set("a", Int(9))
	o.Delete("b")
	o.Set("b", Int(3))
	if got := Generate(o.Compact()); got != `{"a":9,"b":3}` {
		t.Fatalf("order after delete/append: %s", got)
	}
	if got := Generate(o.Without("a")); got != `{"c":null,"b":3}` {
		t.Fatalf("without: %s", got)
	}
	if !deepEqual(Obj("a", Int(1), "b", Flt(2)), Obj("b", Int(2), "a", Int(1))) {
		t.Fatal("hash equality must ignore order and coerce numerics")
	}
}
