#!/usr/bin/env bash
# Tamper tests for the Go by Example corpus validator.
#
# A validator is only worth its exit code if something has actually tried to
# get past it. Each case below mutates one table or one file and asserts the
# validator REJECTS it. The count-only check that shipped in the first cut of
# this corpus passes cases 4, 5 and 6 below, which is why it was replaced with
# an exact path-set comparison.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="${ROOT}/tools/go-by-example/validate.sh"
DOCS="${ROOT}/docs/go-by-example"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

pass=0
fail=0

# The unmutated corpus must pass, or every rejection below is meaningless.
if ! "${V}" >/dev/null; then
  echo "FATAL: the checked-in corpus does not validate; tamper tests cannot run" >&2
  exit 2
fi

# Re-pin a mutated inventory so that the pin's data digest and row counts do not
# mask the specific defect a case is probing.
repin() { # <inventory> <pin-out>
  local inv="$1" out="$2" sha rows
  sha="$(awk '$0 !~ /^#/ && NF' "${inv}" | shasum -a 256 | awk '{ print $1 }')"
  rows="$(awk -F '\t' '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "${inv}")"
  awk -F '\t' -v OFS='\t' -v sha="${sha}" -v rows="${rows}" \
    '$1 ~ /^#/ { print; next } NF { $7 = rows; $8 = sha; print }' "${DOCS}/pin.tsv" > "${out}"
}

reject() { # <case-name> <env assignments...>
  local name="$1"; shift
  if env "$@" "${V}" >"${tmp}/out.$$" 2>&1; then
    echo "FAIL: expected rejection — ${name}"
    sed 's/^/      /' "${tmp}/out.$$"
    fail=$((fail + 1))
  else
    echo "ok: rejected ${name}"
    pass=$((pass + 1))
  fi
}

I="${DOCS}/inventory.tsv"
C="${DOCS}/classification.tsv"
S="${DOCS}/behavior-schema.tsv"

# --- path safety -----------------------------------------------------------
# 1. absolute path
awk -F '\t' -v OFS='\t' 'BEGIN { d = 0 } $1 ~ /^#/ { print; next } !d && $2 == "program" { $1 = "/" $1; d = 1 } { print }' "${I}" > "${tmp}/abs.tsv"
repin "${tmp}/abs.tsv" "${tmp}/abs.pin"
reject "absolute path in inventory" "GBE_INVENTORY=${tmp}/abs.tsv" "GBE_PIN=${tmp}/abs.pin"

# 2. parent traversal
awk -F '\t' -v OFS='\t' 'BEGIN { d = 0 } $1 ~ /^#/ { print; next } !d && $2 == "program" { sub(/^examples\//, "examples/../examples/", $1); d = 1 } { print }' "${I}" > "${tmp}/dotdot.tsv"
repin "${tmp}/dotdot.tsv" "${tmp}/dotdot.pin"
reject "parent traversal (..) in inventory path" "GBE_INVENTORY=${tmp}/dotdot.tsv" "GBE_PIN=${tmp}/dotdot.pin"

# 3. dot component
awk -F '\t' -v OFS='\t' 'BEGIN { d = 0 } $1 ~ /^#/ { print; next } !d && $2 == "program" { sub(/^examples\//, "examples/./", $1); d = 1 } { print }' "${I}" > "${tmp}/dot.tsv"
repin "${tmp}/dot.tsv" "${tmp}/dot.pin"
reject "single-dot component in inventory path" "GBE_INVENTORY=${tmp}/dot.tsv" "GBE_PIN=${tmp}/dot.pin"

# --- set integrity ---------------------------------------------------------
# 4. duplicate row (row COUNT rises, so a count check catches this one only by luck)
awk '$1 ~ /^#/ { print; next } { print } /arrays\/arrays\.go/ { print }' "${I}" > "${tmp}/dup.tsv"
repin "${tmp}/dup.tsv" "${tmp}/dup.pin"
reject "duplicate inventory row" "GBE_INVENTORY=${tmp}/dup.tsv" "GBE_PIN=${tmp}/dup.pin"

