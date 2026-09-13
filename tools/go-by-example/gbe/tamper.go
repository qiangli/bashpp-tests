// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Genuine fail-closed mutations, ported from tools/go-by-example/
// tamper-tests.sh (with its inline Ruby), tamper-retained-evidence.rb and
// bounded-evidence-selftests.rb. Each case changes a real checked-in input,
// the real gate source, a real candidate manifest, or a real evidence
// document, and then enters the normal production path; there are no
// diagnosis hooks and nothing asserts an outcome into existence.
//
// Phase A mutates provisioning, the candidate binding and the gate itself.
// Phase B mutates a complete evidence document.
//
// The executor pin is gone. Authority is a reviewed candidates.tsv row plus a
// `--candidate` manifest that must equal it, so the negatives below cover the
// whole candidate: manifest bytes, launcher, payload, front-end version, build
// recipe, SDK identity and every runtime repository commit.
package main

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// evidenceRel is the historical location of the committed evidence chain
// Phase B mutates; GBE_EVIDENCE names another authenticated document.
const evidenceRel = "tests/go-by-example/sprint118-story3-candidate001.jsonl.fail"

type tamperSuite struct {
	root      string
	work      string
	candidate string
	bashy     string
	pass      int
}

func (t *tamperSuite) fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.RemoveAll(t.work)
	os.Exit(1)
}

func headLines(text string, n int) string {
	lines := rubyLines(text)
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "")
}

// command runs argv with the given extra environment (and removed keys),
// returning combined output and success.
func (t *tamperSuite) command(extraEnv []string, unset []string, argv ...string) (string, bool) {
	cmd := exec.Command(argv[0], argv[1:]...)
	var env []string
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		skip := contains(unset, key)
		for _, e := range extraEnv {
			if k, _, _ := strings.Cut(e, "="); k == key {
				skip = true
			}
		}
		if !skip {
			env = append(env, kv)
		}
	}
	cmd.Env = append(env, extraEnv...)
	out, err := cmd.CombinedOutput()
	return string(out), err == nil
}

func (t *tamperSuite) expectFail(name, marker string, extraEnv []string, unset []string, argv ...string) {
	out, ok := t.command(extraEnv, unset, argv...)
	if ok {
		fmt.Fprint(os.Stderr, headLines(out, 8))
		t.fail("FAIL %s accepted", name)
	}
	if !strings.Contains(out, marker) {
		fmt.Fprint(os.Stderr, headLines(out, 12))
		t.fail("FAIL %s wrong diagnosis", name)
	}
	t.pass++
	fmt.Println("PASS " + name)
}

func (t *tamperSuite) expectOK(name string, extraEnv []string, argv ...string) {
	out, ok := t.command(extraEnv, nil, argv...)
	if !ok {
		fmt.Fprint(os.Stderr, headLines(out, 20))
		t.fail("FAIL %s rejected", name)
	}
	t.pass++
	fmt.Println("PASS " + name)
}

// copyTree is `cp -R src dst` for a repository checkout, minus .git and the
// build cache (each copy rebuilds its own binary from its own sources).
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		if rel == "." {
			return os.MkdirAll(dst, 0o755)
		}
		if path != src && (rel == ".git" || rel == ".cache") {
			return filepath.SkipDir
		}
		target := filepath.Join(dst, rel)
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		case info.IsDir():
			return os.MkdirAll(target, info.Mode().Perm()|0o700)
		default:
			return copyFile(path, target)
		}
	})
}

func (t *tamperSuite) copyRepo(name string) string {
	dst := filepath.Join(t.work, name)
	if err := copyTree(t.root, dst); err != nil {
		t.fail("cannot copy repository to %s: %v", dst, err)
	}
	return dst
}

func (t *tamperSuite) copyFrom(src, name string) string {
	dst := filepath.Join(t.work, name)
	if err := copyTree(src, dst); err != nil {
		t.fail("cannot copy %s to %s: %v", src, dst, err)
	}
	return dst
}

func gateWrapper(repo string) string { return repo + "/tools/go-by-example/gate.sh" }
func gbeWrapper(repo string) string  { return repo + "/tools/go-by-example/gbe.sh" }

func mustRead(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		fatal(err.Error())
	}
	return string(data)
}

func mustWrite(path, text string) {
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		fatal(err.Error())
	}
}

// recandidate rewrites one field of a private repository copy's reviewed
// candidate rows. A caller-supplied manifest is deliberately powerless on its
// own: authority is the row in the reviewed repository, and the manifest has
// to equal it.
func recandidate(repo string, edit func(fields []string)) {
	table := repo + "/docs/go-by-example/candidates.tsv"
	var out []string
	for _, line := range rubyLinesChomp(mustRead(table)) {
		if !strings.HasPrefix(line, "#") && line != "" {
			fields := strings.Split(line, "\t")
			edit(fields)
			line = strings.Join(fields, "\t")
		}
		out = append(out, line)
	}
	mustWrite(table, strings.Join(out, "\n")+"\n")
}

// rewriteManifest writes a modified copy of the candidate manifest and
// re-points every reviewed row at it (JSON.pretty_generate + "\n").
func rewriteManifest(repo, source, dest string, editManifest func(m *Object), editRow func(fields []string)) {
	manifest, err := ParseObject([]byte(mustRead(source)))
	if err != nil {
		fatal("candidate manifest is not valid JSON")
	}
	editManifest(manifest)
	mustWrite(dest, Pretty(manifest)+"\n")
	sum := sha(dest)
	recandidate(repo, func(fields []string) {
		fields[2] = sum
		editRow(fields)
	})
}

func replaceOnce(source *string, old, replacement string) {
	if !strings.Contains(*source, old) {
		if len(old) > 60 {
			old = old[:60]
		}
		fatal("mutation target absent: " + old)
	}
	*source = strings.Replace(*source, old, replacement, 1)
}

// --- Phase A ------------------------------------------------------------------

