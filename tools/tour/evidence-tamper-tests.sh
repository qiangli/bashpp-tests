#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tour-evidence-tamper.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
cp "${ROOT}/tests/tour/evidence.jsonl" "${WORK}/synthetic.jsonl"
ruby -rjson -rdigest - "${WORK}/synthetic.jsonl" <<'RUBY'
path = ARGV[0]
rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
attempts = rows.select { |r| r['type'] == 'attempt' }
victim = attempts.find { |r| r['mode'] == 'baseline' }
%w[interpreted compiled].each do |mode|
  row = attempts.find { |r| r['path'] == victim['path'] && r['mode'] == mode }
  %w[command spawned state exit raw normalized].each { |key| row[key] = Marshal.load(Marshal.dump(victim[key])) }
  row['outcome'] = 'PASS'
end
counts = attempts.group_by { |r| r['outcome'] }.transform_values(&:length).sort.to_h
rows[-3]['outcomes'] = counts
canonical = ->(value) do
  sort = nil
  sort = ->(o) { o.is_a?(Hash) ? o.keys.sort.to_h { |k| [k, sort.call(o[k])] } : o.is_a?(Array) ? o.map { |v| sort.call(v) } : o }
  JSON.generate(sort.call(value))
end
rows[-2]['sha256'] = Digest::SHA256.hexdigest(rows[0...-2].map { |r| canonical.call(r) }.join("\n") + "\n")
rows[-1] = { 'type' => 'verdict', 'value' => counts == { 'PASS' => 291 } ? 'PASS' : 'FAIL', 'root_sha256' => rows[-2]['sha256'] }
File.open(path, 'wb') { |io| rows.each { |r| io.puts(canonical.call(r)) } }
RUBY
log="${WORK}/validator.log"
if TOUR_EVIDENCE="${WORK}/synthetic.jsonl" "${ROOT}/tools/tour/validate-evidence.sh" >"${log}" 2>&1; then
  echo "FAIL synthetic mutual-equality artifact was accepted" >&2
  exit 1
fi
grep -qF 'synthetic mutual-equality artifact' "${log}" || { sed -n '1,8p' "${log}" >&2; exit 1; }
echo "PASS synthetic mutual-equality artifact rejected after internally consistent root/summary rewrite"

# ---------------------------------------------------------------------------
# Exploit test: a forgery that DOES NOT trip the mutual-equality guard above.
# Every interpreted/compiled row across every program KEEPS its own real,
# correctly-bound mode-specific command (so command-binding checks pass and
# no row equals its sibling baseline's command) but has its process/raw
# fields — spawned, state, exit, raw, normalized, stage — overwritten with a
# copy of that SAME program's baseline row, claiming Bash++ reproduced Go's
# behavior everywhere. Every ledger hash, the summary, the root and the
# verdict are recomputed afterward so the file is fully internally
# consistent. A validator that only re-derives fields FROM the ledger (no
# live replay) cannot tell this apart from genuine evidence: MUST REJECT.
# ---------------------------------------------------------------------------
WORK2="$(mktemp -d "${TMPDIR:-/tmp}/tour-evidence-tamper.XXXXXX")"
trap 'rm -rf "${WORK}" "${WORK2}"' EXIT
cp "${ROOT}/tests/tour/evidence.jsonl" "${WORK2}/synthetic.jsonl"
ruby -rjson -rdigest - "${WORK2}/synthetic.jsonl" <<'RUBY'
path = ARGV[0]
rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
attempts = rows.select { |r| r['type'] == 'attempt' }
attempts.group_by { |r| r['path'] }.each_value do |group|
  baseline = group.find { |r| r['mode'] == 'baseline' }
  %w[interpreted compiled].each do |mode|
    row = group.find { |r| r['mode'] == mode }
    # 'command' is deliberately NOT touched: each row keeps its own real,
    # correctly-bound mode-specific command.
    %w[spawned state exit raw normalized stage].each { |key| row[key] = Marshal.load(Marshal.dump(baseline[key])) }
    row['outcome'] = 'PASS'
  end
end
counts = attempts.group_by { |r| r['outcome'] }.transform_values(&:length).sort.to_h
rows[-3]['outcomes'] = counts
canonical = ->(value) do
  sort = nil
  sort = ->(o) { o.is_a?(Hash) ? o.keys.sort.to_h { |k| [k, sort.call(o[k])] } : o.is_a?(Array) ? o.map { |v| sort.call(v) } : o }
  JSON.generate(sort.call(value))
