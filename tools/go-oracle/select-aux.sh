#!/usr/bin/env bash
# Emit the auxiliary-input provenance inventory for the reviewed tranche.
#
# WHY. docs/go-corpus/inventory.tsv digests go/test/**/*.go and nothing else,
# because that is the corpus denominator. But a compiledir/rundir/run/runoutput
# test is not only its .go file: the driver also READS
#
#   * the sibling "<name>.out" expected-output file — whose ABSENCE is itself
#     load-bearing, because "no .out" means "this program must print nothing";
#     and
#   * the sibling "<name>.dir" directory, whose membership decides the package
#     grouping and the compile order, and which may hold non-.go inputs (.s, .h).
#
# None of that was digest-checked. A locally edited .out, a .out created where
# upstream ships none, an added .s, or a deleted package file would all have
# been executed and reported as an official-corpus result. This inventory closes
# that: every auxiliary byte the driver consumes is pinned here, and so is every
# consumed sidecar upstream deliberately does NOT ship.
#
# The rule is mechanical and outcome-blind, like the tranche selection itself.
#
# Usage: select-aux.sh <corpus-root> [tranche]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPUS_ARG="${1:?usage: select-aux.sh <corpus-root> [tranche]}"
TRANCHE="${2:-${ROOT}/docs/go-oracle/tranche-001.tsv}"
PIN="${ROOT}/docs/go-oracle/pin.tsv"

die() { echo "FATAL: $*" >&2; exit 2; }

[ -d "${CORPUS_ARG}/test" ] || die "corpus has no test/ directory: ${CORPUS_ARG}"
CORPUS="$(cd "${CORPUS_ARG}" && pwd)"

release="$(awk -F '\t' '$1 !~ /^#/ && NF { print $1; exit }' "${PIN}")"

# Actions whose execution READS the sibling "<name>.out". Kept in lockstep with
# checkExpectedOutput's call sites in tools/go-oracle/actions.go.
out_consuming() { case "$1" in run|rundir|runoutput) return 0 ;; *) return 1 ;; esac; }
# Actions whose execution READS the sibling "<name>.dir".
dir_consuming() { case "$1" in compiledir|rundir) return 0 ;; *) return 1 ;; esac; }

digest() { shasum -a 256 "$1" | awk '{print $1}'; }
# members <dir> — every regular file, path relative to <dir>, in C order.
members() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }

{
  printf '# release\t%s\n' "${release}"
  printf '# corpus_pin\tdocs/go-corpus/pin.tsv\n'
  printf '# tranche\tdocs/go-oracle/tranche-001.tsv\n'
  printf '# generated_by\ttools/go-oracle/select-aux.sh\n'
  printf '#\n'
  printf '# role\tpath\tpresence\tbytes\tsha256\n'
  printf '#\n'
  printf '# expected_output  the sibling "<name>.out". presence=absent (bytes 0,\n'
  printf '#                  sha256 "-") is a real assertion: upstream ships no .out\n'
  printf '#                  for this test, so its output must be empty.\n'
  printf '# dir_manifest     the sibling "<name>.dir". bytes is the number of regular\n'
  printf '#                  files it holds; sha256 digests the sorted listing of\n'
  printf '#                  "<relpath><TAB><sha256>" lines, so an ADDED or DELETED\n'
  printf '#                  member is caught as well as an edited one.\n'
  printf '# dir_input        a non-.go file inside a "<name>.dir". The .go members are\n'
  printf '#                  already digested by docs/go-corpus/inventory.tsv.\n'

  while IFS=$'\t' read -r p action; do
    case "${p}" in ''|\#*) continue ;; esac
    rel="${p#test/}"
    base="${rel%.go}"

    if out_consuming "${action}"; then
      outfile="${CORPUS}/test/${base}.out"
      if [ -f "${outfile}" ]; then
        printf 'expected_output\ttest/%s.out\tpresent\t%s\t%s\n' \
          "${base}" "$(wc -c < "${outfile}" | tr -d ' ')" "$(digest "${outfile}")"
      else
        printf 'expected_output\ttest/%s.out\tabsent\t0\t-\n' "${base}"
      fi
    fi

    if dir_consuming "${action}"; then
      dir="${CORPUS}/test/${base}.dir"
      [ -d "${dir}" ] || die "${p} declares action ${action} but has no sibling test/${base}.dir"
      listing=""
      count=0
      while IFS= read -r m; do
        [ -n "${m}" ] || continue
        listing+="${m}	$(digest "${dir}/${m}")
"
        count=$((count + 1))
      done < <(members "${dir}")
      [ "${count}" -gt 0 ] || die "test/${base}.dir holds no files"
      printf 'dir_manifest\ttest/%s.dir\tpresent\t%s\t%s\n' \
        "${base}" "${count}" "$(printf '%s' "${listing}" | shasum -a 256 | awk '{print $1}')"
      while IFS= read -r m; do
        case "${m}" in *.go|'') continue ;; esac
        printf 'dir_input\ttest/%s.dir/%s\tpresent\t%s\t%s\n' \
          "${base}" "${m}" "$(wc -c < "${dir}/${m}" | tr -d ' ')" "$(digest "${dir}/${m}")"
      done < <(members "${dir}")
    fi
  done < "${TRANCHE}"
}