func (t *tamperSuite) phaseA(gateEnv []string) {
	W, CANDIDATE, BASHY := t.work, t.candidate, t.bashy
	repo := t.copyRepo("repo")
	SGATE := gateWrapper(repo)
	skip := append([]string{"GBE_SKIP_INTEGRITY=1"}, gateEnv...)

	inventory := mustRead(t.root + "/docs/go-by-example/inventory.tsv")
	var count []string
	for _, line := range rubyLinesChomp(inventory) {
		if strings.HasPrefix(line, "examples/arrays/arrays.go\t") {
			continue
		}
		count = append(count, line)
	}
	mustWrite(W+"/count", strings.Join(count, "\n")+"\n")
	t.expectFail("missing_real_row", "expected exactly 85",
		append([]string{"GBE_INVENTORY=" + W + "/count"}, skip...), nil, SGATE, "--candidate", CANDIDATE, "--bashy", BASHY)

	mustWrite(W+"/source-hash", strings.Replace(inventory, "9b23202e", "0b23202e", 1))
	t.expectFail("mutated_source_binding", "source changed during gate",
		append([]string{"GBE_INVENTORY=" + W + "/source-hash"}, skip...), nil, SGATE, "--candidate", CANDIDATE, "--bashy", BASHY)

	// An adapter is a claim about a control the gate performs. Registering one
	// the gate cannot exercise is the exact `fake_clock`/`seeded_random` defect.
	mustWrite(W+"/schema", mustRead(t.root+"/docs/go-by-example/behavior-schema.tsv")+"adapter\tunimplemented_real_adapter\t-\tmutation\n")
	t.expectFail("mutated_adapter_configuration", "adapter registry differs from schema",
		append([]string{"GBE_SCHEMA=" + W + "/schema"}, skip...), nil, SGATE, "--candidate", CANDIDATE, "--bashy", BASHY)

	// Exact deterministic output may not acquire a volatile-value license.
	permissive := func(text string) string {
		var out []string
		for _, line := range rubyLinesChomp(text) {
			if strings.Contains(line, "examples/arrays/arrays.go") {
				line = strings.Replace(line, "\tdeterministic\tnone\tnone\t", "\tdeterministic\twallclock\tnone\t", 1)
			}
			out = append(out, line)
		}
		return strings.Join(out, "\n") + "\n"
	}
	mustWrite(W+"/permissive-classification", permissive(mustRead(t.root+"/docs/go-by-example/classification.tsv")))
	mustWrite(W+"/permissive-inventory", permissive(inventory))
	t.expectFail("permissive_normalization", "deterministic row must compare raw bytes",
		[]string{"GBE_CLASSIFICATION=" + W + "/permissive-classification", "GBE_INVENTORY=" + W + "/permissive-inventory"}, nil,
		t.root+"/tools/go-by-example/validate.sh")

	// --- candidate binding negatives ---
	// There is no default candidate: a gate that ran whatever was on PATH would
	// be reporting on an unidentified product.
	t.expectFail("no_default_candidate", "there is no default candidate", skip, []string{"GBE_CANDIDATE"}, SGATE, "--bashy", BASHY)

	// A manifest is a selection, not an introduction. One changed byte and it is
	// no longer the manifest the repository reviewed.
	forged := strings.Replace(mustRead(CANDIDATE), `"frontend_version": "gosource-v1"`, `"frontend_version": "gosource-v2"`, 1)
	if forged == mustRead(CANDIDATE) {
		t.fail("FAIL forged manifest is identical")
	}
	mustWrite(W+"/forged-candidate.json", forged)
	t.expectFail("unreviewed_candidate_manifest", "candidate manifest is not the repository-reviewed manifest",
		skip, nil, SGATE, "--candidate", W+"/forged-candidate.json", "--bashy", BASHY)

	// The launcher is selected by path and authenticated by digest.
	t.expectFail("mutated_candidate_launcher", "digest mismatch", skip, nil, SGATE, "--candidate", CANDIDATE, "--bashy", "/bin/echo")

	// A zeroed or self-identical digest is not a reviewed artifact.
	zeroRepo := t.copyRepo("zero-repo")
	recandidate(zeroRepo, func(f []string) { f[3] = strings.Repeat("0", 64) })
	t.expectFail("unprovisioned_candidate", "invalid reviewed candidate launcher_sha256",
		skip, nil, gateWrapper(zeroRepo), "--candidate", CANDIDATE, "--bashy", BASHY)

	sameRepo := t.copyRepo("same-repo")
	recandidate(sameRepo, func(f []string) { f[4] = f[3] })
	t.expectFail("launcher_is_not_its_own_payload", "launcher and payload digests are identical",
		skip, nil, gateWrapper(sameRepo), "--candidate", CANDIDATE, "--bashy", BASHY)

	// The candidate and the oracle must come from the SAME reviewed Go release.
	// The row's recipe pins the release too (either as GOTOOLCHAIN=goX or as the
	// authenticated toolchain PATH), so the whole row is moved to go1.26.0: the
	// refusal under test is the identity comparison against toolchain.tsv, not a
	// recipe that no longer pins the release it names.
	repo126 := t.copyRepo("repo126")
	recandidate(repo126, func(f []string) {
		f[6] = "go version go1.26.0 darwin/arm64"
		f[7] = strings.ReplaceAll(f[7], "go1.27.0", "go1.26.0")
	})
	t.expectFail("go126_candidate_pin_rejected", "is not the reviewed toolchain",
		skip, nil, gateWrapper(repo126), "--candidate", CANDIDATE, "--bashy", BASHY)

	// A default build is permitted when reviewed, but changing the reviewed
	// recipe without changing its authenticated manifest remains a mismatch.
	defaultCLI := t.copyRepo("default-cli-repo")
	recandidate(defaultCLI, func(f []string) { f[7] = "GOTOOLCHAIN=go1.27.0 make build" })
	t.expectFail("mismatched_default_cli_build_recipe", "candidate manifest build_recipe differs from the reviewed table",
		skip, nil, gateWrapper(defaultCLI), "--candidate", CANDIDATE, "--bashy", BASHY)

	// Every replaced runtime dependency is bound, filebrowser included. Dropping
	// one from the reviewed row makes the real manifest stop matching it.
	partial := t.copyRepo("partial-repo")
	recandidate(partial, func(f []string) {
		f[8] = "bashy=92985238a12547b28de74dfcc9bbd5d96abec464;coreutils=ec91ea4560a556c8217117bf7cb24e79f53e54f0;readline=b958823bd7075ed8b9a3aedd351422356a95fe79;sh=9c14f863b1352242a6abfaf2a30cd6ced06751d9"
	})
	t.expectFail("incomplete_runtime_dependencies", "repository set differs from the reviewed runtime dependencies",
		skip, nil, gateWrapper(partial), "--candidate", CANDIDATE, "--bashy", BASHY)

	// A runtime dependency pinned to a different commit is refused by the shared
	// corpus revision check, not by a second implementation of it here.
	wrongCommit := t.copyRepo("wrong-commit-repo")
	fake := strings.Repeat("0", 39) + "1"
	rewriteManifest(wrongCommit, CANDIDATE, W+"/wrong-commit.json",
		func(m *Object) {
			for _, r := range m.Arr("repositories") {
				repo := r.(*Object)
				if filepath.Base(repo.Str("path")) == "filebrowser" {
					repo.Set("commit", fake)
				}
			}
		},
		func(f []string) {
			f[8] = regexp.MustCompile(`filebrowser=[0-9a-f]{40}`).ReplaceAllLiteralString(f[8], "filebrowser="+fake)
		})
	t.expectFail("candidate_revision_mismatch", "candidate revision mismatch",
		skip, nil, gateWrapper(wrongCommit), "--candidate", W+"/wrong-commit.json", "--bashy", BASHY)

	// The compiled mode needs the lowering runtime the candidate was built from.
	// It is not provisioned out of band through GBE_SH_MODULE -- an
	// unauthenticated environment path -- so its absence is a candidate defect,
	// never a silently skipped third mode.
	noSh := t.copyRepo("no-sh-repo")
	rewriteManifest(noSh, CANDIDATE, W+"/no-sh.json",
		func(m *Object) {
			var kept []any
			for _, r := range m.Arr("repositories") {
				if filepath.Base(r.(*Object).Str("path")) != "sh" {
					kept = append(kept, r)
				}
			}
			m.Set("repositories", kept)
		},
		func(f []string) {
			var kept []string
			for _, p := range strings.Split(f[8], ";") {
				if !strings.HasPrefix(p, "sh=") {
					kept = append(kept, p)
				}
			}
			f[8] = strings.Join(kept, ";")
		})
	t.expectFail("missing_sh_module", "declares no mvdan.cc/sh/v3 lowering runtime",
		skip, nil, gateWrapper(noSh), "--candidate", W+"/no-sh.json", "--bashy", BASHY)

	// The independent candidate validator reaches the same refusals from the
	// table alone, with no gate run behind it.
	t.expectOK("candidate_validator_authenticates", nil,
		gbeWrapper(t.root), "validate-candidate", "--candidate", CANDIDATE, "--bashy", BASHY)
	t.expectFail("candidate_validator_rejects_forgery", "candidate manifest is not the repository-reviewed manifest",
		nil, nil, gbeWrapper(t.root), "validate-candidate", "--candidate", W+"/forged-candidate.json", "--bashy", BASHY)
	t.expectFail("go126_candidate_validator_rejected", "is not the reviewed toolchain",
		nil, nil, gbeWrapper(repo126), "validate-candidate", "--candidate", CANDIDATE, "--bashy", BASHY)

	// --- gate source mutations ---
	// These narrow a private copy to one genuine inventory row and change
	// exactly one production behaviour. Authentication still runs first;
	// nothing in the cleanup, record or publication path is weakened and no
	// line asserts a state.
	MROOT := t.copyRepo("production-mutations")
	mutatedGate := func(name, mutation, row string, runTimeout, cleanupTimeout string) string {
		repo := t.copyFrom(MROOT, "gate-"+name)
		result := W + "/result-" + name + ".jsonl"
		path := repo + "/tools/go-by-example/gbe/gate.go"
		s := mustRead(path)
		replaceOnce(&s, "\tdenominator := len(rows) * len(MODES)",
			"\t{\n\t\tvar kept [][]string\n\t\tfor _, r := range rows {\n\t\t\tif strings.Contains(r[0], "+rubyInspect(row)+") {\n\t\t\t\tkept = append(kept, r)\n\t\t\t}\n\t\t}\n\t\tif len(kept) == 0 {\n\t\t\tfatal(\"mutation selected no row\")\n\t\t}\n\t\trows = kept\n\t}\n\tdenominator := len(rows) * len(MODES)")
		replaceOnce(&s, "\tif len(rows) != 85 {\n\t\tfatal(fmt.Sprintf(\"expected exactly 85 program rows, got %d\", len(rows)))\n\t}\n", "")
		compiled := "\t\t\t\tif b, ok := binaries[\"compiled\"]; ok {\n\t\t\t\t\tcommand = append([]string{b}, args...)\n\t\t\t\t}"
		interpreted := "\t\t\t\tcommand = append([]string{BASHY, \"--bashpp\", \"--source=go\"}, sourceArguments[\"interpreted\"]...)"
		switch mutation {
		case "spawn_error":
			replaceOnce(&s, compiled, "\t\t\t\tcommand = append([]string{ROOT + \"/definitely-missing-executable\"}, args...)")
		case "timeout":
			replaceOnce(&s, compiled, "\t\t\t\tcommand = []string{\"/bin/sleep\", \"5\"}")
		case "leak":
			// A genuine survivor, not a forced state: the command exits 0 after
			// putting a descendant in its own session, so the process-group
			// TERM/KILL capture performs provably cannot reach it and kill(0, -pgid)
			// cannot see it. Only the inherited liveness descriptor still observes it.
			replaceOnce(&s, compiled, "\t\t\t\tcommand = []string{selfExecutable(), \"leak-descendant\"}")
		case "flattened_assets":
			// The pre-Sprint-118 defect: copy required assets by basename. `//go:embed
			// folder/single_file.txt` then has nothing to embed and the oracle build
			// fails, which is the whole reason relative paths must be preserved.
			replaceOnce(&s, "\t\ttarget := filepath.Join(dir, asset[len(exampleDir)+1:])", "\t\ttarget := filepath.Join(dir, filepath.Base(asset))")
		case "effect_blind":
			// stdout, stderr and status all agree with the oracle; only the
			// filesystem effect differs. Without a compared effect channel this is
			// invisible.
			replaceOnce(&s, interpreted, "\t\t\t\tcommand = []string{\"/bin/sh\", \"-c\", \"\\\"$0\\\" \\\"$@\\\"; : > gate-mutation-residue\", binaries[\"oracle\"]}")
		default:
			fatal("unknown mutation")
		}
		mustWrite(path, s)
		env := append([]string{"GBE_SKIP_INTEGRITY=1", "GBE_ROW_TIMEOUT=" + envOr("GBE_ROW_TIMEOUT", "240"),
			"GBE_RUN_TIMEOUT=" + runTimeout, "GBE_CLEANUP_TIMEOUT=" + cleanupTimeout}, gateEnv...)
		out, ok := t.command(env, nil, gateWrapper(repo), "--candidate", CANDIDATE, "--bashy", BASHY, "--evidence", result)
		mustWrite(W+"/"+name+".log", out)
		if ok {
			t.fail("FAIL %s production mutation passed", name)
		}
		if !isRegularFile(result + ".fail") {
			fmt.Fprint(os.Stderr, headLines(out, 12))
			t.fail("FAIL %s produced no FAIL evidence", name)
		}
		return result + ".fail"
	}
	checkAttempt := func(evidence, mode, field, want string) {
		rows, err := readEvidence(evidence)
		if err != nil {
			t.fail("FAIL %s: unreadable evidence", evidence)
		}
		var attempt *Object
		for _, r := range rows {
			if r.Str("type") == "attempt" && r.Str("mode") == mode {
				attempt = r
				break
			}
		}
		if attempt == nil {
			t.fail("no %s attempt", mode)
		}
		got := ""
		switch v := attempt.Get(field).(type) {
		case string:
			got = v
		case Number:
			got = v.String()
		case nil:
			got = ""
		default:
			got = Generate(v)
		}
		if got != want {
			t.fail("%s is %s, want %s", field, rubyInspect(got), rubyInspect(want))
		}
		s := rows[len(rows)-1]
		if s.Str("type") != "summary" || s.Str("verdict") != "fail" {
			t.fail("mutation did not publish an honest red summary")
		}
	}

	for _, spec := range [][2]string{{"spawn_error", "unspawned"}, {"timeout", "timeout"}} {
		name, want := spec[0], spec[1]
		ev := mutatedGate(name, name, "hello-world", "1", envOr("MUT_CLEANUP_TIMEOUT", "2"))
		checkAttempt(ev, "compiled", "state", want)
		t.pass++
		fmt.Println("PASS " + name)
	}
	// The leak fixture is this binary's own leak-descendant subcommand -- a
	// native program that needs no PATH -- run on the row whose declared
	// behavior provisions one, as the shell-script fixture it replaces was.
	ev := mutatedGate("leak", "leak", "spawning-processes", "8", ".25")
	checkAttempt(ev, "compiled", "state", "leak")
	t.pass++
	fmt.Println("PASS leak")

	ev = mutatedGate("flattened_assets", "flattened_assets", "embed-directive", envOr("MUT_RUN_TIMEOUT", "20"), envOr("MUT_CLEANUP_TIMEOUT", "2"))
	checkAttempt(ev, "oracle", "state", "unspawned")
	t.pass++
	fmt.Println("PASS flattened_assets")

	ev = mutatedGate("effect_blind", "effect_blind", "hello-world", envOr("MUT_RUN_TIMEOUT", "20"), envOr("MUT_CLEANUP_TIMEOUT", "2"))
	checkAttempt(ev, "interpreted", "verdict", "fail_effects")
	t.pass++
	fmt.Println("PASS effect_blind")
}

