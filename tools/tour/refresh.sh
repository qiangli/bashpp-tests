#!/usr/bin/env bash
# Derive the tour inventory from the pinned golang.org/x/website source.
#
# Acquisition path (authoritative, offline-verifiable):
#   go install golang.org/x/website/tour@<version>
# The tour binary embeds lesson assets from _content/tour
# (content.go: //go:embed _content/tour). This script derives the
# denominator from those same assets, mirroring the upstream oracle
# content_test.go: first line must be a //go:build comment containing OMIT;
# nobuild => not built; norun => built but not executed.
#
# Fail-closed: unresolved references, unknown directives, missing go.mod /
# LICENSE, or any .go file that is neither .play-referenced nor a solution
# aborts the derivation. PLANNED is never emitted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${ROOT}/docs/tour/pin.tsv"
SCHEMA="${ROOT}/docs/tour/differential-schema.tsv"
OUT="${ROOT}/tests/tour/inventory.tsv"
CACHE="${ROOT}/.cache/website/src"

pin_row="$(awk -F '\t' '$1 !~ /^#/ && NF { print; exit }' "${PIN}")"
IFS=$'\t' read -r _repo version commit go_mod_sum _license _provenance _rows _sha <<<"${pin_row}"

inventory_only=0
src="${CACHE}"
if [ "${1:-}" = "--inventory-only" ]; then
  inventory_only=1
  src="${2:?usage: tools/tour/refresh.sh --inventory-only WEBSITE_SRC_ROOT}"
fi

if [ "${inventory_only}" -eq 0 ]; then
  if [ ! -d "${src}/.git" ]; then
    mkdir -p "$(dirname "${src}")"
    git clone https://go.googlesource.com/website "${src}"
  fi
  git -C "${src}" fetch --depth 1 origin "${commit}"
  git -C "${src}" checkout --detach "${commit}"
fi

ruby -rdigest - "$src" "$version" "$commit" "$go_mod_sum" "$SCHEMA" > "${OUT}.tmp" <<'RUBY'
root, version, commit, go_mod_sum, schema_path = ARGV
tour = File.join(root, "_content", "tour")
fatal = ->(msg) { abort "FATAL: #{msg}" }

mod = File.readlines(File.join(root, "go.mod"), chomp: true).grep(/\Amodule /).first
fatal.call("go.mod is not module golang.org/x/website: #{mod.inspect}") unless mod == "module golang.org/x/website"
fatal.call("missing upstream LICENSE in #{root}") unless File.file?(File.join(root, "LICENSE"))
fatal.call("missing _content/tour in #{root}") unless File.directory?(tour)

# Applicability -> differential schema coupling comes from the same table the
# gate reads: docs/tour/differential-schema.tsv is the single source of truth.
couple = {}
File.readlines(schema_path, chomp: true).each do |l|
  next if l.empty? || l.start_with?("#")
  f = l.split("\t", -1)
  next if f.length != 2 # Section 1 vocabulary rows have 3 columns
  couple[f[0]] = f[1]
end
fatal.call("differential schema coupling table is empty") if couple.empty?

rows = []
exception_for = {
  "applicable_go_program" => "none",
  "build_only_go_program" => "none",
  "excluded_fragment" => "fragment",
}

referenced = Hash.new(0)
articles = Dir.glob(File.join(tour, "*.article")).sort
fatal.call("pinned source contains no tour articles") if articles.empty?