# 5. same-count SUBSTITUTION: one real path swapped for a fabricated sibling.
#    Row count, .go count and file count are all unchanged. Only a set
#    comparison sees this.
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } { sub(/examples\/arrays\/arrays\.go/, "examples/arrays/arrayz.go", $1); print }' "${I}" > "${tmp}/subst.tsv"
repin "${tmp}/subst.tsv" "${tmp}/subst.pin"
reject "same-count path substitution" "GBE_INVENTORY=${tmp}/subst.tsv" "GBE_PIN=${tmp}/subst.pin"

# 6. same-count TRANSPOSITION: two rows keep their paths but swap digests.
awk -F '\t' -v OFS='\t' '
  $1 ~ /^#/ { print; next }
  $1 == "examples/for/for.go" { a = $0; next }
  $1 == "examples/functions/functions.go" { b = $0; next }
  { print }
  END { }
' "${I}" > /dev/null
python3 - "${I}" "${tmp}/swap.tsv" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
idx = {}
for i, l in enumerate(lines):
    if l.startswith('#'):
        continue
    idx[l.split('\t')[0]] = i
a, b = idx['examples/for/for.go'], idx['examples/functions/functions.go']
fa, fb = lines[a].split('\t'), lines[b].split('\t')
fa[6], fb[6] = fb[6], fa[6]
fa[7], fb[7] = fb[7], fa[7]
lines[a], lines[b] = '\t'.join(fa), '\t'.join(fb)
open(dst, 'w').write('\n'.join(lines) + '\n')
PY
repin "${tmp}/swap.tsv" "${tmp}/swap.pin"
reject "transposed digests between two rows" "GBE_INVENTORY=${tmp}/swap.tsv" "GBE_PIN=${tmp}/swap.pin"

# 7. missing row: file on disk with no inventory row
grep -v 'examples/xml/xml\.go' "${I}" > "${tmp}/missing.tsv"
repin "${tmp}/missing.tsv" "${tmp}/missing.pin"
grep -v 'examples/xml/xml\.go' "${C}" > "${tmp}/missing.cls"
reject "inventory row missing for an on-disk file" \
  "GBE_INVENTORY=${tmp}/missing.tsv" "GBE_PIN=${tmp}/missing.pin" "GBE_CLASSIFICATION=${tmp}/missing.cls"

# 8. extra file: on-disk file with no inventory row
cp -R "${ROOT}/examples" "${tmp}/extra-tree"
mkdir -p "${tmp}/extra"; mv "${tmp}/extra-tree" "${tmp}/extra/examples"
printf 'package main\n' > "${tmp}/extra/examples/arrays/sneaked.go"
reject "extra on-disk file with no inventory row" "GBE_CORPUS=${tmp}/extra/examples"

# 9. deleted file: inventory row with no on-disk file
cp -R "${ROOT}/examples" "${tmp}/gone-tree"
mkdir -p "${tmp}/gone"; mv "${tmp}/gone-tree" "${tmp}/gone/examples"
rm "${tmp}/gone/examples/xml/xml.go"
reject "inventory row whose file was deleted" "GBE_CORPUS=${tmp}/gone/examples"

# 10. content drift: same size, different bytes
cp -R "${ROOT}/examples" "${tmp}/drift-tree"
mkdir -p "${tmp}/drift"; mv "${tmp}/drift-tree" "${tmp}/drift/examples"
python3 - "${tmp}/drift/examples/hello-world/hello-world.go" <<'PY'
import sys
p = sys.argv[1]
b = open(p, 'rb').read()
open(p, 'wb').write(b.replace(b'hello world', b'hello w0rld'))
PY
reject "content drift at unchanged byte count" "GBE_CORPUS=${tmp}/drift/examples"

# 11. byte-count drift
cp -R "${ROOT}/examples" "${tmp}/grow-tree"
mkdir -p "${tmp}/grow"; mv "${tmp}/grow-tree" "${tmp}/grow/examples"
printf '\n' >> "${tmp}/grow/examples/hello-world/hello-world.go"
reject "byte-count drift" "GBE_CORPUS=${tmp}/grow/examples"

# 12. runtime asset removed from disk
cp -R "${ROOT}/examples" "${tmp}/noasset-tree"
mkdir -p "${tmp}/noasset"; mv "${tmp}/noasset-tree" "${tmp}/noasset/examples"
rm "${tmp}/noasset/examples/embed-directive/folder/single_file.txt"
reject "embed runtime asset deleted" "GBE_CORPUS=${tmp}/noasset/examples"