// --- Phase B -----------------------------------------------------------------

// rebind rewrites every self-hash and the root after an edit, so only
// independent derivation from raw bytes and reviewed tables can reject the
// document.
func rebind(rows []*Object) {
	manifest, attempts, summary := rows[0], rows[1:len(rows)-1], rows[len(rows)-1]
	binding := sha256Hex([]byte(Generate(manifest)))
	for _, a := range attempts {
		if a.Has("binding_sha256") {
			a.Set("binding_sha256", binding)
		}
		a.Delete("evidence_sha256")
		a.Set("evidence_sha256", sha256Hex([]byte(Generate(a))))
	}
	body := summary.Without("root_digest")
	chain := []string{binding}
	for _, a := range attempts {
		chain = append(chain, a.Str("evidence_sha256"))
	}
	chain = append(chain, sha256Hex([]byte(Generate(body))))
	summary.Set("root_digest", sha256Hex([]byte(strings.Join(chain, "\n"))))
}

func writeRows(path string, rows []*Object) {
	var b strings.Builder
	for _, r := range rows {
		b.WriteString(Generate(r))
		b.WriteString("\n")
	}
	mustWrite(path, b.String())
}

func findAttempt(rows []*Object, pred func(*Object) bool) *Object {
	for _, r := range rows {
		if r.Str("type") == "attempt" && pred(r) {
			return r
		}
	}
	return nil
}