end
rows[-2]['sha256'] = Digest::SHA256.hexdigest(rows[0...-2].map { |r| canonical.call(r) }.join("\n") + "\n")
rows[-1] = { 'type' => 'verdict', 'value' => counts == { 'PASS' => 291 } ? 'PASS' : 'FAIL', 'root_sha256' => rows[-2]['sha256'] }
File.open(path, 'wb') { |io| rows.each { |r| io.puts(canonical.call(r)) } }
RUBY
log2="${WORK2}/validator.log"
if TOUR_EVIDENCE="${WORK2}/synthetic.jsonl" "${ROOT}/tools/tour/validate-evidence.sh" >"${log2}" 2>&1; then
  echo "FAIL full-ledger baseline-cloning forgery (real commands, forged process/raw) was accepted" >&2
  exit 1
fi
grep -qF 'FATAL: replay' "${log2}" || { sed -n '1,8p' "${log2}" >&2; exit 1; }
echo "PASS full-ledger baseline-cloning forgery rejected by replay authentication"

# ---------------------------------------------------------------------------
# Provenance forgeries. Each ledger below is fully internally consistent (every
# hash/root/verdict recomputed) and — except the last — every manifest field is
# TRUE about the binary it names. They must still be rejected: evidence may
# only come from the exact pinned Go 1.27 builder and a clean published
# reproducible bashy, no matter how honestly a different toolchain describes
# itself.
# ---------------------------------------------------------------------------

reseal() { # <path>: recompute summary/root/verdict so the ledger balances
  ruby -rjson -rdigest -e '
    path = ARGV[0]
    rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    attempts = rows.select { |r| r["type"] == "attempt" }
    counts = attempts.group_by { |r| r["outcome"] }.transform_values(&:length).sort.to_h
    rows[-3]["outcomes"] = counts
    canonical = ->(value) do
      sort = nil
      sort = ->(o) { o.is_a?(Hash) ? o.keys.sort.to_h { |k| [k, sort.call(o[k])] } : o.is_a?(Array) ? o.map { |v| sort.call(v) } : o }
      JSON.generate(sort.call(value))
    end
    rows[-2]["sha256"] = Digest::SHA256.hexdigest(rows[0...-2].map { |r| canonical.call(r) }.join("\n") + "\n")
    rows[-1] = { "type" => "verdict", "value" => counts == { "PASS" => 291 } ? "PASS" : "FAIL", "root_sha256" => rows[-2]["sha256"] }
    File.open(path, "wb") { |io| rows.each { |r| io.puts(canonical.call(r)) } }
  ' "$1"
}

# --- 1. a dev/dirty bashy, truthfully self-described, is not clean published
# reproducible evidence. Every manifest field about it is accurate; the
# published/dirty policy alone must refuse it.
# ---------------------------------------------------------------------------
WORK3="$(mktemp -d "${TMPDIR:-/tmp}/tour-evidence-tamper.XXXXXX")"
trap 'rm -rf "${WORK}" "${WORK2}" "${WORK3}" "${WORK4:-}" "${WORK5:-}"' EXIT
FAKE_BASHY="${WORK3}/fake-bashy"
printf '#!/usr/bin/env bash\necho "bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-dev (da8deb9-dirty)"\n' > "${FAKE_BASHY}"
chmod +x "${FAKE_BASHY}"
cp "${ROOT}/tests/tour/evidence.jsonl" "${WORK3}/synthetic.jsonl"
ruby -rjson -rdigest - "${WORK3}/synthetic.jsonl" "${FAKE_BASHY}" <<'RUBY'
path, fake = ARGV
rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
version_line = "bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-dev (da8deb9-dirty)"
rows[0]['bashy'] = {
  'path' => fake, 'present' => true, 'sha256' => Digest::SHA256.hexdigest(File.binread(fake)),
  'version' => version_line, 'source_revision' => 'da8deb9', 'published' => false,
  'reproducible' => false, 'build_recipe' => 'workspace dev build'
}
File.open(path, 'wb') { |io| rows.each { |r| io.puts(JSON.generate(r)) } }
RUBY
reseal "${WORK3}/synthetic.jsonl"
log3="${WORK3}/validator.log"
if TOUR_EVIDENCE="${WORK3}/synthetic.jsonl" "${ROOT}/tools/tour/validate-evidence.sh" >"${log3}" 2>&1; then
  echo "FAIL truthfully-described dirty/dev bashy build was accepted" >&2
  exit 1
