#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/tour/pin.tsv"
OUT="${ROOT}/tests/tour/inventory.tsv"
CACHE="${ROOT}/.cache/tour/src"

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r _repo _ref commit _license _provenance _expected_rows _inventory_data_sha256 <<<"${pin_row}"

inventory_only=0
src="${CACHE}"
if [ "${1:-}" = "--inventory-only" ]; then
  inventory_only=1
  src="${2:?usage: tools/tour/refresh.sh --inventory-only TOUR_ROOT}"
fi

if [ "${inventory_only}" -eq 0 ]; then
  if [ ! -d "${src}/.git" ]; then
    mkdir -p "$(dirname "${src}")"
    git clone https://go.googlesource.com/tour "${src}"
  fi
  git -C "${src}" fetch --depth 1 origin "${commit}"
  git -C "${src}" checkout --detach "${commit}"
fi

[ -f "${src}/LICENSE" ] || { echo "FATAL: missing upstream LICENSE in ${src}" >&2; exit 2; }
[ "$(find "${src}" -type f -name '*.md' -not -path '*/.git/*' | wc -l | tr -d ' ')" -gt 0 ] || {
  echo "FATAL: pinned source contains no Markdown pages" >&2
  exit 2
}

ruby -rdigest -e '
root = ARGV.fetch(0)
commit = ARGV.fetch(1)
rows = []

Dir.glob("#{root}/**/*.go").sort.each do |file|
  path = file.delete_prefix(root + "/")
  data = File.binread(file)
  kind = path.end_with?("_test.go") ? "go_test_source" : "go_package_source"
  rows << [
    path,
    kind,
    "n/a",
    "not_applicable_support_package",
    "exception:none",
    "baseline:go-test-or-build;bpp_interpreted:parse-or-run;bpp_compiled:transpile-build-run",
    data.bytesize,
    Digest::SHA256.hexdigest(data),
  ]
end

Dir.glob("#{root}/**/*.md").sort.each do |md_path|
  rel = md_path.delete_prefix(root + "/")
  lines = File.readlines(md_path, chomp: true)
  in_fence = false
  buf = []
  start_line = 0
  index = 0
  lines.each_with_index do |line, i|
    if line.match?(/^\s*```/)
      if in_fence
        text = buf.join("\n") + "\n"
        if text.include?("package main") || text.match?(/^\s*(type|var|func)\s/m)
          index += 1
          path = "%s#program-%02d-L%d" % [rel, index, start_line]
          applicability = text.include?("github.com/gin-gonic/gin") ? "excluded_external_dependency" : (text.include?("package main") ? "applicable_go_program" : "excluded_fragment")
          exception = applicability == "excluded_external_dependency" ? "exception:external_dependency" : (applicability == "excluded_fragment" ? "exception:fragment" : "exception:none")
          schema = applicability == "applicable_go_program" ? "baseline:go-run;bpp_interpreted:parse-run;bpp_compiled:transpile-build-run" : "baseline:syntax-context-only;bpp_interpreted:not-run;bpp_compiled:not-run"
          rows << [path, "markdown_code_program", start_line, applicability, exception, schema, text.bytesize, Digest::SHA256.hexdigest(text)]
        end
        in_fence = false; buf = []
      else
        in_fence = true; start_line = i + 2; buf = []
      end
    elsif in_fence
      buf << line
    end
  end
  abort "FATAL: unterminated Markdown code fence: #{rel}" if in_fence
end

puts "# release\tgolang/tour@#{commit}"
puts "# source\thttps://go.googlesource.com/tour"
puts "# license\tBSD-3-Clause"
puts "# generated_by\ttools/tour/refresh.sh"
puts "# path\tkind\tstart_line\tapplicability\texception\tdifferential_schema\tbytes\tsha256"
rows.sort_by!(&:first)
rows.each { |row| puts row.join("\t") }
' "${src}" "${commit}" > "${OUT}.tmp"

if [ "${inventory_only}" -eq 1 ]; then
  cat "${OUT}.tmp"
  rm "${OUT}.tmp"
else
  mv "${OUT}.tmp" "${OUT}"
  "${ROOT}/tools/tour/validate.sh"
fi