func (t *tamperSuite) phaseB() {
	W := t.work
	evidence := os.Getenv("GBE_EVIDENCE")
	if evidence == "" {
		evidence = t.root + "/" + evidenceRel
	}
	evidenceAbs, err := realPath(evidence)
	if err != nil {
		t.fail("FAIL committed evidence chain is missing: %s", evidence)
	}
	// The document is addressed relative to each repository copy when it lives
	// inside the repository, and by its absolute anchored path otherwise.
	locate := func(repo string) string {
		if strings.HasPrefix(evidenceAbs, t.root+"/") {
			return repo + "/" + evidenceAbs[len(t.root)+1:]
		}
		return evidenceAbs
	}
	PROD := t.copyRepo("prod")
	PRODUCTION := locate(PROD)
	if !isRegularFile(PRODUCTION) {
		t.fail("FAIL committed evidence chain is missing: %s", evidence)
	}
	validator := func(repo string) []string { return []string{gbeWrapper(repo), "validate-evidence"} }
	run := func(repo string, args ...string) []string { return append(validator(repo), args...) }
	t.expectOK("committed_evidence_is_authenticated", nil, run(PROD, PRODUCTION)...)

	load := func() []*Object {
		rows, err := readEvidence(PRODUCTION)
		if err != nil {
			t.fail("FAIL cannot parse %s", PRODUCTION)
		}
		return rows
	}

	// A fully self-consistent GREEN document with every hash recomputed still
	// has no reviewed production root behind it.
	{
		rows := load()
		manifest, attempts, summary := rows[0], rows[1:len(rows)-1], rows[len(rows)-1]
		for start := 0; start+3 <= len(attempts); start += 3 {
			oracle := attempts[start]
			for _, a := range attempts[start+1 : start+3] {
				for _, k := range []string{"raw_stdout_b64", "raw_stderr_b64", "normalized_stdout_b64", "normalized_stderr_b64", "exit", "effects_sha256", "effects_delta"} {
					a.Set(k, oracle.Get(k))
				}
				a.Set("spawned", true)
				a.Set("state", "complete")
				a.Set("verdict", "pass")
				stages := stageList(a)
				last := stages[len(stages)-1]
				last.Set("spawned", true)
				last.Set("state", "complete")
				last.Set("exit", oracle.Get("exit"))
			}
		}
		// A source document that is already green would reproduce its own
		// anchored root; the invented chain records an observation nobody made
		// so that its self-consistency is the only thing vouching for it.
		for _, a := range attempts {
			a.Set("detail", "invented")
		}
		for _, a := range attempts {
			a.Delete("evidence_sha256")
			a.Set("evidence_sha256", sha256Hex([]byte(Generate(a))))
		}
		summary.Set("verdict", "pass")
		summary.Set("executed", Int(int64(len(attempts))))
		summary.Set("missing_or_unspawned", Int(0))
		summary.Set("failures", []any{})
		body := summary.Without("root_digest")
		chain := []string{sha256Hex([]byte(Generate(manifest)))}
		for _, a := range attempts {
			chain = append(chain, a.Str("evidence_sha256"))
		}
		chain = append(chain, sha256Hex([]byte(Generate(body))))
		summary.Set("root_digest", sha256Hex([]byte(strings.Join(chain, "\n"))))
		writeRows(W+"/invented.jsonl.pass", rows)
	}
	t.expectFail("self_hashes_are_not_authentication", "evidence root is not anchored", nil, nil, run(PROD, W+"/invented.jsonl.pass")...)

	// Mutations of the committed document. Each helper recomputes every
	// attacker-controlled self-hash and the public root, so only independent
	// derivation from raw bytes and reviewed tables can reject them.
	mutate := func(name string, edit func(rows []*Object)) string {
		dest := W + "/" + name + ".fail"
		rows := load()
		edit(rows)
		writeRows(dest, rows)
		return dest
	}
	first := func(rows []*Object) *Object { return rows[0] }
	lastRow := func(rows []*Object) *Object { return rows[len(rows)-1] }

	// Structural: same record count, but a mode/row pairing that never happened.
	d := mutate("missing-mode", func(rows []*Object) { rows[1] = deepCopy(rows[2]).(*Object); rebind(rows) })
	t.expectFail("missing_mode_evidence", "missing, duplicate, reordered, or foreign row/mode evidence", nil, nil, run(PROD, d)...)
	d = mutate("missing-row", func(rows []*Object) {
		for i := 0; i < 3; i++ {
			rows[1+i] = deepCopy(rows[4+i]).(*Object)
		}
		rebind(rows)
	})
	t.expectFail("missing_row_evidence", "missing, duplicate, reordered, or foreign row/mode evidence", nil, nil, run(PROD, d)...)

	// Self-hash left stale: the cheapest forgery of all.
	{
		lines := rubyLines(mustRead(PRODUCTION))
		if len(lines) > 1 {
			lines[1] = strings.Replace(lines[1], `"spawned":true`, `"spawned":false`, 1)
		}
		mustWrite(W+"/tampered.fail", strings.Join(lines, ""))
	}
	t.expectFail("result_tampering", "result tampering detected", nil, nil, run(PROD, W+"/tampered.fail")...)

	// Raw bytes changed, stale normalized bytes retained (and the reverse).
	arraysOracle := func(rows []*Object) *Object {
		r := findAttempt(rows, func(x *Object) bool { return x.Str("path") == "examples/arrays/arrays.go" && x.Str("mode") == "oracle" })
		if r == nil {
			t.fail("arrays oracle absent")
		}
		return r
	}
	d = mutate("arrays-stale-normalized", func(rows []*Object) {
		arraysOracle(rows).Set("raw_stdout_b64", b64([]byte("attacker-controlled arrays output\n")))
		rebind(rows)
	})
	t.expectFail("arrays_raw_stale_normalized", "stored normalized output differs from independently recomputed bytes: examples/arrays/arrays.go:oracle", nil, nil, run(PROD, d)...)
	d = mutate("arrays-stale-raw", func(rows []*Object) {
		arraysOracle(rows).Set("normalized_stdout_b64", b64([]byte("attacker-preferred comparator input\n")))
		rebind(rows)
	})
	t.expectFail("arrays_stale_raw_for_normalized", "stored normalized output differs from independently recomputed bytes: examples/arrays/arrays.go:oracle", nil, nil, run(PROD, d)...)

	// A comparator may not wave a mismatch through by rewriting its own verdict
	// -- nor invent one where the derivation says pass.
	d = mutate("permissive-comparator", func(rows []*Object) {
		if r := findAttempt(rows, func(x *Object) bool { return x.Str("verdict") != "pass" }); r != nil {
			r.Set("verdict", "pass")
		} else {
			findAttempt(rows, func(x *Object) bool { return x.Str("mode") == "compiled" }).Set("verdict", "fail_mismatch")
		}
		rebind(rows)
	})
	t.expectFail("permissive_comparator", "per-attempt verdict is not derived", nil, nil, run(PROD, d)...)
	d = mutate("tampered-summary", func(rows []*Object) { lastRow(rows).Set("failures", []any{"invented"}); rebind(rows) })
	t.expectFail("tampered_summary", "summary is not independently derived", nil, nil, run(PROD, d)...)
	d = mutate("tampered-root", func(rows []*Object) { lastRow(rows).Set("root_digest", strings.Repeat("0", 64)) })
	t.expectFail("tampered_root", "summary-bound root digest mismatch", nil, nil, run(PROD, d)...)

	// Effects: a forged digest, and a listing quietly rewritten by a
	// normalization no row licenses.
	d = mutate("forged-effects", func(rows []*Object) {
		r := findAttempt(rows, func(x *Object) bool { return x.Has("effects_delta") })
		r.Set("effects_delta", "+tmp/undeclared-residue\tfile:"+strings.Repeat("0", 64))
		rebind(rows)
	})
	t.expectFail("forged_effect_digest", "stored effect digest differs from the recorded delta", nil, nil, run(PROD, d)...)

	// A compiled run may not be recorded without the stages that could have
	// produced an artifact: a successful transpile is not a successful build,
	// and a transpile without a validated source map is not a successful
	// transpile.
	spawnedCompiled := func(rows []*Object) *Object {
		r := findAttempt(rows, func(x *Object) bool { return x.Str("mode") == "compiled" && x.Bool("spawned") })
		if r == nil {
			t.fail("no spawned compiled attempt")
		}
		return r
	}
	d = mutate("stage-masquerade", func(rows []*Object) {
		r := spawnedCompiled(rows)
		var kept []any
		for _, s := range r.Arr("stages") {
			if s.(*Object).Str("stage") != "build" {
				kept = append(kept, s)
			}
		}
		r.Set("stages", kept)
		rebind(rows)
	})
	t.expectFail("stage_masquerade", "compiled run was recorded without a successful build stage", nil, nil, run(PROD, d)...)
	d = mutate("map-masquerade", func(rows []*Object) {
		for _, s := range spawnedCompiled(rows).Arr("stages") {
			s.(*Object).Delete("source_map_sha256")
		}
		rebind(rows)
	})
	t.expectFail("source_map_masquerade", "without a successful transpile stage", nil, nil, run(PROD, d)...)

	// The recorded recipe is part of what is reviewed: reverting the oracle to
	// `go run`, granting one mode extra environment, dropping the --go-file
	// multi-file contract, renaming the shared process primitives away, or
	// overstating the isolation the harness actually builds is refused even
	// when every hash in the document has been recomputed around the change.
	recipeEdit := func(name, key string, value any) string {
		return mutate(name, func(rows []*Object) { first(rows).Obj("recipe").Set(key, value); rebind(rows) })
	}
	d = recipeEdit("go-run-oracle", "oracle", "go run the pinned source")
	t.expectFail("go_run_oracle_recipe", "oracle recipe must build and run a native binary", nil, nil, run(PROD, d)...)
	d = recipeEdit("env-divergence", "declared_env_divergence", []any{"GOROOT"})
	t.expectFail("declared_env_divergence", "evidence declares an environment divergence between modes", nil, nil, run(PROD, d)...)
	d = recipeEdit("hidden-env-grant", "common_runtime_go_env", []any{})
	t.expectFail("hidden_runtime_env_grant", "does not record the common runtime Go environment", nil, nil, run(PROD, d)...)
	d = recipeEdit("operand-recipe", "multi_file_input", "operand")
	t.expectFail("operand_multifile_recipe", "does not record the --go-file multi-file input contract", nil, nil, run(PROD, d)...)
	// ... and where it is actually observable: the recorded argv of the
	// multi-file row. Rewriting it to the operand spelling is refused even
	// though the recipe prose still claims --go-file.
	d = mutate("operand-argv", func(rows []*Object) {
		r := findAttempt(rows, func(x *Object) bool { return x.Str("kind") == "test_program" && x.Str("mode") == "interpreted" })
		if r == nil {
			t.fail("no multi-file product attempt")
		}
		for _, s := range r.Arr("stages") {
			st := s.(*Object)
			var kept []any
			for _, a := range st.Arr("argv") {
				if a != "--go-file" {
					kept = append(kept, a)
				}
			}
			st.Set("argv", kept)
		}
		rebind(rows)
	})
	t.expectFail("operand_multifile_argv", "did not use the --go-file contract", nil, nil, run(PROD, d)...)
	d = recipeEdit("foreign-primitives", "process_primitives", "a private spawn/timeout/leak implementation")
	t.expectFail("foreign_process_primitives", "does not record the shared corpus process primitives", nil, nil, run(PROD, d)...)
	d = recipeEdit("stale-corpus-primitives", "corpus_executor_sha256", strings.Repeat("0", 64))
	t.expectFail("unanchored_corpus_primitives", "corpus executor is not anchored to production", nil, nil, run(PROD, d)...)
	d = recipeEdit("overstated-isolation", "source_absence", "the program cannot reach its source or the Go SDK")
	t.expectFail("overstated_isolation", "evidence overstates isolation", nil, nil, run(PROD, d)...)

	// Candidate binding inside the document: evidence produced against some
	// other launcher, payload, build recipe or runtime dependency set is not
	// evidence about the reviewed candidate.
	candidateEdit := func(name, key string, value any) string {
		return mutate(name, func(rows []*Object) { first(rows).Obj("candidate").Set(key, value); rebind(rows) })
	}
	d = candidateEdit("other-launcher", "launcher_sha256", strings.Repeat("a", 64))
	t.expectFail("evidence_bound_to_other_launcher", "candidate launcher_sha256 is not the repository-reviewed value", nil, nil, run(PROD, d)...)
	d = candidateEdit("other-payload", "payload_sha256", strings.Repeat("b", 64))
	t.expectFail("evidence_bound_to_other_payload", "candidate payload_sha256 is not the repository-reviewed value", nil, nil, run(PROD, d)...)
	d = candidateEdit("default-cli-evidence", "build_recipe", "GOTOOLCHAIN=go1.27.0 make build")
	t.expectFail("evidence_bound_to_default_cli", "candidate build_recipe is not the repository-reviewed value", nil, nil, run(PROD, d)...)
	d = mutate("dropped-dependency", func(rows []*Object) {
		c := first(rows).Obj("candidate")
		var kept []any
		for _, r := range c.Arr("repositories") {
			if r.(*Object).Str("name") != "filebrowser" {
				kept = append(kept, r)
			}
		}
		c.Set("repositories", kept)
		rebind(rows)
	})
	t.expectFail("evidence_drops_runtime_dependency", "candidate runtime dependencies differ from the reviewed set", nil, nil, run(PROD, d)...)

	// Repository mutations checked by the validator's own standalone revalidation.
	CROW := "examples/atomic-counters/atomic-counters.go"
	couple := func(text string) string {
		prefix := CROW + "\tprogram\tconcurrency\tnone\tbounded_wait\t"
		var out []string
		for _, line := range rubyLinesChomp(text) {
			if strings.HasPrefix(line, prefix) {
				line = CROW + "\tprogram\tconcurrency\tnone\tbounded_wait,tmpdir\t" + line[len(prefix):]
			}
			out = append(out, line)
		}
		return strings.Join(out, "\n") + "\n"
	}
	clsRepo := t.copyFrom(PROD, "cls-repo")
	mustWrite(clsRepo+"/docs/go-by-example/classification.tsv", couple(mustRead(t.root+"/docs/go-by-example/classification.tsv")))
	t.expectFail("classification_not_bound_to_inventory", "inventory classification columns do not match the authored classification table",
		nil, nil, run(clsRepo, locate(clsRepo))...)
	mustWrite(clsRepo+"/docs/go-by-example/inventory.tsv", couple(mustRead(t.root+"/docs/go-by-example/inventory.tsv")))
	t.expectFail("unlicensed_adapter_coupling", "row carries an adapter no declared behavior requires: "+CROW,
		nil, nil, run(clsRepo, locate(clsRepo))...)

	schemaRepo := t.copyFrom(PROD, "schema-repo")
	mustWrite(schemaRepo+"/docs/go-by-example/behavior-schema.tsv", mustRead(schemaRepo+"/docs/go-by-example/behavior-schema.tsv")+"adapter\tnamed_but_unimplemented\t-\tclaims a control nothing performs\n")
	t.expectFail("schema_adapter_without_implementation", "schema declares an adapter the gate does not implement",
		nil, nil, run(schemaRepo, locate(schemaRepo))...)

	strayRepo := t.copyFrom(PROD, "stray-repo")
	mustWrite(strayRepo+"/examples/stray.txt", "not reviewed\n")
	t.expectFail("unanchored_corpus_file", "standalone corpus integrity revalidation failed",
		nil, nil, run(strayRepo, locate(strayRepo))...)
}