known_directive = /\A\.(play|image|code|link|video|iframe|caption|background|syntax)\b/
articles.each do |art|
  rel = art.delete_prefix(tour + "/")
  lines = File.readlines(art, chomp: true)
  in_block = false
  block_start = 0
  block = []
  block_index = 0
  lines.each_with_index do |l, i|
    if l.start_with?(".")
      fatal.call("unknown present directive in #{rel}: #{l}") unless l =~ known_directive
      if l.split.first == ".play"
        arg = l.split[1]
        fatal.call(".play without an argument in #{rel}: #{l}") if arg.nil?
        fatal.call(".play argument is not a .go path in #{rel}: #{arg}") unless arg.end_with?(".go")
        path = "_content/tour/#{arg}"
        fatal.call("unresolved .play reference in #{rel}: #{arg}") unless File.file?(File.join(root, path))
        referenced[path] += 1
      elsif l.split.first == ".image"
        arg = l.split[1].to_s.delete_prefix("/")
        fatal.call("unresolved .image asset in #{rel}: #{arg}") unless File.file?(File.join(root, "_content", arg))
      end
    end
    if l.start_with?("\t")
      block_start = i + 1 if block.empty?
      block << l
    elsif !block.empty?
      text = block.join("\n") + "\n"
      block_index += 1
      rows << [
        "_content/tour/#{rel}#inline-%02d-L%d" % [block_index, block_start],
        "article_inline_block",
        block_start.to_s,
        "excluded_fragment",
        "exception:fragment",
        couple.fetch("excluded_fragment"),
        text.bytesize,
        Digest::SHA256.hexdigest(text),
      ]
      block = []
    end
  end
  if !block.empty?
    text = block.join("\n") + "\n"
    block_index += 1
    rows << [
      "_content/tour/#{rel}#inline-%02d-L%d" % [block_index, block_start],
      "article_inline_block",
      block_start.to_s,
      "excluded_fragment",
      "exception:fragment",
      couple.fetch("excluded_fragment"),
      text.bytesize,
      Digest::SHA256.hexdigest(text),
    ]
  end
end

Dir.glob(File.join(tour, "**", "*.go")).sort.each do |file|
  path = file.delete_prefix(root + "/")
  lines = File.readlines(file, chomp: true)
  tag = lines.first.to_s
  fatal.call("first line is not a go:build comment: #{path}") unless tag.start_with?("//go:build ")
  fatal.call(%{build comment does not contain "OMIT": #{path}}) unless tag.include?("OMIT")
  text = File.binread(file)

  applicability =
    if tag.include?("nobuild") then "excluded_fragment"
    elsif tag.include?("norun") then "build_only_go_program"
    else "applicable_go_program"
    end
  exception = exception_for.fetch(applicability)

  # Reviewed allowlist: tour-UI-served page programs that are loaded directly
  # by the frontend (initial sandbox editor content) rather than via .play.
  ui_served = %w[_content/tour/welcome/sandbox.go]
  kind =
    if referenced.key?(path) then "lesson_play_program"
    elsif path.start_with?("_content/tour/solutions/") then "exercise_solution_program"
    elsif ui_served.include?(path) then "ui_sandbox_program"
    else fatal.call("inventoried .go file is neither .play-referenced, a solution, nor reviewed UI-served: #{path}")
    end

  rows << [
    path, kind, "n/a", applicability,
    "exception:#{exception}",
    couple.fetch(applicability) { fatal.call("no differential schema coupling for #{applicability}") },
    text.bytesize, Digest::SHA256.hexdigest(text),
  ]
end

referenced.each_key do |path|
  fatal.call(".play reference never inventoried: #{path}") unless rows.any? { |r| r[0] == path }
end

puts "# release\tgolang.org/x/website@#{version}"
puts "# commit\t#{commit}"
puts "# go_mod_sum\t#{go_mod_sum}"
puts "# source\thttps://go.googlesource.com/website"
puts "# license\tBSD-3-Clause"
puts "# generated_by\ttools/tour/refresh.sh"
puts "# path\tkind\tstart_line\tapplicability\texception\tdifferential_schema\tbytes\tsha256"
rows.sort_by!(&:first)
rows.each { |r| puts r.join("\t") }
RUBY

if [ "${inventory_only}" -eq 1 ]; then
  cat "${OUT}.tmp"
  rm -f "${OUT}.tmp"
else
  mv "${OUT}.tmp" "${OUT}"
  echo "refreshed ${OUT}; now update docs/tour/pin.tsv (rows + inventory_data_sha256) and run tools/tour/validate.sh" >&2
fi