fi
grep -qF 'FATAL: bashy build is dirty or unpublished' "${log3}" || { sed -n '1,8p' "${log3}" >&2; exit 1; }
echo "PASS dirty/dev bashy build (truthfully self-described) rejected"

# --- 2. a real host toolchain that is not the pinned Go 1.27 builder —
# e.g. the host Go 1.26 — truthfully self-described with its true checksum,
# must be rejected by the pin cross-check, not merely by self-consistency.
# ---------------------------------------------------------------------------
GOOS="$(uname -s | tr '[:upper:]' '[:lower:]')"
GOARCH="$(uname -m)"
PINNED_IDENTITY="$(awk -F '\t' -v goos="${GOOS}" -v goarch="${GOARCH}" '$1 !~ /^#/ && NF && $1 == goos && $2 == goarch { print $4; exit }' "${ROOT}/docs/tour/toolchain.tsv")"
HOST_GO="$(command -v go || true)"
HOST_IDENTITY=""
[ -n "${HOST_GO}" ] && HOST_IDENTITY="$("${HOST_GO}" version | head -1)"
if [ -n "${HOST_GO}" ] && [ -n "${PINNED_IDENTITY}" ] && [ "${HOST_IDENTITY}" != "${PINNED_IDENTITY}" ]; then
  WORK4="$(mktemp -d "${TMPDIR:-/tmp}/tour-evidence-tamper.XXXXXX")"
  cp "${ROOT}/tests/tour/evidence.jsonl" "${WORK4}/synthetic.jsonl"
  ruby -rjson -rdigest - "${WORK4}/synthetic.jsonl" "${HOST_GO}" "${HOST_IDENTITY}" <<'RUBY'
path, go_path, identity = ARGV
rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
rows[0]['go'] = {
  'path' => go_path, 'present' => true, 'sha256' => Digest::SHA256.hexdigest(File.binread(go_path)),
  'version' => identity, 'identity' => identity,
  'pinned_sha256' => Digest::SHA256.hexdigest(File.binread(go_path))
}
File.open(path, 'wb') { |io| rows.each { |r| io.puts(JSON.generate(r)) } }
RUBY
  reseal "${WORK4}/synthetic.jsonl"
  log4="${WORK4}/validator.log"
  if TOUR_EVIDENCE="${WORK4}/synthetic.jsonl" "${ROOT}/tools/tour/validate-evidence.sh" >"${log4}" 2>&1; then
    echo "FAIL truthfully-described non-pinned Go builder (${HOST_IDENTITY}) was accepted" >&2
    exit 1
  fi
  grep -qF 'not the pinned Go 1.27 toolchain' "${log4}" || { sed -n '1,8p' "${log4}" >&2; exit 1; }
  echo "PASS non-pinned Go builder (${HOST_IDENTITY}) rejected by toolchain pin cross-check"
else
  echo "NOTE host go is the pinned toolchain here; non-pinned-builder forgery not exercisable on this host"
fi

# --- 3. a fabricated bashy version string paired with the real binary's true
# checksum: internally perfect and the string itself parses as a clean
# published release — only re-deriving the string from the live binary can
# catch it.
# ---------------------------------------------------------------------------
WORK5="$(mktemp -d "${TMPDIR:-/tmp}/tour-evidence-tamper.XXXXXX")"
cp "${ROOT}/tests/tour/evidence.jsonl" "${WORK5}/synthetic.jsonl"
ruby -rjson - "${WORK5}/synthetic.jsonl" <<'RUBY'
path = ARGV[0]
rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
rows[0]['bashy']['version'] = 'bashy, GNU Bash 5.3 compatible, version 5.3.0(1)-bashy-0.19.0'
rows[0]['bashy']['source_revision'] = '0.19.0'
File.open(path, 'wb') { |io| rows.each { |r| io.puts(JSON.generate(r)) } }
RUBY
reseal "${WORK5}/synthetic.jsonl"
log5="${WORK5}/validator.log"
if TOUR_EVIDENCE="${WORK5}/synthetic.jsonl" "${ROOT}/tools/tour/validate-evidence.sh" >"${log5}" 2>&1; then
  echo "FAIL fabricated bashy version string (self-consistent, parses as published) was accepted" >&2
  exit 1
fi
grep -qF 'FATAL: exact bashy version mismatch' "${log5}" || { sed -n '1,8p' "${log5}" >&2; exit 1; }
echo "PASS fabricated bashy version string rejected by live version re-derivation"