func tamperTestsMain(args []string) {
	if len(args) != 0 {
		fatal("tamper-tests takes no arguments")
	}
	candidate := os.Getenv("GBE_CANDIDATE")
	if candidate == "" {
		fatal("set GBE_CANDIDATE to the authenticated candidate manifest")
	}
	bashy := os.Getenv("BASHY_BIN")
	if bashy == "" {
		fatal("set BASHY_BIN to the authenticated candidate launcher")
	}
	work, err := os.MkdirTemp(envOr("TMPDIR", "/tmp"), "gbe-tamper.")
	if err != nil {
		fatal(err.Error())
	}
	t := &tamperSuite{root: ROOT, work: work, candidate: candidate, bashy: bashy}
	defer os.RemoveAll(work)
	t.phaseA(nil)
	t.phaseB()
	fmt.Printf("PASS: %d genuine mutations/invariants checked\n", t.pass)
}

// --- tamper-retained-evidence -------------------------------------------------

// tamperRetainedMain mutates a retained REAL execution ledger; it never
// produces an execution verdict.
func tamperRetainedMain(args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: tamper-retained-evidence AUTHENTICATED_EVIDENCE")
		os.Exit(1)
	}
	source := expandPath(args[0])
	self, err := os.Executable()
	if err != nil {
		fatal(err.Error())
	}
	validate := func(path string) (string, bool) {
		cmd := exec.Command(self, "validate-evidence", path)
		cmd.Env = append(envWithout("GBE_ROOT"), "GBE_ROOT="+ROOT)
		out, err := cmd.CombinedOutput()
		return string(out), err == nil
	}
	if out, ok := validate(source); !ok {
		fatal("real evidence prerequisite failed:\n" + out)
	}
	original, err := readEvidence(source)
	if err != nil {
		fatal(err.Error())
	}
	type check struct {
		name      string
		diagnosis string
		mutate    func(rows []*Object)
	}
	checks := []check{
		{"duplicate-stream", "duplicate retained stage stream path", func(rows []*Object) {
			for _, s := range rows[1].Arr("stages") {
				stage := s.(*Object)
				if capture := stage.Obj("capture"); capture != nil {
					capture.Set("stderr", deepCopy(capture.Obj("stdout")))
					return
				}
			}
			fatal("no captured stage")
		}},
		{"raw-stream-substitution", "run raw bytes differ from retained capture", func(rows []*Object) {
			rows[1].Set("raw_stdout_b64", b64([]byte("unobserved program output")))
		}},
		{"native-artifact-digest", "retained native_file changed", func(rows []*Object) {
			for _, s := range rows[1].Arr("stages") {
				stage := s.(*Object)
				if native := stage.Obj("native_file"); native != nil {
					native.Set("sha256", strings.Repeat("0", 64))
					return
				}
			}
			fatal("undefined method '[]=' for nil")
		}},
		{"telemetry-mode-digest", "telemetry mode file changed", func(rows []*Object) {
			rows[1].Obj("configuration").Obj("mode_file").Set("sha256", strings.Repeat("0", 64))
		}},
		{"telemetry-configuration-command", "invalid telemetry setup commands", func(rows []*Object) {
			argv := rows[1].Obj("configuration").Arr("stages")[0].(*Object).Arr("argv")
			argv[2] = "on"
		}},
	}
	dir, err := os.MkdirTemp(envOr("TMPDIR", "/tmp"), "gbe-retained-tamper-")
	if err != nil {
		fatal(err.Error())
	}
	defer os.RemoveAll(dir)
	for _, c := range checks {
		rows := make([]*Object, len(original))
		for i, r := range original {
			rows[i] = deepCopy(r).(*Object)
		}
		c.mutate(rows)
		// Recompute the modified record's integrity hash. Rejection must come from
		// independently retained facts, not the trivial self-hash mismatch.
		rows[1].Set("evidence_sha256", sha256Hex([]byte(Generate(rows[1].Without("evidence_sha256")))))
		path := filepath.Join(dir, c.name+".jsonl.fail")
		writeRows(path, rows)
		out, ok := validate(path)
		if ok || !strings.Contains(out, c.diagnosis) {
			fatal("FAIL " + c.name + ": wrong acceptance/diagnosis:\n" + out)
		}
		fmt.Println("PASS " + c.name)
	}
	fmt.Printf("PASS %d retained-evidence mutations against authenticated real execution\n", len(checks))
}

