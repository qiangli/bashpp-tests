# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
#
# The reviewed-candidate binding shared by the gate and its independent
# validators.
#
# Sprint 98 bound one reproducible executor digest from docs/go-by-example/
# executor.tsv. The Go-source front end is not that shape: it is a Makefile
# tag-enabled build (`make build BASHY_GOSOURCE=1`) that installs a small
# launcher beside a large `.real` payload, and whose lowering runtime is a set
# of replaced sibling modules. So the authority moved to a manifest, and the
# manifest is authenticated by tools/corpus/executor.rb primitives rather than
# by a second implementation of them here.
#
# The CLI arg contract is `--candidate MANIFEST` (`GBE_CANDIDATE` for the
# environment spelling). A caller chooses WHICH reviewed candidate to run; it
# cannot introduce one, because every field of the manifest must equal a row of
# docs/go-by-example/candidates.tsv, starting with the manifest's own digest.
require "digest"
require "json"
require "rbconfig"
require_relative "../corpus/executor"

module GoByExampleCandidate
  class Error < StandardError; end

  ROOT = File.expand_path("../..", __dir__)
  DOCS = ROOT + "/docs/go-by-example"
  # A shipped launcher is a small stub beside its payload. A candidate whose
  # launcher IS the payload is a different artifact shape than the one reviewed,
  # so the two digests may never coincide.
  FIELDS = %w[manifest_sha256 launcher_sha256 payload_sha256 frontend_version go_identity build_recipe repositories].freeze

  module_function

  def host
    [RbConfig::CONFIG["host_os"].sub(/darwin.*/, "darwin").sub(/linux.*/, "linux"),
     RbConfig::CONFIG["host_cpu"].sub("aarch64", "arm64").sub("x86_64", "amd64")]
  end

  def table(path = DOCS + "/candidates.tsv")
    File.readlines(path, chomp: true)
        .reject { |line| line.empty? || line.start_with?("#") }
        .map { |line| line.split("\t", -1) }
  end

  # The reviewed row for this host, as a field hash. Malformed rows are a
  # repository defect, not something to fall back from.
  def reviewed(path = DOCS + "/candidates.tsv", manifest_sha256: nil)
    os, arch = host
    rows = table(path).select { |r| r[0] == os && r[1] == arch }
    raise Error, "duplicate reviewed candidate identity" unless rows.map { |r| r[2] }.uniq.size == rows.size
    row = manifest_sha256 ? rows.find { |r| r[2] == manifest_sha256 } : rows.last
    raise Error, "candidate manifest is not the repository-reviewed manifest (#{manifest_sha256})" if !row && manifest_sha256
    raise Error, "no repository-reviewed Bash++ candidate for #{os}/#{arch}" unless row
    raise Error, "reviewed candidate row is malformed" unless row.size == 9
    fields = FIELDS.zip(row[2..]).to_h
    %w[manifest_sha256 launcher_sha256 payload_sha256].each do |key|
      raise Error, "invalid reviewed candidate #{key}" unless fields[key].match?(/\A[0-9a-f]{64}\z/) && fields[key] !~ /\A0+\z/
    end
    raise Error, "reviewed candidate launcher and payload digests are identical" if fields["launcher_sha256"] == fields["payload_sha256"]
    raise Error, "reviewed candidate declares no frontend version" if fields["frontend_version"].to_s.empty?
    # Historical diagnostic builds used an optional tag. Final default builds
    # are equally admissible only when their exact recipe and all bytes match
    # the separately reviewed candidate row and manifest.
    version = fields["go_identity"].to_s.split[2]
    recipe = fields["build_recipe"].to_s
    explicit_release = version && recipe.include?("GOTOOLCHAIN=#{version}")
    pinned_sdk_path = version && recipe.include?("GOTOOLCHAIN=local") && recipe.match?(%r{(?:\A|\s)PATH=/[^\s:]+/golang\.org/toolchain@v0\.0\.1-#{Regexp.escape(version)}\.#{Regexp.escape(os)}-#{Regexp.escape(arch)}/bin(?::|\s|\z)})
    raise Error, "reviewed build recipe does not pin the Go toolchain: #{recipe.inspect}" unless explicit_release || pinned_sdk_path
    fields["repositories"] = parse_repositories(fields["repositories"])
    fields
  end

  def parse_repositories(value)
    pairs = value.to_s.split(";").map { |entry| entry.split("=", -1) }
    raise Error, "reviewed candidate repository list is malformed" unless !pairs.empty? && pairs.all? { |name, commit| name.to_s.match?(/\A[a-z0-9._-]+\z/) && commit.to_s.match?(/\A[0-9a-f]{40}\z/) }
    names = pairs.map(&:first)
    raise Error, "reviewed candidate repository list is unsorted or duplicated" unless names == names.sort && names.uniq == names
    pairs.to_h
  end

  # The toolchain identity is bound to the same reviewed release as the oracle,
  # so a pass can never be assembled from a Go 1.27 oracle plus a candidate some
  # other release actually built.
  def toolchain(path = DOCS + "/toolchain.tsv")
    os, arch = host
    row = File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }.find { |r| r[0] == os && r[1] == arch }
    raise Error, "no authenticated Go toolchain pin for #{os}/#{arch}" unless row
    {"version" => row[2], "identity" => row[3], "go_sha256" => row[4]}
  end

  # Where --candidate came from, in precedence order. Absent is a provisioning
  # error: there is no default candidate and no implicit fall-back to a binary
  # merely found on PATH.
  def manifest_path(argv_value)
    path = argv_value || ENV["GBE_CANDIDATE"]
    raise Error, "pass --candidate MANIFEST (or set GBE_CANDIDATE) naming the authenticated Bash++ candidate manifest; there is no default candidate" if path.to_s.empty?
    raise Error, "candidate manifest is not a readable file: #{path}" unless File.file?(path)
    File.realpath(path)
  end

  # Authenticate a supplied manifest against the reviewed table and the bytes on
  # disk. Returns the provenance the gate records; raises on any divergence.
  def authenticate(manifest_path, bashy, reviewed_row = nil, toolchain_row = nil)
    row = reviewed_row || reviewed(manifest_sha256: Corpus.digest(manifest_path))
    tool = toolchain_row || toolchain
    raise Error, "reviewed candidate go_identity #{row['go_identity'].inspect} is not the reviewed toolchain #{tool['identity'].inspect}" unless row["go_identity"] == tool["identity"]

    digest = Corpus.digest(manifest_path)
    raise Error, "candidate manifest is not the repository-reviewed manifest (#{digest})" unless digest == row["manifest_sha256"]
    manifest = JSON.parse(File.read(manifest_path))
    raise Error, "candidate manifest is not a JSON object" unless manifest.is_a?(Hash)

    %w[launcher_sha256 payload_sha256 frontend_version build_recipe].each do |key|
      raise Error, "candidate manifest #{key} differs from the reviewed table" unless manifest[key] == row[key]
    end
    declared = manifest["repositories"]
    raise Error, "candidate manifest declares no repositories" unless declared.is_a?(Array) && !declared.empty?
    supplied = declared.to_h { |repo| [File.basename(repo.fetch("path").to_s), repo["commit"]] }
    raise Error, "candidate manifest repository set differs from the reviewed runtime dependencies: #{supplied.keys.sort.inspect} vs #{row['repositories'].keys.inspect}" unless supplied == row["repositories"]

    raise Error, "Bash++ candidate launcher missing: #{bashy}" unless File.file?(bashy) && File.executable?(bashy)
    # Corpus owns launcher/payload digest authentication and the clean-exact-
    # revision check for every declared repository, including untracked files.
    provenance = Corpus.authenticate_candidate(File.expand_path(bashy), manifest)
    raise Error, "candidate payload is not a native binary" unless Corpus.native_binary?(File.expand_path(bashy) + ".real")

    sh = declared.map { |repo| repo.fetch("path") }.find { |path| module_name(path) == "mvdan.cc/sh/v3" }
    raise Error, "the authenticated candidate declares no mvdan.cc/sh/v3 lowering runtime; the compiled mode cannot build generated Go without it" unless sh
    provenance.merge(
      "manifest" => {"path" => manifest_path, "sha256" => digest},
      "sh_module" => {"path" => File.realpath(sh), "commit" => supplied.fetch(File.basename(sh))},
      "go_identity" => row["go_identity"],
      "candidates_sha256" => Corpus.digest(DOCS + "/candidates.tsv")
    )
  end

  def module_name(path)
    line = File.readlines(File.join(path, "go.mod"), chomp: true).find { |l| l.start_with?("module ") }
    line && line.split(" ", 2)[1].to_s.strip
  rescue SystemCallError
    nil
  end
end
