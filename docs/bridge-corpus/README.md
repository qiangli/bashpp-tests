# Bridge corpus — the Go stdlib the bash++ bridge actually exposes

This directory is the W6-initial slice of the Go-bridge work: it derives,
from the `sh` source that implements the bridge, the actual list of Go
standard-library packages exposed to bash++ scripts, inventories the pinned
upstream Go 1.27.0 test files belonging to that list, and maps each part of
that inventory to the obligation a real bridge-execution claim would have to
discharge. The inventory claims no bridge behaviour. The native runner now executes the
178 host-exposed package suites as a separate Go oracle; it grants no Bash++
execution credit.

## What the bridge actually is (read from `sh`, not from prose)

Two mechanisms in `sh` put Go packages in front of a bash++ script:

1. **The reviewed import inventory (parser + interpreter gate).**
   `sh/syntax/go127stdlib_generated.go` holds `go127StdlibImports`, a closed
   list of **180** import paths generated from the sum.golang.org-authenticated
   Go 1.27.0 toolchain module (union of `go tool dist list` × `go list std`,
   filtered by `publicStdlibPath` in `sh/syntax/gen_go127stdlib.go`, which
   drops `cmd/*`, `builtin`, and any path with an `internal`, `vendor`,
   `testdata` or `*_test` element). The list's joined bytes are pinned by the
   generator's reviewed `inventorySHA256`
   (`de444f71…cd927e289f6c`). `syntax.BashPPStdlibImportAllowed` is the
   membership predicate; the interpreter consults it after `go list` reports
   a package as standard (`interp/bashpp_import.go`, `nativeBashPPEvaluator.Resolve`).

2. **The capability policy and the toolchain adapter (execution path).**
   `interp/bashpp_eval.go` classifies every imported package from `go list
   -e -json` facts (`classifyBashPPPackage`) and applies a single decision
   table (`bashPPPolicyFor`): `capReviewedStdlib` and `capExternalPureGo`
   reach the reviewed-toolchain adapter (`policyToolchain`); `capCgo`,
   `capCompiledOnly`, `capNotBuildable`, `capUnreviewedStdlib`, `capMissing`
   and the zero value `capUnknown` all **refuse**. Execution itself
   (`nativeBashPPEvaluator.Call`/`Values`) generates a temporary
   `package main` that imports the resolved packages, builds it with the
   identity-verified Go 1.27.0 toolchain (`bashPPGoReviews` digest table),
   runs the binary, and — for value calls — marshals results through
   `encoding/json`.

The **lowered (transpiled) mode** resolves imports through
`sh/lower/module_importer.go` (`go/importer` + structural resolver); the
exposed-package derivation here is the interpreted-mode surface, and the
dual-mode obligation (O8) records that the lowered mode owes the same
coverage.

## The derived exposed list

* **180** packages are in the reviewed inventory — every one is inventoried
  in [`stdlib-inventory.tsv`](stdlib-inventory.tsv); none is dropped.
* On the derivation host (darwin/arm64, pinned Go 1.27.0 toolchain),
  **178** classify `capReviewedStdlib` — importable through the bridge
  under the runtime's own rules. **2 are refused with code-derived
  reasons**: `plugin` (`cgo` — "package requires cgo, which this pure-Go
  shell does not provide") and `syscall/js` (`not-buildable` on this host —
  "build constraints exclude all Go files"). These are the policy's own
  refusal classes, read out of `sh`; this slice invents no exclusions.
* Capability is **host-relative by construction**: the runtime asks `go
  list` on the running host. A different GOOS/GOARCH can move a package
  between classes; re-run `tools/bridge-corpus/derive-stdlib.sh` there.

