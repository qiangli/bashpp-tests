// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withRoot(t *testing.T) {
	t.Helper()
	ROOT = repoRoot(t)
	DOCS = ROOT + "/docs/go-by-example"
}

func rewrite(t *testing.T, src, dst string, edit func(lines []string) []string) {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	lines := edit(rubyLinesChomp(string(data)))
	if err := os.WriteFile(dst, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// repin re-derives the pin's data digest and row count for a mutated inventory,
// so a case probes the defect it names and not the pin's cross-check.
func repin(t *testing.T, inventory, dst string) {
	t.Helper()
	data, _ := os.ReadFile(inventory)
	var body strings.Builder
	rows := 0
	for _, line := range rubyLinesChomp(string(data)) {
		if !strings.HasPrefix(line, "#") && strings.TrimSpace(line) != "" {
			body.WriteString(line + "\n")
			rows++
		}
	}
	sum := sha256Hex([]byte(body.String()))
	rewrite(t, DOCS+"/pin.tsv", dst, func(lines []string) []string {
		for i, l := range lines {
			if strings.HasPrefix(l, "#") || l == "" {
				continue
			}
			f := strings.Split(l, "\t")
			f[6] = itoa(rows)
			f[7] = sum
			lines[i] = strings.Join(f, "\t")
		}
		return lines
	})
}

func runValidate(t *testing.T, env map[string]string) (int, string) {
	t.Helper()
	for _, k := range []string{"GBE_PIN", "GBE_INVENTORY", "GBE_CLASSIFICATION", "GBE_SCHEMA", "GBE_CORPUS"} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	for k, v := range env {
		t.Setenv(k, v)
	}
	t.Helper()
	r, w, _ := os.Pipe()
	saved := os.Stderr
	os.Stderr = w
	done := make(chan string)
	go func() {
		out, _ := io.ReadAll(r)
		done <- string(out)
	}()
	code := validateMain(nil, io.Discard)
	w.Close()
	os.Stderr = saved
	return code, <-done
}

func TestValidateAcceptsTheCheckedInCorpus(t *testing.T) {
	withRoot(t)
	if code, out := runValidate(t, nil); code != 0 {
		t.Fatalf("checked-in corpus rejected: %s", out)
	}
}

func TestValidateRejectsDefectClasses(t *testing.T) {
	withRoot(t)
	tmp := t.TempDir()
	inv := DOCS + "/inventory.tsv"
	cls := DOCS + "/classification.tsv"

	// same-count path substitution: only a set comparison sees it
	rewrite(t, inv, tmp+"/subst.tsv", func(lines []string) []string {
		for i, l := range lines {
			lines[i] = strings.Replace(l, "examples/arrays/arrays.go", "examples/arrays/arrayz.go", 1)
		}
		return lines
	})
	repin(t, tmp+"/subst.tsv", tmp+"/subst.pin")
	if code, out := runValidate(t, map[string]string{"GBE_INVENTORY": tmp + "/subst.tsv", "GBE_PIN": tmp + "/subst.pin"}); code == 0 || !strings.Contains(out, "present in inventory.tsv but not in") {
		t.Fatalf("substitution accepted: %d %s", code, out)
	}
	// transposed digests between two rows
	rewrite(t, inv, tmp+"/swap.tsv", func(lines []string) []string {
		var a, b int
		for i, l := range lines {
			if strings.HasPrefix(l, "examples/for/for.go\t") {
				a = i
			}
			if strings.HasPrefix(l, "examples/functions/functions.go\t") {
				b = i
			}
		}
		fa, fb := strings.Split(lines[a], "\t"), strings.Split(lines[b], "\t")
		fa[6], fb[6] = fb[6], fa[6]
		fa[7], fb[7] = fb[7], fa[7]
		lines[a], lines[b] = strings.Join(fa, "\t"), strings.Join(fb, "\t")
		return lines
	})
	repin(t, tmp+"/swap.tsv", tmp+"/swap.pin")
	if code, out := runValidate(t, map[string]string{"GBE_INVENTORY": tmp + "/swap.tsv", "GBE_PIN": tmp + "/swap.pin"}); code == 0 || !strings.Contains(out, "drift on examples/for/for.go") {
		t.Fatalf("transposition accepted: %d %s", code, out)
	}
	// deterministic row acquiring a volatile-value licence
	rewrite(t, cls, tmp+"/detnorm.cls", func(lines []string) []string {
		for i, l := range lines {
			if strings.HasPrefix(l, "examples/arrays/arrays.go\t") {
				lines[i] = strings.Replace(l, "\tdeterministic\tnone\tnone\t", "\tdeterministic\twallclock\tnone\t", 1)
			}
		}
		return lines
	})
	if code, out := runValidate(t, map[string]string{"GBE_CLASSIFICATION": tmp + "/detnorm.cls"}); code == 0 || !strings.Contains(out, "deterministic row must compare raw bytes") {
		t.Fatalf("permissive normalization accepted: %d %s", code, out)
	}
	// unlicensed normalization (the json row switched to wallclock)
	rewrite(t, cls, tmp+"/unlic.cls", func(lines []string) []string {
		for i, l := range lines {
			lines[i] = strings.Replace(l, "examples/json/json.go\tprogram\tmap_iteration\tmap_order\tnone\tnone", "examples/json/json.go\tprogram\tmap_iteration\twallclock\tnone\tnone", 1)
		}
		return lines
	})
	if code, out := runValidate(t, map[string]string{"GBE_CLASSIFICATION": tmp + "/unlic.cls"}); code == 0 || !strings.Contains(out, "normalization wallclock is not licensed by any declared behavior") {
		t.Fatalf("unlicensed normalization accepted: %d %s", code, out)
	}
	// failure-derived states are never classifications
	for _, token := range []string{"n/a", "planned", "skipped", "unsupported", "exception"} {
		rewrite(t, cls, tmp+"/na.cls", func(lines []string) []string {
			for i, l := range lines {
				if strings.HasPrefix(l, "examples/arrays/arrays.go\t") {
					f := strings.Split(l, "\t")
					f[2] = token
					lines[i] = strings.Join(f, "\t")
				}
			}
			return lines
		})
		if code, _ := runValidate(t, map[string]string{"GBE_CLASSIFICATION": tmp + "/na.cls"}); code == 0 {
			t.Fatalf("%q accepted as a classification", token)
		}
	}
	// a symlink standing in for a copied source, and an uninventoried file
	link := filepath.Join(tmp, "link")
	if err := copyTree(ROOT+"/examples", link+"/examples"); err != nil {
		t.Fatal(err)
	}
	os.Remove(link + "/examples/xml/xml.go")
	os.Symlink(ROOT+"/examples/xml/xml.go", link+"/examples/xml/xml.go")
	if code, out := runValidate(t, map[string]string{"GBE_CORPUS": link + "/examples"}); code == 0 || !strings.Contains(out, "present in inventory.tsv but not in the corpus tree") {
		t.Fatalf("symlink accepted: %d %s", code, out)
	}
	os.Remove(link + "/examples/xml/xml.go")
	copyFile(ROOT+"/examples/xml/xml.go", link+"/examples/xml/xml.go")
	os.WriteFile(link+"/examples/stray.txt", []byte("not reviewed\n"), 0o644)
	if code, out := runValidate(t, map[string]string{"GBE_CORPUS": link + "/examples"}); code == 0 || !strings.Contains(out, "present in the corpus tree but not in inventory.tsv") {
		t.Fatalf("stray file accepted: %d %s", code, out)
	}
	// pin drift
	rewrite(t, DOCS+"/pin.tsv", tmp+"/badcommit.pin", func(lines []string) []string {
		for i, l := range lines {
			lines[i] = strings.Replace(l, "7d705626375ba0263b616865a286e1587d6989c8", "7d705626375ba0263b616865a286e1587d6989c9", 1)
		}
		return lines
	})
	if code, out := runValidate(t, map[string]string{"GBE_PIN": tmp + "/badcommit.pin"}); code == 0 || !strings.Contains(out, "pin commit drifted") {
		t.Fatalf("pin drift accepted: %d %s", code, out)
	}
}

func TestCorpusPrimitives(t *testing.T) {
	withRoot(t)
	tmp := t.TempDir()
	os.WriteFile(tmp+"/a.txt", []byte("hello\n"), 0o644)
	os.MkdirAll(tmp+"/d", 0o755)
	os.Symlink("a.txt", tmp+"/d/link")
	snap, err := snapshot(tmp)
	if err != nil {
		t.Fatal(err)
	}
	if snap["a.txt"].Str("kind") != "file" || snap["d"].Str("kind") != "directory" || snap["d/link"].Str("target") != "a.txt" {
		t.Fatalf("snapshot: %v", snap)
	}
	if !nativeBinary("/bin/ls") {
		t.Fatal("/bin/ls must be recognised as native")
	}
	if nativeBinary(tmp + "/a.txt") {
		t.Fatal("a text file is not native")
	}
	stage, err := capture([]string{"/bin/sh", "-c", "echo out; echo err >&2; exit 3"}, tmp, tmp+"/logs/run", map[string]string{"PATH": ""}, Flt(5), os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	if !stage.Bool("spawned") || stage.Str("state") != "exited" || !deepEqual(stage.Get("exit"), Int(3)) || stage.Get("signal") != nil {
		t.Fatalf("capture: %s", Generate(stage))
	}
	if data, _ := os.ReadFile(stage.Obj("stdout").Str("path")); string(data) != "out\n" {
		t.Fatalf("stdout log: %q", data)
	}
	if got := Generate(stage.Obj("environment")); got != `{"PATH":""}` {
		t.Fatalf("environment: %s", got)
	}
	keys := stage.Keys()
	if strings.Join(keys, ",") != "argv,cwd,environment,timeout_seconds,spawned,state,exit,signal,descendants_survived,duration_seconds,lineage,stdout,stderr" {
		t.Fatalf("capture field order: %v", keys)
	}
	slow, err := capture([]string{"/bin/sleep", "5"}, tmp, tmp+"/logs/slow", map[string]string{}, Flt(0.2), os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	if slow.Str("state") != "deadline" || !deepEqual(slow.Get("signal"), Int(9)) {
		t.Fatalf("deadline: %s", Generate(slow))
	}
	if success(stage) || success(slow) {
		t.Fatal("success? must be false for exit 3 and for a deadline")
	}
	if !isRegularFile(tmp + "/logs/run.lineage.jsonl") {
		t.Fatal("lineage ledger not written")
	}
	// The generated driver for the test row is byte-stable.
	driver, err := testDriver([]byte("package main\n\nfunc TestA(t *testing.T) {}\nfunc BenchmarkB(b *testing.B) {}\n"), "x_test.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(driver, "\t\t\t{Name: \"TestA\", F: TestA},\n") || !strings.Contains(driver, "\t\t\t{Name: \"BenchmarkB\", F: BenchmarkB},\n") {
		t.Fatalf("driver: %s", driver)
	}
}
