// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// tour-evidence/v2 tamper tests — the port of tools/tour/evidence-tamper-tests.sh:
// a synthetic mutual-equality forgery, a full-ledger baseline-cloning forgery
// that keeps every real command, and three provenance forgeries (a truthfully
// self-described dirty/dev bashy, a real non-pinned Go builder, a fabricated
// published version string). Every forged ledger is internally consistent and
// must still be rejected, with the exact message the validator prints.
//
// Usage: tour evidence-tamper-tests [ledger]  (default tests/tour/evidence.jsonl)
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func cmdEvidenceTamperTests(root string, args []string) int {
	ledger := filepath.Join(root, "tests/tour/evidence.jsonl")
	if len(args) > 0 {
		ledger = args[0]
	}
	work, err := os.MkdirTemp("", "tour-evidence-tamper")
	if err != nil {
		return abortf("FATAL: %v", err)
	}
	defer os.RemoveAll(work)
	exe, _ := os.Executable()

	load := func() []map[string]any {
		records, err := readLedger(ledger)
		if err != nil {
			panic(err)
		}
		return records
	}
	// reseal recomputes summary/root/verdict so the ledger balances.
	resealEvidence := func(rows []map[string]any) []map[string]any {
		attempts := []map[string]any{}
		for _, r := range rows {
			if r["type"] == "attempt" {
				attempts = append(attempts, r)
			}
		}
		counts := countBy(attempts, "outcome")
		rows[len(rows)-3]["outcomes"] = counts
		rows[len(rows)-2]["sha256"] = ledgerRoot(rows[:len(rows)-2])
		value := "FAIL"
		if jsonEqual(counts, map[string]any{"PASS": int64(291)}) {
			value = "PASS"
		}
		rows[len(rows)-1] = map[string]any{"type": "verdict", "value": value, "root_sha256": rows[len(rows)-2]["sha256"]}
		return rows
	}
	validate := func(path string) (bool, string) {
		cmd := exec.Command(exe, "validate-evidence")
		cmd.Env = append(os.Environ(), "TOUR_REPO_ROOT="+root, "TOUR_EVIDENCE="+path)
		out, err := cmd.CombinedOutput()
		return err == nil, string(out)
	}
	probe := func(name, expected, acceptedMessage string, mutate func(rows []map[string]any) []map[string]any) bool {
		path := filepath.Join(work, name+".jsonl")
		if err := writeLedger(path, resealEvidence(mutate(load()))); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return false
		}
		accepted, log := validate(path)
		if accepted {
			fmt.Fprintf(os.Stderr, "FAIL %s\n", acceptedMessage)
			return false
		}
		if !strings.Contains(log, expected) {
			lines := strings.Split(log, "\n")
			if len(lines) > 8 {
				lines = lines[:8]
			}
			fmt.Fprintln(os.Stderr, strings.Join(lines, "\n"))
			return false
		}
		return true
	}
	cloneKeys := func(dst, src map[string]any, keys ...string) {
		for _, k := range keys {
			dst[k] = deepCopy(src[k])
		}
	}
	attemptsOf := func(rows []map[string]any) []map[string]any {
		out := []map[string]any{}
		for _, r := range rows {
			if r["type"] == "attempt" {
				out = append(out, r)
			}
		}
		return out
	}

	// 1. synthetic mutual equality: one program's product rows cloned from its
	// baseline, command included.
	if !probe("synthetic", "synthetic mutual-equality artifact", "synthetic mutual-equality artifact was accepted", func(rows []map[string]any) []map[string]any {
		attempts := attemptsOf(rows)
		victim := findRecord(attempts, func(r map[string]any) bool { return r["mode"] == "baseline" })
		for _, mode := range []string{"interpreted", "compiled"} {
			row := findRecord(attempts, func(r map[string]any) bool { return r["path"] == victim["path"] && r["mode"] == mode })
			cloneKeys(row, victim, "command", "spawned", "state", "exit", "raw", "normalized")
			row["outcome"] = "PASS"
		}
		return rows
	}) {
		return 1
	}
	fmt.Println("PASS synthetic mutual-equality artifact rejected after internally consistent root/summary rewrite")

	// 2. full-ledger baseline-cloning forgery: every product row KEEPS its own
	// real command but carries its baseline's process/raw fields.
	if !probe("cloning", "FATAL: replay", "full-ledger baseline-cloning forgery (real commands, forged process/raw) was accepted", func(rows []map[string]any) []map[string]any {
		groups := map[string][]map[string]any{}
		order := []string{}
		for _, r := range attemptsOf(rows) {
			path := asString(r["path"])
			if _, ok := groups[path]; !ok {
				order = append(order, path)
			}
			groups[path] = append(groups[path], r)
		}
		for _, path := range order {
			group := groups[path]
			baseline := findRecord(group, func(r map[string]any) bool { return r["mode"] == "baseline" })
			for _, mode := range []string{"interpreted", "compiled"} {
				row := findRecord(group, func(r map[string]any) bool { return r["mode"] == mode })
				cloneKeys(row, baseline, "spawned", "state", "exit", "raw", "normalized", "stage")
				row["outcome"] = "PASS"
			}
		}
		return rows
	}) {
		return 1
	}
	fmt.Println("PASS full-ledger baseline-cloning forgery rejected by replay authentication")

	// 3. a dev/dirty bashy, truthfully self-described.
	fakeBashy := filepath.Join(work, "fake-bashy")
	os.WriteFile(fakeBashy, []byte("#!/usr/bin/env bash\necho \"bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-dev (da8deb9-dirty)\"\n"), 0o755)
	if !probe("dirty", "FATAL: bashy build is dirty or unpublished", "truthfully-described dirty/dev bashy build was accepted", func(rows []map[string]any) []map[string]any {
		rows[0]["bashy"] = map[string]any{
			"path": fakeBashy, "present": true, "sha256": shaFile(fakeBashy),
			"version": "bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-dev (da8deb9-dirty)", "source_revision": "da8deb9",
			"published": false, "reproducible": false, "build_recipe": "workspace dev build",
		}
		return rows
	}) {
		return 1
	}
	fmt.Println("PASS dirty/dev bashy build (truthfully self-described) rejected")

	// 4. a real host toolchain that is not the pinned Go 1.27 builder.
	goos, goarch := hostGoosGoarch()
	pinnedIdentity := ""
	for _, f := range tsvRowsLoose(filepath.Join(root, "docs/tour/toolchain.tsv")) {
		if field(f, 0) == goos && field(f, 1) == goarch {
			pinnedIdentity = field(f, 3)
			break
		}
	}
	hostGo, _ := exec.LookPath("go")
	hostIdentity := ""
	if hostGo != "" {
		hostIdentity = shellOutput(nil, hostGo, "version")
	}
	if hostGo != "" && pinnedIdentity != "" && hostIdentity != pinnedIdentity {
		if !probe("builder", "not the pinned Go 1.27 toolchain", fmt.Sprintf("truthfully-described non-pinned Go builder (%s) was accepted", hostIdentity), func(rows []map[string]any) []map[string]any {
			rows[0]["go"] = map[string]any{"path": hostGo, "present": true, "sha256": shaFile(hostGo),
				"version": hostIdentity, "identity": hostIdentity, "pinned_sha256": shaFile(hostGo)}
			return rows
		}) {
			return 1
		}
		fmt.Printf("PASS non-pinned Go builder (%s) rejected by toolchain pin cross-check\n", hostIdentity)
	} else {
		fmt.Println("NOTE host go is the pinned toolchain here; non-pinned-builder forgery not exercisable on this host")
	}

	// 5. a fabricated bashy version string paired with the real binary's checksum.
	if !probe("fabricated", "FATAL: exact bashy version mismatch", "fabricated bashy version string (self-consistent, parses as published) was accepted", func(rows []map[string]any) []map[string]any {
		asMap(rows[0]["bashy"])["version"] = "bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-0.19.0"
		asMap(rows[0]["bashy"])["source_revision"] = "0.19.0"
		return rows
	}) {
		return 1
	}
	fmt.Println("PASS fabricated bashy version string rejected by live version re-derivation")
	return 0
}