Provenance chain, recorded in [`bridge-pin.tsv`](bridge-pin.tsv) and
re-verified by `tools/bridge-corpus/verify.sh`: sh commit + per-file digests
of the four bridge files; toolchain identified three ways (bin/go SHA-256
matching `sh`'s review table, the sum.golang.org module ziphash, and the
src/ tree hash matching the generator's reviewed `sourceSHA256`).

## The upstream test inventory

[`upstream-tests.tsv`](upstream-tests.tsv) holds one row per `*_test.go`
file directly inside each reviewed package's directory of the pinned Go
1.27.0 source. `go test <pkg>` selects applicable files using host constraints;
the inventory retains the other files too. **1135 files**
across the 180 packages (172 of them have test files), all inventoried
whether their package is exposed or refused:

| fact | count |
|---|---|
| black-box files (`package X_test`) | 604 |
| in-package files (`package X`) | 529 |
| other (package clause neither — `syscall/js`, unnameable on this host) | 2 |
| files in exposed packages | 1132 |
| files in refused packages | 3 |
| `Test*` / `Benchmark*` / `Example*` / `Fuzz*` entrypoints | 6817 / 1660 / 914 / 44 |
| files importing `internal/*` paths | 610 |
| files carrying `//go:build` constraints | 213 |

Upstream source is BSD-3-Clause; this repository stores only metadata
(paths, sizes, digests, mechanically derived counts), never upstream bytes.

This supersedes — numerically, by measurement — the root README/PLAN's old
Tier-2 claim ("~150 `*_test.go` files" across six packages). Those files are
outside this slice's ownership and were not edited; this README records the
measured numbers so the stale figure is not mistaken for a denominator.

## The obligations

[`obligations.tsv`](obligations.tsv) maps the inventory to what a real
bridge-execution claim must answer for. Summary of the nine rows:

* **O1** — 178 exposed packages each need an `import` + selector call that
  actually completes through the interpreted bridge. Precondition for
  everything else.
* **O2** — 405 out-of-tree-capable black-box files. Key derived fact: a
  hand-generated testmain faces specific TestMain/fuzz/internal import
  limitations, even though SDK `testing.go` (pinned at 2428) exports
  `testing.Main`. Native `go test` dispatch can measure bridge plumbing, but
  does not discharge execution of unchanged test bodies by Bash++. An exact
  [driver contract](test-body-driver-contract.md) defines `testing.Main`
  interpreter callbacks; implementing and executing it remains product work.
* **O3** — 198 black-box files importing `internal/*`: native Go compilation
  must satisfy internal-package visibility. The interpreter-owned package
  graph and test driver remain to be specified.
* **O4** — 529 in-package files: tests must share the tested package scope,
  including test-only declarations and `export_test.go` additions. Native
  in-tree dispatch alone does not establish interpreted test-body execution.
* **O5** — 211 build-constrained files: host-relative applicability,
  re-derived per host; counted, never excluded.
* **O6/O7** — 3 files whose packages the runtime policy refuses (cgo,
  host-unbuildable): recorded with the code-derived refusal strings;
  discharging them requires an `sh` policy change or a different host
  profile, both outside this slice.
* **O8** — the lowered/transpiled mode owes the same import surface
  (`sh/lower/module_importer.go`) as a dual-mode differential.
* **O9** — the certification boundary, made enforceable.

## The certification boundary (the thing this slice refuses to fudge)

**Running the pinned Go toolchain's `go test` natively certifies the Go
toolchain and nothing else.** The bridge is exercised only when the
dispatch itself goes through bash++ — import resolution via the runtime's
`go list` path, selector/value call marshaling into a generated
`package main`, build by the identity-verified toolchain, JSON result
ingestion. Even then, what such a run certifies is the *bridge plumbing*,
not stdlib semantics: the stdlib code under test is upstream's, compiled by
upstream's toolchain. `verify.sh` enforces `executed = no` on every
obligation row so native runs cannot be claimed as bridge evidence. The
O2–O4 rows currently describe native plumbing carriers, not a completed
interpreter-owned test-body driver contract; that contract remains open.

## Tools

* `tools/bridge-corpus/derive-stdlib.sh` — extracts the reviewed inventory
  from `sh` (verifying it against sh's own `inventorySHA256`), verifies the
  pinned toolchain three ways, and classifies all 180 packages with the
  runtime's own rule order. Writes `stdlib-inventory.tsv` + `bridge-pin.tsv`.
* `tools/bridge-corpus/inventory-tests.sh` — inventories `*_test.go` files
  from the authenticated source tree. Writes `upstream-tests.tsv`, updates
  the pin.
* `tools/bridge-corpus/verify.sh` — the offline gate: pin structure, data
  digests, the joined-path hash back to sh's reviewed constant, the policy
  decision table, obligation denominators recomputed from the stated
  filters, `executed=no` enforced; with `BRIDGE_GO_ROOT`/`BRIDGE_SH_ROOT`
  it re-hashes all 1135 files and the sh bridge files. Tamper-tested:
  corrupted digests, dropped rows, denominator drift, `executed` claims and
  a wrong toolchain tree all fail closed.
* `tools/bridge-corpus/bridgecorpus.go` — mechanical helper (tree hashing
  with the generator's exact framing, capability classification mirroring
  `classifyBashPPPackage`, per-file test facts).
* `tools/bridge-corpus/listsha.sh` — offline joined-list digest.

This slice owns only `tools/bridge-corpus/` and `docs/bridge-corpus/`; it
is not yet wired into `harness/run.sh` (that wiring is a later slice's
decision, and the gate is runnable standalone today).

## Native oracle delivery and remaining acceptance

`tools/bridge-corpus/native.rb` authenticates the complete 180-row inventory
against reviewed data and path-list SHA-256 pins before selecting the 178
exposed packages. It rejects duplicates, malformed rows, changed policy or
source facts, missing package terminals, unexpected packages, duplicate test
terminals, unfinished tests, and an SDK from a different host profile. Its
summary retains the inventory digest and both policy refusals (`plugin`,
`syscall/js`). SDK authentication runs before and after execution. Native
FAIL remains FAIL; no outcome grants product execution credit.

Example invocation, with the matching authenticated SDK identity and cache:

```sh
ruby tools/bridge-corpus/native.rb --inventory docs/bridge-corpus/stdlib-inventory.tsv \
  --sdk-identity /path/to/go-full-sdk-identity.json \
  --source-cache /path/to/go-full \
  --fixtures /path/to/bridge-fixtures/manifest.json \
  --evidence /path/to/new-evidence-directory
ruby tools/bridge-corpus/native_test.rb
```

The retained first run at
`/Users/qiangli/.bashy/sprint118/evidence/bridge-native-001` reports
**155 package PASS, 14 FAIL, 9 SKIP**, with 81,263 runtime test starts and
81,263 terminals, no incomplete events, and intact SDK bytes afterward.
Its verdict is **FAIL**, and `product_execution_claim` is false. This run
predates the runner's inventory-record addition; its exact 178 distinct
command arguments and raw logs retain the historical package membership.
Do not rewrite this evidence to imply the newer validator produced it.

The 13 failed crypto packages require external test vectors that the empty
module cache and `GOPROXY=off` could not supply. They are `crypto/cipher`,
`crypto/dsa`, `crypto/ecdh`, `crypto/ecdsa`, `crypto/ed25519`, `crypto/hkdf`,
`crypto/hmac`, `crypto/mldsa`, `crypto/mlkem`, `crypto/pbkdf2`, `crypto/rsa`,
`crypto/tls`, and `crypto/x509`. The `runtime` package additionally fails
`TestMkmalloc` for the unavailable `golang.org/x/tools` module, and
`TestMemoryLimit`/`TestMemoryLimitNoGCPercent` because those tests require an
initial GOMAXPROCS of at least 4 while this approved run caps it at 2.
These are measured environment failures, not justified skips or Bash++ bugs.
Any follow-up must authenticate the external fixtures and retain the original
results and exact resource settings.

All nine package skips report `[no test files]`. The stream also retains
346 individual test skips and their output. The source-bound review tool
binds every skip to exact upstream events, source positions or declarations,
and the native environment. It grants no product execution credit. The
[driver contract](test-body-driver-contract.md) is now specified separately;
its implementation remains a parent product obligation. The repaired native
run described below preserves this initial FAIL evidence.


## Authenticated fixtures and repaired native profile

`tools/bridge-corpus/fixtures.py` derives five exact root versions from the
immutable SDK: Wycheproof, ed25519vectors, BoringSSL, x509-limbo, and x/tools.
Wycheproof and x/tools also have SDK `go.sum` checksums. The other three have
SDK version pins but no SDK checksums; their downloads are authenticated by
Go with `GOSUMDB=sum.golang.org`. The authenticated module graph has 65 modules.
[`fixture-lock.json`](fixture-lock.json) records all module versions, module
sums, archive/go.mod SHA-256 hashes, and extracted-file manifest hashes.
Fixture source files remain outside the SDK and outside this repository.

```sh
python3 tools/bridge-corpus/fixtures.py provision \
  --sdk-identity /path/to/go-full-sdk-identity.json --path /path/to/new-fixtures
python3 tools/bridge-corpus/fixtures.py validate \
  --sdk-identity /path/to/go-full-sdk-identity.json \
  --path /path/to/new-fixtures/manifest.json
python3 tools/bridge-corpus/fixtures_test.py
python3 tools/bridge-corpus/skips_test.py
```

Provisioning retains every download command, environment, raw response, and
checksum check. `--resume` resumes an incomplete attempt and gives subsequent
command logs distinct names; completed manifests cannot be overwritten.
Validation checks source/version bindings, exact graph membership, reviewed
checksums, and all extracted bytes. The native runner requires this manifest
and authenticates it before and after execution, setting the explicit
`GOMODCACHE` while keeping `GOPROXY=off` during tests.

The repaired resource profile uses `GOMAXPROCS=4`, the minimum required by the
unchanged runtime memory-limit tests, `GOFLAGS=-p=1` for nested Go package
builds, and outer `-p=1 -parallel=2`. The upstream BoringSSL runner's own
`-num-workers` default remains `runtime.NumCPU()`; it is not silently changed
by the harness. A separate SDK probe records 12 CPUs and GOMAXPROCS 4 on this
host. Process/RSS samples retain observed child commands and resource use.

The complete repaired run is retained at
`/Users/qiangli/.bashy/sprint118/evidence/bridge-native-002`.
No source files or original tests were rewritten to repair the environment.
It reports **169 package PASS, 9 SKIP, and zero FAIL**, with **124,873
runtime starts and 124,873 terminals**, no incomplete events, and intact SDK
and fixtures afterward. Elapsed native time was 768.705 seconds. The raw
185,693,750-byte stdout SHA-256 is
`d728dfa61d3993c4c39d3798ef4e8899e273324a781dabc136414c6316bcde0a`.
The repaired fixtures enabled 43,610 more dynamically registered tests than
the first run. Native success still grants no product coverage.

The source-bound skip report is generated with:

```sh
python3 tools/bridge-corpus/skips.py --native /path/to/native-evidence \
  --sdk-identity /path/to/go-full-sdk-identity.json --output /path/to/new-review
```

Every observed skip terminal is retained with raw log positions and source
hashes. Positioned reasons must resolve to a unique SDK callsite. Silent skips
retain their original test declaration and context. The 2,229 BoringSSL
skips additionally bind the SDK result-to-`SkipNow` adapter and the
authenticated BoringSSL `errUnimplemented`-to-SKIP mapping. Its temporary
`results.json` was removed by upstream cleanup; the individual skip events
and mapping source are retained, and that evidence limit is explicit. Package-level no-test
skips additionally retain actual `go list -json` host selection and original
source fingerprints. Exact conditions and candidate messages are evidence
for independent applicability review, never newly invented exclusions.

## SDK relocation boundary for the official product runner

The official full product runner originally compares whole SDK identity JSON,
including three location fields: `root`, `source_archive.path`, and
`distribution_archive.path`. Moving an unchanged SDK therefore triggers a
false identity mismatch. A narrow repair should permit only these three
location changes, require every other field to remain exactly equal, and
reauthenticate the complete relocated SDK using `sdk.py` before and after use.
Require and retain the relocation manifest and original identity record as
path provenance. Preserve the historical native summary and commands without
rewriting their original paths. This is a proposal for the manager-owned
`tools/go-full` code; the bridge corpus does not edit that runner.