# 13. symlink substituted for a copied source
cp -R "${ROOT}/examples" "${tmp}/link-tree"
mkdir -p "${tmp}/link"; mv "${tmp}/link-tree" "${tmp}/link/examples"
rm "${tmp}/link/examples/values/values.go"
ln -s /etc/hosts "${tmp}/link/examples/values/values.go"
reject "symlink standing in for a copied source" "GBE_CORPUS=${tmp}/link/examples"

# 14. unsorted inventory
python3 - "${I}" "${tmp}/unsorted.tsv" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
data = [i for i, l in enumerate(lines) if not l.startswith('#')]
a, b = data[0], data[1]
lines[a], lines[b] = lines[b], lines[a]
open(sys.argv[2], 'w').write('\n'.join(lines) + '\n')
PY
repin "${tmp}/unsorted.tsv" "${tmp}/unsorted.pin"
reject "inventory order regression" "GBE_INVENTORY=${tmp}/unsorted.tsv" "GBE_PIN=${tmp}/unsorted.pin"

# --- classification integrity ---------------------------------------------
# 15. normalization not licensed by any declared behavior
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/arrays/arrays.go" { $3 = "map_iteration"; $4 = "wallclock"; $5 = "none" } { print }' "${C}" > "${tmp}/unlic.cls"
reject "unlicensed normalization on a row" "GBE_CLASSIFICATION=${tmp}/unlic.cls"

# 16. required adapter missing
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/epoch/epoch.go" { $5 = "none" } { print }' "${C}" > "${tmp}/noadapter.cls"
reject "behavior declared without its required adapter" "GBE_CLASSIFICATION=${tmp}/noadapter.cls"

# 17. adapter not required by any declared behavior
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/epoch/epoch.go" { $5 = "fake_clock,stdin_fixture" } { print }' "${C}" > "${tmp}/extraadapter.cls"
reject "unlicensed adapter on a row" "GBE_CLASSIFICATION=${tmp}/extraadapter.cls"

# 18. deterministic combined with another behavior
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/arrays/arrays.go" { $3 = "clock,deterministic"; $4 = "wallclock"; $5 = "fake_clock" } { print }' "${C}" > "${tmp}/detmix.cls"
reject "deterministic combined with another behavior" "GBE_CLASSIFICATION=${tmp}/detmix.cls"

# 19. deterministic row carrying a normalization
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/arrays/arrays.go" { $4 = "map_order" } { print }' "${C}" > "${tmp}/detnorm.cls"
reject "deterministic row carrying a normalization" "GBE_CLASSIFICATION=${tmp}/detnorm.cls"

# 20. failure-derived / deferred state reintroduced
for token in n/a N/A PLANNED skipped exception; do
  awk -F '\t' -v OFS='\t' -v t="${token}" '$1 ~ /^#/ { print; next } $1 == "examples/http-client/http-client.go" { $3 = t; $4 = t; $5 = t } { print }' "${C}" > "${tmp}/na.cls"
  reject "failure-derived state '${token}' as a classification" "GBE_CLASSIFICATION=${tmp}/na.cls"
done

# 21. undeclared vocabulary term
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/arrays/arrays.go" { $3 = "quantum" } { print }' "${C}" > "${tmp}/vocab.cls"
reject "behavior term absent from the schema" "GBE_CLASSIFICATION=${tmp}/vocab.cls"

# 22. behavior set out of order / duplicated
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/goroutines/goroutines.go" { $3 = "timeout,concurrency" } { print }' "${C}" > "${tmp}/order.cls"
reject "unsorted behavior set" "GBE_CLASSIFICATION=${tmp}/order.cls"

# 23. not_a_program smuggled onto a program row
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/http-server/http-server.go" { $3 = "not_a_program"; $4 = "not_a_program"; $5 = "not_a_program" } { print }' "${C}" > "${tmp}/nap.cls"
reject "not_a_program on a program row" "GBE_CLASSIFICATION=${tmp}/nap.cls"

# 24. runtime asset reclassified as a program
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 ~ /single_file\.txt$/ { $2 = "program"; $3 = "deterministic"; $4 = "none"; $5 = "none" } { print }' "${C}" > "${tmp}/asset.cls"
reject "runtime asset reclassified as a program" "GBE_CLASSIFICATION=${tmp}/asset.cls"

