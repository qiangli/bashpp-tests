#!/usr/bin/env python3
"""Retain exact upstream skip decisions for manager applicability review.

This verifies the reasons recorded by the authenticated upstream runner; it
never turns a skip into product coverage or silently approves an exclusion.
"""
import argparse
import collections
import json
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
import inventory as inv


def report(native, output, inventory):
    inv.require(not output.exists(), "skip report directory already exists")
    summary = json.loads((native / "summary.json").read_text())
    inv.require(summary["schema"] == "go-full-native/v1" and summary["product_execution_claim"] is False, "wrong native evidence schema")
    log = summary["native_stage"]["stdout"]
    inv.require(inv.sha(Path(log["path"]).read_bytes()) == log["sha256"], "native stdout digest changed")
    for name, record in summary["inventory"].items():
        inv.require(inv.sha((inventory / name).read_bytes()) == record["sha256"], "native inventory changed: " + name)
    pin = inv.pins()
    files = inv.archive_files(summary["sdk"]["source_archive"]["path"], pin)
    output_by_key = collections.defaultdict(list)
    skips = {}
    for number, line in enumerate(Path(log["path"]).read_text().splitlines(), 1):
        event = json.loads(line)
        key = event["Package"], event.get("Test")
        if event["Action"] == "output":
            output_by_key[key].append({"line": number, "output": event["Output"]})
        if event["Action"] == "skip":
            inv.require(key not in skips, "duplicate skip event: " + str(key))
            skips[key] = {"line": number, "event": event}
    roots = [json.loads(line) for name in ("testdir-roots.jsonl", "typechecker-roots.jsonl") for line in (inventory / name).read_text().splitlines()]
    rows = []
    for root in roots:
        if root["id"].startswith("testdir:"):
            key = "cmd/internal/testdir", root["upstream_subtest"]
        else:
            key = tuple(root["id"].split(":", 1))
        if key not in skips:
            continue
        messages = output_by_key[key]
        reasons = [line.strip().split(": ", 1)[1] for record in messages for line in record["output"].splitlines()
                   if line.strip().startswith(("testdir_test.go:", "check_test.go:")) and ": " in line]
        inv.require(len(reasons) == 1, "skip lacks exactly one upstream reason: " + root["id"])
        reason = reasons[0]
        source_files = root.get("input_files", [root["path"]])
        directives = {name: inv.constraints(files[name]) for name in source_files}
        if reason == "skip":
            inv.require(root["recipe"]["action"] == "skip", "explicit skip reason disagrees with source action")
            category = "upstream-explicit-skip-action"
        elif reason.startswith("//"):
            inv.require(reason in directives[root["path"]], "skip reason is absent from original build directives")
            category = "upstream-build-constraint"
        elif reason == "all files skipped by build tags":
            inv.require(not root["id"].startswith("testdir:") and all(directives.values()), "checker skip lacks source build constraints")
            category = "upstream-checker-build-constraints"
        else:
            raise ValueError("unclassified skip reason: " + root["id"] + ": " + reason)
        rows.append({"id": root["id"], "category": category, "exact_upstream_reason": reason,
                     "source_inputs": [inv.fingerprint(name, files) for name in source_files],
                     "source_constraints": directives, "upstream_recipe": root.get("recipe"),
                     "terminal_evidence": skips[key], "output_evidence": messages,
                     "product_execution_credit": 0, "adjudication": "requires-manager-scope-decision"})
    expected = sum(counts.get("skip", 0) for axis, counts in summary["counts_by_axis"].items() if axis in ("testdir", "typechecker"))
    inv.require(len(rows) == expected, "skip reason denominator mismatch")
    output.mkdir(parents=True)
    go = summary["native_stage"]["argv"][0]
    inv.require(inv.sha(Path(go).read_bytes()) == summary["sdk"]["go"]["sha256"], "SDK executable changed")
    command = [go, "env", "-json", "GOOS", "GOARCH", "GOHOSTOS", "GOHOSTARCH", "GOVERSION", "CGO_ENABLED", "GOEXPERIMENT", "GODEBUG"]
    started = time.monotonic()
    process = subprocess.run(command, cwd=summary["native_stage"]["cwd"], env=summary["native_stage"]["environment"], capture_output=True, timeout=60)
    (output / "sdk-env.stdout").write_bytes(process.stdout)
    (output / "sdk-env.stderr").write_bytes(process.stderr)
    inv.require(process.returncode == 0, "SDK environment query failed")
    environment = json.loads(process.stdout)
    result = {"schema": "go-full-skip-review/v1", "native_summary_sha256": inv.sha((native / "summary.json").read_bytes()),
              "native_log": log, "scope": "historical and static typechecker roots", "skip_roots": len(rows),
              "category_counts": dict(collections.Counter(row["category"] for row in rows)),
              "exact_reason_counts": dict(collections.Counter(row["exact_upstream_reason"] for row in rows)),
              "bound_native_environment": environment, "native_process_environment": summary["native_stage"]["environment"],
              "environment_query": {"argv": command, "exit": process.returncode, "duration_seconds": time.monotonic()-started,
                                    "stdout_sha256": inv.sha(process.stdout), "stderr_sha256": inv.sha(process.stderr)},
              "native_runner_sha256": pin["semantics_sha256"], "manager_adjudication_complete": False,
              "product_execution_credit": 0}
    (output / "roots.jsonl").write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))
    (output / "summary.json").write_bytes(inv.pretty(result))
    print(json.dumps(result, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, default=inv.REPO / "docs/go-full")
    args = parser.parse_args()
    report(args.native, args.output, args.inventory)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        print("FATAL: " + str(exc), file=sys.stderr)
        sys.exit(2)
