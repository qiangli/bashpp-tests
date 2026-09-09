#!/usr/bin/env python3
"""Expand complete ordered directory recipes and tested-package obligations.

This is a phase ledger, not evidence of product compilation or execution.
"""
import argparse
import collections
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import subprocess
import sys
import time

sys.dont_write_bytecode = True
import inventory as inv
import sdk as sdktool


def package_nodes(root, parsed):
    action = root["recipe"]["action"]
    directory = root["directory"]["path"]
    if action in inv.PACKAGE_ACTIONS:
        return [{"id": root["id"] + ":package:" + str(group["ordinal"]), "ordinal": group["ordinal"],
                 "package": group["package"], "source_files": group["files"],
                 "compiler_package_path": "main" if group["package"] == "main" else "test/" + PurePosixPath(group["files"][0]).stem,
                 "importcfg_alias": "test/" + PurePosixPath(group["files"][0]).stem,
                 "file_selection": "explicit-upstream-group; file build constraints do not filter these compile inputs"}
                for group in root["package_groups"]]
    if action in {"builddir", "buildrundir"}:
        return [{"id": root["id"] + ":package:0", "ordinal": 0, "package": "main",
                 "compiler_package_path": "main", "source_files": root["direct_compile_inputs"],
                 "assembly_files": root["direct_assembly_inputs"]}]
    # runindir delegates package selection to go run . upstream. Preserve every
    # directory/file candidate and its constraints for an environment-bound
    # loader rather than pretending each *.go file is a standalone package.
    groups = collections.defaultdict(list)
    for name in root["directory"]["members"]:
        if name.endswith(".go"):
            groups[str(PurePosixPath(name).parent)].append(name)
    return [{"id": root["id"] + ":package:" + str(index), "ordinal": index,
             "package_candidates": sorted({parsed[name]["package"] for name in names}), "source_files": names,
             "compiler_package_path": root["module_path"] + ("/" + directory_name[len(directory)+1:] if directory_name != directory else ""),
             "directory": directory_name, "build_selection": "requires-module-build-constraints-and-file-selection"}
            for index, (directory_name, names) in enumerate(sorted(groups.items()))]