# 25. required asset dropped from the requires closure -> orphan asset row
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 ~ /embed-directive\.go$/ { $6 = "none" } { print }' "${C}" > "${tmp}/orphan.cls"
reject "runtime asset required by no program" "GBE_CLASSIFICATION=${tmp}/orphan.cls"

# 26. requires an asset that is not inventoried
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 ~ /embed-directive\.go$/ { $6 = "examples/embed-directive/folder/absent.bin" } { print }' "${C}" > "${tmp}/ghost.cls"
reject "program requiring an uninventoried asset" "GBE_CLASSIFICATION=${tmp}/ghost.cls"

# 27. classification and inventory disagree on an axis
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } $1 == "examples/select/select.go" { $3 = "concurrency"; $5 = "bounded_wait" } { print }' "${C}" > "${tmp}/diverge.cls"
reject "classification diverging from the derived inventory" "GBE_CLASSIFICATION=${tmp}/diverge.cls"

# --- pin integrity ---------------------------------------------------------
# 28. inventory data digest drift
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } NF { $8 = "0000000000000000000000000000000000000000000000000000000000000000"; print }' "${DOCS}/pin.tsv" > "${tmp}/badsha.pin"
reject "pin inventory data digest drift" "GBE_PIN=${tmp}/badsha.pin"

# 29. pin commit drift
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } NF { $2 = "0000000000000000000000000000000000000000"; print }' "${DOCS}/pin.tsv" > "${tmp}/badcommit.pin"
reject "pin commit drift" "GBE_PIN=${tmp}/badcommit.pin"

# 30. license provenance stripped
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } NF { $4 = "UNKNOWN"; print }' "${DOCS}/pin.tsv" > "${tmp}/badlicense.pin"
reject "upstream license provenance stripped" "GBE_PIN=${tmp}/badlicense.pin"

# 31. .go denominator claim changed
awk -F '\t' -v OFS='\t' '$1 ~ /^#/ { print; next } NF { $9 = "84"; print }' "${DOCS}/pin.tsv" > "${tmp}/badcount.pin"
reject "upstream .go denominator changed" "GBE_PIN=${tmp}/badcount.pin"

# --- schema integrity ------------------------------------------------------
# 32. behavior requiring an undeclared adapter
awk -F '\t' -v OFS='\t' '$1 == "behavior" && $2 == "clock" { $3 = "time_machine" } { print }' "${S}" > "${tmp}/badschema.tsv"
reject "schema behavior requiring an undeclared adapter" "GBE_SCHEMA=${tmp}/badschema.tsv"

# 33. behavior allowing an undeclared normalization
awk -F '\t' -v OFS='\t' '$1 == "behavior" && $2 == "clock" { $4 = "handwave" } { print }' "${S}" > "${tmp}/badschema2.tsv"
reject "schema behavior allowing an undeclared normalization" "GBE_SCHEMA=${tmp}/badschema2.tsv"

# The execution adapter and toolchain probes belong to the still-open
# differential-runner story. This inventory-only tranche deliberately has no
# gate.sh, so claiming those probes here would be a false implementation.

# 34. the harness must fail, and must not invoke the subject binary, when the
#     corpus does not validate.
marker="${tmp}/target-invoked"
printf '#!/bin/sh\n: > %s\n' "${marker}" > "${tmp}/target"
chmod +x "${tmp}/target"
if GBE_INVENTORY="${tmp}/missing.tsv" GBE_PIN="${tmp}/missing.pin" BASHY_BIN="${tmp}/target" \
   "${ROOT}/harness/run.sh" >/dev/null 2>&1; then
  echo "FAIL: expected rejection — harness ran with an invalid Go by Example corpus"; fail=$((fail + 1))
else
  echo "ok: rejected harness run with an invalid Go by Example corpus"; pass=$((pass + 1))
fi
if [ -e "${marker}" ]; then
  echo "FAIL: harness invoked the subject binary after corpus validation failed"; fail=$((fail + 1))
else
  echo "ok: subject binary never invoked after corpus validation failed"; pass=$((pass + 1))
fi

echo
if [ "${fail}" -gt 0 ]; then
  echo "go-by-example tamper tests: ${pass} passed, ${fail} FAILED" >&2
  exit 1
fi
echo "go-by-example tamper tests OK: ${pass} defect classes rejected"