// --- bounded-evidence-selftests -------------------------------------------

type boundedSuite struct {
	label           string
	evidence        string
	inventory       string
	source          string
	inventoryTarget string
	candidateTarget string
}

// boundedSelftestsMain tampers the retained bounded evidence chains and their
// bindings; every mutation must be rejected by the real
// validate-bounded-evidence, never asserted from here. Candidates024-027 are
// exercised through the same generalized validator. GBE_BOUNDED_STATE names
// the directory holding the retained runtime-integration-0NN trees.
func boundedSelftestsMain(args []string) {
	state := envOr("GBE_BOUNDED_STATE", "/Users/qiangli/.local/state/bashy/sprint118-evidence")
	suites := []boundedSuite{
		{"Candidate024", state + "/runtime-integration-024/gbe-subset.jsonl.fail", state + "/runtime-integration-024/subset-inventory.tsv", "examples/generics/generics.go", "d070bee32f", "f7dbbff0fdff337e"},
		{"Candidate025", state + "/runtime-integration-025/gbe-subset.jsonl.pass", state + "/runtime-integration-025/subset-inventory.tsv", "examples/recursion/recursion.go", "3e64a878e9", "57a8b7680573866b"},
		{"Candidate026", state + "/runtime-integration-026/gbe-subset.jsonl.fail", state + "/runtime-integration-026/subset-inventory.tsv", "examples/generics/generics.go", "d070bee32f", "304bc25216736f83"},
		{"Candidate027", state + "/runtime-integration-027/gbe-subset.jsonl.pass", state + "/runtime-integration-027/subset-inventory.tsv", "examples/range-over-iterators/range-over-iterators.go", "7ee6216ba1", "d2da6d9cf2e36906"},
	}
	self, err := os.Executable()
	if err != nil {
		fatal(err.Error())
	}
	runValidator := func(root, evidence, inventory string) (string, bool) {
		cmd := exec.Command(self, "validate-bounded-evidence", evidence, inventory)
		cmd.Env = append(envWithout("GBE_ROOT"), "GBE_ROOT="+root)
		out, err := cmd.CombinedOutput()
		return string(out), err == nil
	}
	expectFail := func(name, marker, root, evidence, inventory string) {
		out, ok := runValidator(root, evidence, inventory)
		if ok {
			fatal("FAIL " + name + " accepted")
		}
		if !strings.Contains(out, marker) {
			fatal("FAIL " + name + " produced the wrong diagnostic:\n" + out)
		}
		fmt.Println("PASS " + name)
	}
	expectPass := func(name, root, evidence, inventory string) {
		out, ok := runValidator(root, evidence, inventory)
		if !ok {
			fatal("FAIL " + name + " rejected:\n" + out)
		}
		fmt.Println("PASS " + name)
	}
	mutateCandidateTable := func(path, target, action string) {
		lines := rubyLines(mustRead(path))
		index := -1
		for i, l := range lines {
			if strings.Contains(l, target) {
				index = i
				break
			}
		}
		if index < 0 {
			fatal("candidate " + action + " target missing")
		}
		switch action {
		case "mutate":
			lines[index] = strings.Replace(lines[index], target, "0"+target[1:], 1)
		case "delete":
			lines = append(lines[:index], lines[index+1:]...)
		case "reorder":
			prior := -1
			for i := index - 1; i >= 0; i-- {
				if !strings.HasPrefix(lines[i], "#") && strings.TrimSpace(lines[i]) != "" {
					prior = i
					break
				}
			}
			if prior < 0 {
				fatal("candidate reorder predecessor missing")
			}
			lines[index], lines[prior] = lines[prior], lines[index]
		default:
			fatal("unknown candidate table action: " + action)
		}
		mustWrite(path, strings.Join(lines, ""))
	}
	recomputeRoot := func(rows []*Object) { rebind(rows) }

	total := 0
	for _, suite := range suites {
		label := suite.label
		evidence := expandPath(suite.evidence)
		inventory := expandPath(suite.inventory)
		work, err := os.MkdirTemp(envOr("TMPDIR", "/tmp"), "gbe-bounded-tamper-"+label+"-")
		if err != nil {
			fatal(err.Error())
		}
		pass := 0
		// 1. An inventory cannot change either a row or its source binding.
		inventoryText := mustRead(inventory)
		if !strings.Contains(inventoryText, suite.inventoryTarget) {
			fatal(label + " inventory mutation target missing")
		}
		tamperedInventory := work + "/inventory.tsv"
		mustWrite(tamperedInventory, strings.Replace(inventoryText, suite.inventoryTarget, "0"+suite.inventoryTarget[1:], 1))
		expectFail(label+" inventory_binding_tamper", "bounded inventory digest changed", ROOT, evidence, tamperedInventory)
		pass++

		// 2. The separately supplied inventory is still checked against repository bytes.
		repo := work + "/repo"
		if err := copyTree(ROOT, repo); err != nil {
			fatal(err.Error())
		}
		sourcePath := repo + "/" + suite.source
		mustWrite(sourcePath, mustRead(sourcePath)+"\n")
		expectFail(label+" source_tamper", "bounded source changed: "+suite.source, repo, evidence, inventory)
		pass++
		copyFile(ROOT+"/"+suite.source, sourcePath)

		// 3. A syntactically valid future suffix leaves each historical prefix valid.
		candidatesPath := repo + "/docs/go-by-example/candidates.tsv"
		mustWrite(candidatesPath, mustRead(candidatesPath)+"darwin\tarm64\t"+strings.Repeat("0", 64)+"\t"+strings.Repeat("1", 64)+"\t"+strings.Repeat("2", 64)+"\tgosource-v1\tdummy\tdummy\tdummy=0000000000000000000000000000000000000000\n")
		expectPass(label+" candidate_suffix_append", repo, evidence, inventory)
		copyFile(ROOT+"/docs/go-by-example/candidates.tsv", candidatesPath)

		// 4. Mutation, deletion, and reordering within the selected authenticated
		// prefix all fail, even though the table remains otherwise parseable.
		for _, action := range []string{"mutate", "delete", "reorder"} {
			mutateCandidateTable(candidatesPath, suite.candidateTarget, action)
			marker := "candidate table binding changed"
			if action == "delete" {
				marker = "candidate manifest row is not unique"
			}
			expectFail(label+" candidate_"+action+"_tamper", marker, repo, evidence, inventory)
			copyFile(ROOT+"/docs/go-by-example/candidates.tsv", candidatesPath)
			pass++
		}
		// 5. The evidence's recorded whole-table digest is not authority for a
		// changed authenticated prefix.
		mutateCandidateTable(candidatesPath, suite.candidateTarget, "mutate")
		expectFail(label+" candidate_binding_tamper", "candidate table binding changed", repo, evidence, inventory)
		pass++

		// 6. Recompute every attacker-controlled JSON hash around a forged
		//    retained-stream digest. The actual retained bytes remain an
		//    independent witness.
		rows, err := readEvidence(evidence)
		if err != nil {
			fatal(err.Error())
		}
		attempt := findAttempt(rows, func(x *Object) bool { return x.Str("mode") == "oracle" })
		stages := stageList(attempt)
		stages[len(stages)-1].Obj("capture").Obj("stdout").Set("sha256", strings.Repeat("0", 64))
		recomputeRoot(rows)
		streamEvidence := work + "/stream.jsonl"
		writeRows(streamEvidence, rows)
		expectFail(label+" retained_stream_tamper", "retained stdout changed", ROOT, streamEvidence, inventory)
		pass++

		// 7. A self-consistent replacement root is still not the independently
		//    reviewed root. This also prevents a bounded run from inventing parity.
		rows, _ = readEvidence(evidence)
		rows[len(rows)-1].Set("parity_claim", true)
		recomputeRoot(rows)
		rootEvidence := work + "/root.jsonl"
		writeRows(rootEvidence, rows)
		expectFail(label+" root_tamper", "bounded root is not the reviewed "+label+" root", ROOT, rootEvidence, inventory)
		pass++
		os.RemoveAll(work)
		total += pass
	}
	fmt.Printf("PASS: %d bounded-evidence tamper selftests across %d reviewed candidates\n", total, len(suites))
}

