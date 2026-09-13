// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Tamper self-tests for the tour-executor ledger and its offline gate — the
// port of tools/tour/executor-tamper-tests.sh. The selftests prove the gate on
// a SYNTHETIC fixture; this suite proves it on the REAL evidence: it takes the
// committed tests/tour/executor-results.jsonl (or the ledger named on the
// command line), mutates exactly one recorded fact, reseals the ledger so
// nothing else is inconsistent, and requires the REAL gate to emit the
// expected finding.
//
// Each probe is DIFFERENTIAL: the expected finding must be ABSENT from the
// gate's report on the pristine ledger and PRESENT after the mutation. A probe
// whose mutation leaves the report unchanged is a failure of this suite.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func cmdExecutorTamperTests(root string, args []string) int {
	ledger := filepath.Join(root, "tests/tour/executor-results.jsonl")
	if len(args) > 0 {
		ledger = args[0]
	}
	if !fileExists(ledger) {
		fmt.Fprintf(os.Stderr, "FATAL: missing ledger %s\n", ledger)
		return 2
	}
	work, err := os.MkdirTemp("", "tour-executor-tamper")
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		return 2
	}
	defer os.RemoveAll(work)

	pass, fail := 0, 0
	// The gate's report on the untouched ledger. Every expected finding below
	// must be absent from it, otherwise the probe proves nothing.
	baseRC, baseReport := runGate(root, ledger, nil)
	fmt.Printf("pristine ledger: gate exit %d (%d report lines)\n", baseRC, countLines(baseReport))

	probe := func(name, expected string, mutation func(body []map[string]any) []map[string]any) {
		if strings.Contains(baseReport, expected) {
			fmt.Printf("  FAIL %s: finding %s is ALREADY present without any mutation\n", name, expected)
			fail++
			return
		}
		records, err := readLedger(ledger)
		if err != nil {
			fmt.Printf("  FAIL %s: could not build the mutated ledger\n    mutation failed:\n      %v\n", name, err)
			fail++
			return
		}
		body := []map[string]any{}
		for _, r := range records {
			if r["type"] != "root" && r["type"] != "verdict" {
				body = append(body, r)
			}
		}
		var mutated []map[string]any
		ok := func() (ok bool) {
			defer func() {
				if r := recover(); r != nil {
					fmt.Printf("  FAIL %s: could not build the mutated ledger\n    mutation failed:\n      %v\n", name, r)
					ok = false
				}
			}()
			mutated = mutation(body)
			return true
		}()
		if !ok {
			fail++
			return
		}
		body = mutated
		out := filepath.Join(work, "ledger.jsonl")
		if err := writeLedger(out, reseal(body)); err != nil {
			fmt.Printf("  FAIL %s: could not build the mutated ledger\n", name)
			fail++
			return
		}
		_, report := runGate(root, out, nil)
		if strings.Contains(report, expected) {
			pass++
			fmt.Printf("  ok   %s\n", name)
		} else {
			fmt.Printf("  FAIL %s: expected finding %s, gate said:\n", name, expected)
			for i, line := range strings.Split(report, "\n") {
				if i >= 20 {
					break
				}
				fmt.Printf("       %s\n", line)
			}
			fail++
		}
	}

	manifestOf := func(body []map[string]any) map[string]any { return body[0] }
	firstObservation := func(body []map[string]any) map[string]any { return findRecord(body, isObs("", "")) }
	firstOracle := func(body []map[string]any) map[string]any {
		return findRecord(body, func(r map[string]any) bool { return r["type"] == "oracle" })
	}
	volatileBaseline := func(body []map[string]any) map[string]any {
		volatile := asString(firstOracle(body)["path"])
		return findRecord(body, func(r map[string]any) bool { return isObs("baseline", "")(r) && r["path"] == volatile })
	}
	resetFailures := func(manifest map[string]any) {
		manifest["candidate_failures"] = anyList(candidateFailures(asMap(manifest["candidate"])))
	}

	fmt.Println("candidate provenance")
	probe("a rebound launcher digest is rejected", "candidate:unbound_launcher_digest", func(body []map[string]any) []map[string]any {
		m := manifestOf(body)
		asMap(dig(m, "candidate", "binaries", "launcher"))["sha256"] = "deadbeef"
		resetFailures(m)
		return body
	})
	probe("an unbound replaced dependency (filebrowser) is rejected", "candidate:unbound:filebrowser", func(body []map[string]any) []map[string]any {
		m := manifestOf(body)
		for _, c := range asList(asMap(m["candidate"])["components"]) {
			if asMap(c)["component"] == "filebrowser" {
				asMap(c)["bound"] = false
				asMap(c)["commit"] = nil
			}
		}
		resetFailures(m)
		return body
	})
	probe("dropping a manifest repository is rejected", "candidate:repository_set", func(body []map[string]any) []map[string]any {
		m := manifestOf(body)
		candidate := asMap(m["candidate"])
		kept := []any{}
		for _, r := range asList(candidate["repositories"]) {
			if asMap(r)["name"] != "filebrowser" {
				kept = append(kept, r)
			}
		}
		candidate["repositories"] = kept
		resetFailures(m)
		return body
	})
	probe("a candidate hiding its own failures is rejected", "candidate:runner_hid_failures", func(body []map[string]any) []map[string]any {
		asMap(dig(manifestOf(body), "candidate", "binaries", "payload"))["present"] = false
		return body
	})

	fmt.Println("shared capture provenance")
	probe("a privately captured ledger is rejected", "capture:implementation", func(body []map[string]any) []map[string]any {
		manifestOf(body)["capture_implementation"] = "tools/tour/executor.go"
		return body
	})
	probe("a rebound shared capture library digest is rejected", "capture:library_sha256", func(body []map[string]any) []map[string]any {
		manifestOf(body)["capture_library_sha256"] = strings.Repeat("0", 64)
		return body
	})

	fmt.Println("semantic comparators and the native oracle")
	probe("a forged semantic verdict is rejected", "semantic_forged:", func(body []map[string]any) []map[string]any {
		observation := volatileBaseline(body)
		asMap(observation["semantic"])["findings"] = []any{}
		asMap(asMap(observation["semantic"])["evidence"])["oracle_runs"] = int64(99)
		return body
	})
	probe("a semantic verdict on an undeclared row is rejected", "semantic_undeclared:", func(body []map[string]any) []map[string]any {
		o := findRecord(body, func(r map[string]any) bool { return r["type"] == "observation" && r["semantic"] == nil })
		o["semantic"] = map[string]any{"comparator": "line_set", "version": semanticsVersion, "ok": true, "findings": []any{}, "evidence": map[string]any{}}
		return body
	})
	probe("a missing oracle record is rejected", "oracle:row_set", func(body []map[string]any) []map[string]any {
		return deleteAt(body, findIndex(body, func(r map[string]any) bool { return r["type"] == "oracle" }))
	})
	probe("an oracle thinner than the declared minimum is rejected", "oracle:repeats", func(body []map[string]any) []map[string]any {
		oracle := firstOracle(body)
		oracle["runs"] = asList(oracle["runs"])[:3]
		oracle["repeats"] = int64(3)
		return body
	})
	probe("an oracle that is not the built artifact is rejected", "oracle_binary_mismatch:", func(body []map[string]any) []map[string]any {
		asMap(firstOracle(body)["binary"])["sha256"] = strings.Repeat("7", 64)
		return body
	})
	probe("an oracle bound to another source digest is rejected", "oracle:source_binding:", func(body []map[string]any) []map[string]any {
		firstOracle(body)["source_sha256"] = strings.Repeat("8", 64)
		return body
	})
	probe("a widened comparison window is rejected", "semantic_window_forged:", func(body []map[string]any) []map[string]any {
		window := asMap(volatileBaseline(body)["window"])
		window["to"] = asFloat(window["to"]) + 100000.0
		return body
	})
	probe("a semantics table demoted to advisory is rejected", "semantics:gate_effect", func(body []map[string]any) []map[string]any {
		asMap(manifestOf(body)["semantics"])["gate_effect"] = "advisory"
		return body
	})
	probe("a volatility table promoted to a waiver is rejected", "volatility:claims_gate_effect", func(body []map[string]any) []map[string]any {
		asMap(manifestOf(body)["volatility"])["gate_effect"] = "waives-mismatch"
		return body
	})

	fmt.Println("phase contract")
	probe("a rewritten historical phase token is rejected", "historical_phase_drift:", func(body []map[string]any) []map[string]any {
		findRecord(body, isObs("", "build_only_go_program"))["historical_phase_token"] = "transpile-build-no-run"
		return body
	})
	probe("a rebound phase-migration table is rejected", "binding:phase_migration:sha256", func(body []map[string]any) []map[string]any {
		asMap(manifestOf(body)["phase_migration"])["sha256"] = strings.Repeat("0", 64)
		return body
	})

	fmt.Println("isolation claims")
	probe("an OS-sandbox claim is rejected", "input_absence:os_sandbox_claimed", func(body []map[string]any) []map[string]any {
		asMap(manifestOf(body)["environment"])["os_sandbox"] = true
		return body
	})
	probe("a weakened input-absence scope is rejected", "input_absence:scope", func(body []map[string]any) []map[string]any {
		asMap(manifestOf(body)["environment"])["input_absence_scope"] = "fully sandboxed"
		return body
	})

	fmt.Println("artifacts and streams")
	probe("a source map that does not describe its own artifact is rejected", "source_map_generation_digest", func(body []map[string]any) []map[string]any {
		o := findRecord(body, func(r map[string]any) bool {
			return isObs("compiled", "")(r) && jsonEqual(stageAt(r, 0)["exit"], int64(0))
		})
		asMap(asMap(asMap(stageAt(o, 0)["artifacts"])["map"])["source_map"])["go_digest"] = "sha256:" + strings.Repeat("9", 64)
		return body
	})
	probe("rewritten raw bytes without renormalizing are rejected", "normalizer_drift:", func(body []map[string]any) []map[string]any {
		s := lastStage(findRecord(body, isObs("baseline", "")))
		asMap(s["raw"])["stdout_base64"] = b64([]byte("tampered\n"))
		asMap(s["raw"])["stdout_bytes"] = int64(9)
		return body
	})

	fmt.Println("ledger shape")
	probe("a deleted observation is rejected", "missing:", func(body []map[string]any) []map[string]any {
		return deleteAt(body, findIndex(body, isObs("compiled", "")))
	})
	probe("a duplicated observation is rejected", "duplicate:", func(body []map[string]any) []map[string]any {
		return insertAt(body, 1, asMap(deepCopy(firstObservation(body))))
	})
	probe("a PLANNED placeholder status is rejected", "placeholder_status:", func(body []map[string]any) []map[string]any {
		firstObservation(body)["status"] = "PLANNED"
		return body
	})
	probe("an observation-level waiver is rejected", "unexpected_na:", func(body []map[string]any) []map[string]any {
		firstObservation(body)["expected_failure"] = "unimplemented"
		return body
	})
	probe("a hand-written PASS over a failed stage is rejected", "status_forged:", func(body []map[string]any) []map[string]any {
		o := findRecord(body, func(r map[string]any) bool { return r["type"] == "observation" && r["status"] != "PASS" })
		if o == nil {
			// Every observation already passes: forge a failure into a stage and
			// leave the status claiming PASS.
			o = firstObservation(body)
			lastStage(o)["exit"] = int64(9)
		}
		o["status"] = "PASS"
		return body
	})

	// The root check is the one probe that must NOT be resealed.
	fmt.Println("sealing")
	records, err := readLedger(ledger)
	if err == nil {
		records[len(records)-2]["sha256"] = strings.Repeat("1", 64)
		records[len(records)-1]["root_sha256"] = strings.Repeat("1", 64)
		out := filepath.Join(work, "root.jsonl")
		writeLedger(out, records)
		_, report := runGate(root, out, nil)
		if strings.Contains(report, "root:tampered") {
			pass++
			fmt.Println("  ok   a tampered root hash is rejected")
		} else {
			fail++
			fmt.Println("  FAIL a tampered root hash is rejected")
		}
	} else {
		fail++
		fmt.Println("  FAIL a tampered root hash is rejected")
	}

	fmt.Println()
	fmt.Printf("tour executor tamper tests: %d passed, %d failed\n", pass, fail)
	if fail == 0 {
		return 0
	}
	return 1
}

func countLines(s string) int {
	n := 0
	for _, line := range strings.Split(s, "\n") {
		if line != "" {
			n++
		}
	}
	return n
}