def graph(root, parsed, files):
    nodes = package_nodes(root, parsed)
    action = root["recipe"]["action"]
    aliases = {node.get("importcfg_alias", node["compiler_package_path"]): node for node in nodes}
    edges = []
    for node in nodes:
        imported = sorted({name for source in node["source_files"] for name in parsed[source]["imports"]})
        node["source_digests"] = [inv.fingerprint(name, files) for name in node["source_files"]]
        node["source_constraints"] = {name: inv.constraints(files[name]) for name in node["source_files"]}
        node["import_parse_errors"] = {name: parsed[name]["parse_error"] for name in node["source_files"] if parsed[name].get("parse_error")}
        node["imports"] = imported
        for imported_path in imported:
            resolved = posixpath.normpath("test/" + imported_path) if imported_path.startswith(("./", "../")) else imported_path
            target = aliases.get(resolved)
            edge = {"from": node["id"], "source_import": imported_path, "resolved_importcfg_path": resolved}
            if target:
                edge.update({"to": target["id"], "kind": "tested-source-package", "native_forwarding_permitted": False,
                             "requires_declared_compile_order": action in inv.PACKAGE_ACTIONS,
                             "declared_order_satisfied": target["ordinal"] < node["ordinal"] if action in inv.PACKAGE_ACTIONS else None})
            elif imported_path == "C":
                edge.update({"kind": "cgo-boundary", "boundary": "requires-reviewed-foreign-code-bridge-phase", "native_tested_go_forwarding_permitted": False})
            elif imported_path == "unsafe" or any(name.startswith("src/" + imported_path + "/") for name in files):
                edge.update({"kind": "sdk-dependency", "boundary": "record-native-bridge-operation-if-executed"})
            else:
                edge.update({"kind": "unresolved-import", "native_forwarding_permitted": False})
            edges.append(edge)
    action = root["recipe"]["action"]
    phases = []
    def phase(kind, package=None, **extra):
        record = {"id": root["id"] + ":phase:" + str(len(phases)), "kind": kind,
                  "requires": [phases[-1]["id"]] if phases else [], "status": "not-executed", **extra}
        if package:
            record["package"] = package["id"]
            record["source_files"] = package["source_files"]
        phases.append(record)
    want_error = root["recipe"]["want_error"]
    if action in inv.PACKAGE_ACTIONS:
        error_group = len(nodes) - 1 - int(action == "errorcheckandrundir" and want_error)
        for node in nodes:
            phase("compile-package", node, must_reject=action.startswith("errorcheck") and want_error and node["ordinal"] == error_group,
                  artifact_required=not (action.startswith("errorcheck") and want_error and node["ordinal"] == error_group),
                  interpreted_requirement="check/convert tested source package without init or main",
                  compiled_requirement="emit and compile tested source package without init/main execution")
            if action.startswith("errorcheck"):
                phase("match-source-positioned-diagnostics", node)
        if action == "errorcheckandrundir":
            for node in nodes:
                phase("recompile-package", node, failure_permitted=want_error and node["ordinal"] == len(nodes)-2)
        if action in {"rundir", "errorcheckandrundir"}:
            phase("link-final-package", nodes[-1], interpreted_requirement="link interpreter package bodies and bindings; no native tested-package replacement")
            phase("execute-final-package", nodes[-1], args=root["recipe"]["args"], tested_dependencies_must_use_same_product_mode=True)
            phase("match-expected-output", expected_output=root["expected_output"])
    elif action in {"builddir", "buildrundir"}:
        node = nodes[0]
        if node["assembly_files"]:
            phase("generate-symabis", node)
        phase("compile-package", node, generated_asm_header=bool(node["assembly_files"]))
        if node["assembly_files"]:
            phase("assemble-original-inputs", node)
        phase("pack-objects", node)
        phase("link-final-package", node)
        if action == "buildrundir":
            phase("execute-final-package", node, tested_dependencies_must_use_same_product_mode=True)
            phase("match-expected-output", expected_output=root["expected_output"])
    else:
        phase("overlay-original-module-inputs", module_path=root["module_path"], module_go_version=root["module_go_version"])
        phase("resolve-tested-package-graph", package_ids=[node["id"] for node in nodes], native_tested_package_forwarding_permitted=False)
        phase("build-and-run-module", flags=root["recipe"]["flags"], tested_dependencies_must_use_same_product_mode=True)
        phase("match-expected-output", expected_output=root["expected_output"])
    return {"id": root["id"], "action": action, "source_directory": root["directory"], "recipe": root["recipe"],
            "build_constraints": root["build_constraints"], "tested_packages": nodes, "import_edges": edges,
            "phases": phases, "required_modes": ["baseline", "interpreted", "compiled"], "execution_claim": False,
            "product_gap": "Package importer/linker must preserve tested source and dispatch dependencies through the selected product mode."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=inv.REPO / ".cache/go-full")
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("--sdk-identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=inv.REPO / "docs/go-full/directory-phases.jsonl")
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    pin = inv.pins()
    identity = json.loads(args.sdk_identity.read_text())
    inv.require(args.go.resolve() == (Path(identity["root"]) / "bin/go").resolve(), "Go executable differs from SDK identity")
    authenticated = sdktool.prepare(args.cache, Path(identity["distribution_archive"]["path"]).parent, Path(identity["root"]), identity["goos"], identity["goarch"])
    inv.require(authenticated == identity, "SDK identity differs from authenticated archives")
    files = inv.archive_files(args.cache / pin["filename"], pin)
    inv.verify_source(args.cache / "go", files)
    roots, _, _, _ = inv.historical_roots(files, pin)
    roots = [root for root in roots if "directory" in root]
    wanted = sorted({name for root in roots for name in root["directory"]["members"] if name.endswith(".go")})
    approved = [row[4] for row in inv.rows(inv.REPO / "docs/go-oracle/toolchain.tsv") if row[0] == "toolchain"]
    inv.require(inv.sha(args.go.read_bytes()) in approved, "unreviewed Go executable for import parser build")
    helper_source = Path(__file__).with_name("packagegraph") / "main.go"
    helper_digest = inv.sha(helper_source.read_bytes())
    helper = args.cache / "packagegraph"
    build = subprocess.run([str(args.go.resolve()), "build", "-p=1", "-trimpath", "-o", str(helper.resolve()), str(helper_source)],
                           env=dict(os.environ, GOMAXPROCS="1", GOTOOLCHAIN="local", GOENV="off", GOFLAGS="", GOPROXY="off", GOSUMDB="off", GOROOT=identity["root"]), capture_output=True)
    inv.require(build.returncode == 0, "import parser build failed: " + build.stderr.decode(errors="replace"))
    inv.require(inv.sha(helper_source.read_bytes()) == helper_digest, "import parser source changed during build")
    requests = [{"path": str((args.cache / "go" / name).resolve()), "relative": name, "sha256": inv.sha(files[name])} for name in wanted]
    inspected = subprocess.run([str(helper.resolve())], input=json.dumps(requests).encode(), capture_output=True, env={"GOMAXPROCS": "1"})
    inv.require(inspected.returncode == 0, "import parser failed: " + inspected.stderr.decode(errors="replace"))
    records = json.loads(inspected.stdout)
    inv.require([row["path"] for row in records] == wanted, "import parser input denominator mismatch")
    parsed = {row["path"]: row for row in records}
    ledger = [graph(root, parsed, files) for root in roots]
    data = "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in ledger).encode()
    if args.validate:
        inv.require(args.output.read_bytes() == data, "directory phase ledger differs from authenticated sources")
    else:
        args.output.write_bytes(data)
    print(json.dumps({"evidence_kind": "directory-phase-ledger", "execution_claim": False, "roots": len(ledger),
                      "tested_package_nodes": sum(len(row["tested_packages"]) for row in ledger),
                      "phase_obligations_per_mode": sum(len(row["phases"]) for row in ledger),
                      "tested_source_edges": sum(edge["kind"] == "tested-source-package" for row in ledger for edge in row["import_edges"]),
                      "unresolved_edges": sum(edge["kind"] == "unresolved-import" for row in ledger for edge in row["import_edges"]),
                      "parser_source_sha256": helper_digest, "parser_binary_sha256": inv.sha(helper.read_bytes()), "ledger_sha256": inv.sha(data)}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        print("FATAL: " + str(exc), file=sys.stderr)
        sys.exit(2)