// --- leak fixture ---------------------------------------------------------------

// leakDescendantMain is the genuine descendant leak used by the process-mutation
// tests (it replaces tests/go-by-example/leak-descendant.sh, which needed a
// Ruby interpreter). The grandchild moves itself into a NEW session, so the
// gate's process-group TERM/KILL provably cannot reach it and kill(0, -pgid)
// cannot even see it. This process does not exit until the grandchild has
// confirmed the escape -- otherwise the descendant would still be in this
// process group when the gate cleans up, and the gate would (correctly) reap it
// instead of reporting a leak. Nothing here asserts a state; the gate observes
// one. The survivor exits on its own, so the test never strands a process.
func leakDescendantMain(args []string) {
	ready, err := os.CreateTemp(envOr("TMPDIR", "/tmp"), "gbe-leak.")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	ready.Close()
	self, _ := os.Executable()
	cmd := exec.Command(self, "leak-survivor", ready.Name())
	devnull, _ := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = devnull, devnull, devnull
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	deadline := time.Now().Add(10 * time.Second)
	for fileSize(ready.Name()) == 0 {
		if time.Now().After(deadline) {
			fmt.Fprintln(os.Stderr, "descendant never left the process group")
			os.Exit(3)
		}
		time.Sleep(10 * time.Millisecond)
	}
	os.Remove(ready.Name())
	os.Exit(0)
}

func leakSurvivorMain(args []string) {
	if len(args) == 1 {
		os.WriteFile(args[0], []byte("detached"), 0o600)
	}
	time.Sleep(3 * time.Second)
}

func selfExecutable() string {
	exe, err := os.Executable()
	if err != nil {
		fatal(err.Error())
	}
	return exe
}

var _ = bytes.Compare
