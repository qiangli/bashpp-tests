#!/usr/bin/env ruby
# Independent verification of a Go by Example evidence chain.
#
# Nothing here trusts a field the producer wrote about itself. Normalized
# output, effect digests, per-attempt verdicts, the summary and the root digest
# are all re-derived from the raw bytes plus the repository's own reviewed
# tables, and the resulting root must additionally appear in
# docs/go-by-example/evidence-roots.tsv: SHA-256 links fields together but
# cannot say who produced them, so authentication comes from a separately
# committed anchor, never from a self-consistent document.
require "base64"
require "digest"
require "json"
require "rbconfig"
require_relative "normalizer"
require_relative "candidate"

abort "usage: validate-evidence.rb EVIDENCE" unless ARGV.size == 1
root = File.expand_path("../..", __dir__)
sha = ->(path) { Digest::SHA256.file(path).hexdigest }
die = ->(message) { abort "FATAL: #{message}" }

EVIDENCE_SCHEMA = 8
MODES = %w[oracle interpreted compiled].freeze
STORY = "Sprint118/Story3/fa07603b71dc"
EFFECT_NORMALIZATIONS = %w[tmp_path].freeze
# Stage names each mode must record, in order, before its run. They are what
# stops a successful transpile from being read as an artifact that executed.
REQUIRED_STAGES = {
  "oracle" => [%w[oracle-build oracle-test-build]],
  "interpreted" => [],
  "compiled" => [%w[transpile]]
}.freeze

rows = File.readlines(ARGV[0], chomp: true).map { |line| JSON.parse(line) rescue die.call("invalid evidence JSON") }
die.call("evidence must be manifest, attempts, summary") unless rows.size >= 3 && rows.first["type"] == "manifest" && rows.last["type"] == "summary"
manifest, attempts, summary = rows.first, rows[1...-1], rows.last
die.call("unsupported evidence schema") unless manifest["schema"] == EVIDENCE_SCHEMA
die.call("wrong durable story binding") unless manifest["story"] == STORY

inventory_path = root + "/docs/go-by-example/inventory.tsv"
schema_path = root + "/docs/go-by-example/behavior-schema.tsv"
toolchain_path = root + "/docs/go-by-example/toolchain.tsv"
candidates_path = root + "/docs/go-by-example/candidates.tsv"
evidence_roots_path = root + "/docs/go-by-example/evidence-roots.tsv"
classification_path = root + "/docs/go-by-example/classification.tsv"
normalizer_path = root + "/tools/go-by-example/normalizer.rb"

inventory = File.readlines(inventory_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }.select { |r| %w[program test_program].include?(r[1]) }
die.call("production inventory no longer has exactly 85 rows") unless inventory.size == 85
denominator = inventory.size * MODES.size
die.call("evidence must contain #{denominator} attempts") unless attempts.size == denominator
die.call("invalid manifest denominator/modes") unless manifest["denominator"] == {"rows" => inventory.size, "modes_per_row" => MODES.size, "attempts" => denominator} && manifest["modes"] == MODES

schema_rows = File.readlines(schema_path, chomp: true).map { |line| line.split("\t", -1) }.reject { |row| row.empty? || row[0].to_s.start_with?("#") }
registered_normalizations = schema_rows.map { |row| row[1] if row[0] == "normalization" }.compact
registered_adapters = schema_rows.map { |row| row[1] if row[0] == "adapter" }.compact
behaviors = schema_rows.each_with_object({}) { |row, acc| acc[row[1]] = {requires: row[2].to_s, allows: row[3].to_s} if row[0] == "behavior" }
die.call("behavior schema declares no behaviors, adapters or normalizations") if behaviors.empty? || registered_adapters.empty? || registered_normalizations.empty?
die.call("schema vocabularies must be unique") unless registered_adapters.uniq == registered_adapters && registered_normalizations.uniq == registered_normalizations
behaviors.each do |name, spec|
  spec[:requires].split(",").each { |adapter| die.call("behavior #{name} requires undeclared adapter #{adapter}") unless registered_adapters.include?(adapter) }
  spec[:allows].split(",").each { |norm| die.call("behavior #{name} allows undeclared normalization #{norm}") unless registered_normalizations.include?(norm) }
end
die.call("normalizer registry differs from production schema") unless registered_normalizations.sort == GoByExampleNormalizer::NAMES.sort
# An adapter names a control the gate performs. A registry entry no production
# code implements is exactly the "adapter name as evidence of determinism"
# failure Sprint 118 removed, so it is refused here as well as in the gate.
gate_adapters = File.read(root + "/tools/go-by-example/gate.rb")[/^ADAPTERS = %w\[([^\]]*)\]/, 1].to_s.split
die.call("schema declares an adapter the gate does not implement: #{(registered_adapters - gate_adapters).inspect}") unless (registered_adapters - gate_adapters).empty?
die.call("gate implements an adapter the schema does not declare: #{(gate_adapters - registered_adapters).inspect}") unless (gate_adapters - registered_adapters).empty?

inventory.each do |row|
  path = root + "/" + row[0]
  die.call("anchored corpus source mismatch: #{row[0]}") unless File.file?(path) && File.size(path).to_s == row[6] && sha.call(path) == row[7]
  row_normalizations = row[3] == "none" ? ["none"] : row[3].split(",")
  die.call("inventory uses an unregistered normalizer: #{row[0]}") unless (row_normalizations - registered_normalizations).empty?
end

classification = File.readlines(classification_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }
die.call("classification table has malformed rows") unless classification.all? { |row| row.size == 6 }
authored = classification.select { |row| %w[program test_program].include?(row[1]) }
die.call("inventory classification columns do not match the authored classification table") unless authored == inventory.map { |row| row[0, 6] }
authored.each do |path, kind, behavior, normalization, adapter, _requires|
  declared = behavior.split(",")
  die.call("row declares an unregistered behavior: #{path}") unless declared.all? { |name| behaviors.key?(name) }
  die.call("test_harness behavior and test_program kind must agree: #{path}") unless (kind == "test_program") == declared.include?("test_harness")
  die.call("deterministic is exclusive and must compare raw bytes: #{path}") if declared.include?("deterministic") && (declared.size != 1 || normalization != "none" || adapter != "none")
  adapters = adapter == "none" ? [] : adapter.split(",")
  normalizations = normalization == "none" ? [] : normalization.split(",")
  die.call("row uses an unregistered adapter: #{path}") unless (adapters - registered_adapters).empty?
  die.call("row uses an unregistered normalizer: #{path}") unless (normalizations - registered_normalizations).empty?
  required = declared.flat_map { |name| behaviors[name][:requires].split(",") }.reject { |name| name == "none" }
  die.call("declared behavior requires an adapter the row does not carry: #{path}") unless (required - adapters).empty?
  licensed_adapters = declared.flat_map { |name| behaviors[name][:requires].split(",") }
  die.call("row carries an adapter no declared behavior requires: #{path}") unless (adapters - licensed_adapters).empty?
  licensed_normalizations = declared.flat_map { |name| behaviors[name][:allows].split(",") }
  die.call("row carries a normalization no declared behavior licenses: #{path}") unless (normalizations - licensed_normalizations).empty?
end
die.call("standalone corpus integrity revalidation failed") unless system(root + "/tools/go-by-example/validate.sh", out: File::NULL)
corpus_root = Digest::SHA256.hexdigest(inventory.map { |r| "#{r[0]}\0#{r[7]}\n" }.join)

os = RbConfig::CONFIG["host_os"].sub(/darwin.*/, "darwin").sub(/linux.*/, "linux")
arch = RbConfig::CONFIG["host_cpu"].sub("aarch64", "arm64").sub("x86_64", "amd64")
toolpin = File.readlines(toolchain_path, chomp: true).reject { |x| x.empty? || x.start_with?("#") }.map { |x| x.split("\t", -1) }.find { |r| r[0] == os && r[1] == arch }
die.call("no local production anchor row") unless toolpin
# The candidate anchor is re-derived from candidates.tsv here, independently of
# whatever the evidence says about itself, and its declared SDK identity must be
# the same reviewed release the oracle used: a pass may never be assembled from
# a Go 1.27 oracle plus a candidate some other release actually built.
begin
  reviewed_candidate = GoByExampleCandidate.reviewed(candidates_path, manifest_sha256: manifest.dig("candidate", "manifest_sha256"))
rescue GoByExampleCandidate::Error => e
  die.call(e.message)
end
die.call("candidate pin was not built by the pinned Go toolchain: #{reviewed_candidate['go_identity'].inspect} != #{toolpin[3].inspect}") unless reviewed_candidate["go_identity"] == toolpin[3]

anchors = {
  "corpus_sha256" => sha.call(inventory_path), "corpus_root_sha256" => corpus_root,
  "behavior_schema_sha256" => sha.call(schema_path), "classification_sha256" => sha.call(classification_path),
  "normalizer_version" => GoByExampleNormalizer::VERSION,
  "normalizer_sha256" => sha.call(normalizer_path), "toolchain_sha256" => sha.call(toolchain_path),
  "go_sha256" => toolpin[4]
}
anchors.each { |key, value| die.call("manifest #{key} is not anchored to production") unless manifest[key] == value }

# --- candidate binding ------------------------------------------------------
# Sprint 98 anchored one executor digest. The Go-source front end is a launcher
# plus a `.real` payload plus a set of replaced runtime modules, so the whole
# candidate is re-derived here from candidates.tsv: both digests, the front-end
# version, the exact reviewed build recipe, the SDK identity, and every
# runtime repository at its exact reviewed commit, the lowering runtime and
# filebrowser included. Evidence produced against any other candidate is refused.
recorded = manifest["candidate"] || {}
die.call("evidence records no candidate binding") if recorded.empty?
die.call("candidates table is not anchored to production") unless recorded["candidates_sha256"] == sha.call(candidates_path)
{
  "manifest_sha256" => reviewed_candidate["manifest_sha256"],
  "launcher_sha256" => reviewed_candidate["launcher_sha256"],
  "payload_sha256" => reviewed_candidate["payload_sha256"],
  "frontend_version" => reviewed_candidate["frontend_version"],
  "build_recipe" => reviewed_candidate["build_recipe"],
  "go_identity" => reviewed_candidate["go_identity"]
}.each { |key, value| die.call("candidate #{key} is not the repository-reviewed value") unless recorded[key] == value }
die.call("candidate launcher and payload digests may not coincide") if recorded["launcher_sha256"] == recorded["payload_sha256"]
expected_repositories = reviewed_candidate["repositories"].map { |name, commit| {"name" => name, "commit" => commit} }
die.call("candidate runtime dependencies differ from the reviewed set: #{recorded['repositories'].inspect}") unless recorded["repositories"] == expected_repositories
die.call("candidate lowering runtime is not the reviewed mvdan.cc/sh/v3 commit") unless recorded["sh_module_commit"] == reviewed_candidate["repositories"]["sh"]
# The recorded recipe is part of what is being reviewed: an evidence chain that
# quietly reverts to `go run` or grants one mode extra environment is not the
# reviewed contract, whatever its hashes say.
recipe = manifest["recipe"] || {}
die.call("evidence does not record the reviewed three-mode recipe") unless MODES.all? { |m| recipe[m].to_s.length > 0 }
die.call("oracle recipe must build and run a native binary, never `go run`") unless recipe["oracle"].include?("go build") && !recipe["oracle"].include?("go run")
die.call("product recipes must use the unchanged-Go-source selector") unless recipe["interpreted"].include?("--source=go") && recipe["compiled"].include?("--source=go")
# Explicit multi-file input must use the product's own repeated --go-file. The
# alternative -- appending the second file as an operand -- makes the CLI hand it
# to the program as argv, so a one-file build would be compared against the
# oracle's two-file one and the divergence would be invisible.
die.call("evidence does not record the --go-file multi-file input contract") unless recipe["multi_file_input"] == "--go-file"
die.call("evidence declares an environment divergence between modes: #{recipe['declared_env_divergence'].inspect}") unless recipe["declared_env_divergence"] == []
# GOROOT/GOMODCACHE are the product runtime's import-resolution inputs. They are
# admissible only as part of the block EVERY mode receives; a chain that granted
# them to the interpreter alone would be a tooling exemption, and is refused.
die.call("evidence does not record the common runtime Go environment") unless recipe["common_runtime_go_env"] == %w[GOROOT GOMODCACHE GOCACHE]
die.call("evidence licenses an unreviewed effect normalization: #{recipe['effect_normalizations'].inspect}") unless recipe["effect_normalizations"] == EFFECT_NORMALIZATIONS
# The process, deadline and descendant primitives are the shared corpus ones,
# and the evidence has to name the exact reviewed bytes it used for them.
die.call("evidence does not record the shared corpus process primitives") unless recipe["process_primitives"].to_s.include?("Corpus.capture")
die.call("corpus executor is not anchored to production") unless recipe["corpus_executor_sha256"] == sha.call(root + "/tools/corpus/executor.rb")
if recipe.key?("runtime_config_sha256")
  die.call("runtime configuration helper is not anchored") unless recipe["runtime_config_sha256"] == sha.call(root + "/tools/go-by-example/runtime-config.rb")
  die.call("unreviewed telemetry configuration") unless recipe["runtime_telemetry"] == {"OTEL_TRACES_EXPORTER" => "none", "Go" => "pinned go telemetry off in each isolated HOME before effect baseline"}
end
die.call("input binding helper is not anchored to production") unless recipe["input_binding_sha256"] == sha.call(root + "/tools/go-by-example/inputs.rb")
die.call("run launcher is not anchored to production") unless recipe["launcher_source_sha256"] == sha.call(root + "/tools/go-by-example/launch.go")
# The isolation claim is bounded on purpose: no OS-level sandbox is built, so
# the evidence may not be worded as if the SDK or the source tree were denied.
die.call("evidence overstates isolation") unless recipe["source_absence"].to_s.include?("NOT an OS-level denial")

binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
expected_pairs = inventory.flat_map { |r| MODES.map { |mode| [r[0], mode] } }
actual_pairs = attempts.map { |r| [r["path"], r["mode"]] }
die.call("missing, duplicate, reordered, or foreign row/mode evidence") unless actual_pairs == expected_pairs

seen_stream_paths = {}
attempts.each do |attempt|
  body = attempt.reject { |key, _| key == "evidence_sha256" }
  die.call("result tampering detected") unless attempt["binding_sha256"] == binding && attempt["evidence_sha256"] == Digest::SHA256.hexdigest(JSON.generate(body))
  inventory_row = inventory.find { |row| row[0] == attempt["path"] }
  die.call("attempt kind differs from the inventory: #{attempt['path']}") unless attempt["kind"] == inventory_row[1]
  normalizations = inventory_row[3] == "none" ? [] : inventory_row[3].split(",")

  if recipe.key?("runtime_config_sha256") && attempt["state"] == "complete"
    config = attempt.fetch("configuration", {})
    die.call("completed attempt lacks verified telemetry setup") unless config["state"] == "complete" && config["go_mode"] == "off" && config["environment"] == {"OTEL_TRACES_EXPORTER" => "none"}
    setup = config.fetch("stages", [])
    die.call("invalid telemetry setup stages") unless setup.size == 2 && setup.all? { |stage| stage["state"] == "exited" && stage["exit"] == 0 && stage["environment"]["OTEL_TRACES_EXPORTER"] == "none" }
    die.call("invalid telemetry setup commands") unless setup[0]["argv"][1..] == ["telemetry", "off"] && setup[1]["argv"][1..] == ["env", "-json", "GOTELEMETRY", "GOTELEMETRYDIR"]
    begin
      mode = config.fetch("mode_file")
      actual_mode = Corpus.file_record(mode.fetch("path"))
      die.call("telemetry mode file changed") unless actual_mode.values_at("sha256", "bytes") == mode.values_at("sha256", "bytes") && File.binread(mode.fetch("path")).match?(/\Aoff(?: \d{4}-\d{2}-\d{2})?\z/)
      setup.each do |stage|
        die.call("telemetry setup SDK digest mismatch") unless Corpus.digest(stage.fetch("argv").first) == manifest.fetch("go_sha256")
        %w[stdout stderr].each do |stream|
          artifact = stage.fetch(stream)
          actual = Corpus.file_record(artifact.fetch("path"))
          die.call("telemetry setup raw log changed") unless actual.values_at("sha256", "bytes") == artifact.values_at("sha256", "bytes")
        end
      end
      observed = JSON.parse(File.read(setup.last.fetch("stdout").fetch("path")))
      die.call("telemetry query does not match configuration") unless observed["GOTELEMETRY"] == "off" && File.expand_path(File.join(observed.fetch("GOTELEMETRYDIR"), "mode")) == File.expand_path(mode.fetch("path"))
    rescue StandardError => error
      die.call("invalid retained telemetry configuration: #{error.message}")
    end
  end

  # --- stage separation ---
  stages = attempt["stages"]
  die.call("attempt records no stages: #{attempt['path']}:#{attempt['mode']}") unless stages.is_a?(Array) && !stages.empty?
  die.call("last recorded stage must be the run: #{attempt['path']}:#{attempt['mode']}") unless stages.last["stage"] == "run"
  REQUIRED_STAGES.fetch(attempt["mode"]).each_with_index do |allowed, index|
    die.call("missing #{allowed.join('/')} stage: #{attempt['path']}:#{attempt['mode']}") unless allowed.include?(stages[index].to_h["stage"])
  end
  die.call("interpreted mode may only record a run stage: #{attempt['path']}") if attempt["mode"] == "interpreted" && stages.size != 1
  stages.each do |stage|
    capture = stage["capture"]
    next unless capture
    %w[stdout stderr].each do |stream|
      artifact = capture.fetch(stream)
      path = File.realpath(artifact.fetch("path"))
      die.call("duplicate retained stage stream path") if seen_stream_paths.key?(path)
      seen_stream_paths[path] = true
      actual = Corpus.file_record(path)
      die.call("retained stage stream changed") unless actual.values_at("sha256", "bytes") == artifact.values_at("sha256", "bytes") && stage[stream + "_sha256"] == actual["sha256"]
      if stage["stage"] == "run"
        die.call("run raw bytes differ from retained capture") unless Base64.strict_decode64(attempt.fetch("raw_" + stream + "_b64")) == File.binread(path)
      end
    end
    %w[native_file generated_file source_map_file].each do |key|
      next unless stage[key]
      artifact = stage.fetch(key); actual = Corpus.file_record(artifact.fetch("path"))
      die.call("retained #{key} changed") unless actual.values_at("sha256", "bytes") == artifact.values_at("sha256", "bytes")
      die.call("retained native artifact is not a binary") if key == "native_file" && !Corpus.native_binary?(artifact.fetch("path"))
    end
    if stage["source_map_file"]
      mapping = JSON.parse(File.read(stage.fetch("source_map_file").fetch("path")))
      die.call("retained source map does not bind original inputs") unless Corpus.valid_source_map?(mapping, stage.fetch("generated_file"), stage.fetch("source_inputs"))
    end
  end
  run_stage = stages.last
  die.call("run stage disagrees with the attempt: #{attempt['path']}:#{attempt['mode']}") unless run_stage["spawned"] == attempt["spawned"] && run_stage["state"] == attempt["state"] && run_stage["exit"] == attempt["exit"]

  # --- the recorded input spelling, not just the recipe prose ---
  # A product stage that names more than one .go input must have named each of
  # them with --go-file. Appending the extra file as an operand would make the
  # CLI hand it to the program as argv, so a one-file build would have been
  # compared against the oracle's whole package with nothing in the streams to
  # show for it.
  if %w[interpreted compiled].include?(attempt["mode"])
    stages.each do |stage|
      argv = Array(stage["argv"])
      next if argv.empty?
      go_inputs = argv.each_with_index.select { |token, index| token.to_s.end_with?(".go") && argv[index - 1] != "-o" && argv[index - 1] != "--map" }.map(&:first)
      next if go_inputs.size <= 1
      if attempt["mode"] == "interpreted" && stage["stage"] == "run" && recipe.key?("multi_file_program_arguments")
        die.call("unreviewed multi-file argv contract") unless recipe["multi_file_program_arguments"] == "-- separator before program argv"
        if attempt["kind"] == "test_program"
          separator = argv.index("--")
          die.call("test driver arguments lack an explicit separator") unless separator && argv[(separator + 1)..] == ["-test.v"]
        end
      end
      flagged = argv.each_cons(2).count { |flag, value| flag == "--go-file" && value.to_s.end_with?(".go") }
      die.call("a multi-file product stage did not use the --go-file contract: #{attempt['path']}:#{attempt['mode']}:#{stage['stage']}") unless flagged == go_inputs.size
    end
  end
  if attempt["mode"] == "compiled" && attempt["spawned"]
    build = stages.find { |s| s["stage"] == "build" }
    die.call("a compiled run was recorded without a successful build stage: #{attempt['path']}") unless build && build["exit"] == 0 && build["state"] == "complete" && build["artifact_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
    transpile = stages.find { |s| s["stage"] == "transpile" }
    # A validated source map is part of the transpile artifact: an unparseable,
    # mis-positioned or mis-digested map means the stage did not produce what the
    # contract describes, and its build must not be read as if it had.
    die.call("a compiled run was recorded without a successful transpile stage: #{attempt['path']}") unless transpile && transpile["exit"] == 0 && transpile["generated_go_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) && transpile["source_map_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  # --- independently recomputed comparator inputs ---
  begin
    raw_stdout = Base64.strict_decode64(attempt.fetch("raw_stdout_b64"))
    raw_stderr = Base64.strict_decode64(attempt.fetch("raw_stderr_b64"))
    attempt["_normalized"] = [Base64.strict_encode64(GoByExampleNormalizer.normalize(raw_stdout, normalizations, :stdout)),
                              Base64.strict_encode64(GoByExampleNormalizer.normalize(raw_stderr, normalizations, :stderr))]
  rescue KeyError, ArgumentError
    die.call("invalid raw output encoding: #{attempt['path']}:#{attempt['mode']}")
  rescue StandardError
    attempt["_normalized"] = nil
  end
  if attempt.key?("effects_delta")
    licensed = normalizations & EFFECT_NORMALIZATIONS
    delta = attempt["effects_delta"]
    die.call("stored effect digest differs from the recorded delta: #{attempt['path']}:#{attempt['mode']}") unless attempt["effects_sha256"] == Digest::SHA256.hexdigest(delta)
    recomputed = begin
      licensed.empty? ? delta : GoByExampleNormalizer.normalize(delta, licensed, :stdout)
    rescue StandardError
      nil
    end
    die.call("effect listing was rewritten by an unlicensed normalization: #{attempt['path']}:#{attempt['mode']}") unless recomputed == delta
  else
    die.call("effect digest recorded without its delta: #{attempt['path']}:#{attempt['mode']}") if attempt["effects_sha256"]
  end
end

attempts.each_slice(MODES.size) do |triple|
  oracle = triple[0]
  triple.each do |attempt|
    recomputed = attempt.delete("_normalized")
    stored = [attempt["normalized_stdout_b64"], attempt["normalized_stderr_b64"]]
    if stored != (recomputed || [nil, nil])
      die.call("stored normalized output differs from independently recomputed bytes: #{attempt['path']}:#{attempt['mode']}")
    end
    expected =
      if !attempt["spawned"] || attempt["state"] != "complete" then "fail_incomplete"
      elsif recomputed.nil? || oracle["normalized_stdout_b64"].nil? || attempt["effects_sha256"].nil? then "fail_normalization"
      elsif attempt["mode"] == "oracle" then "pass"
      elsif attempt["exit"] != oracle["exit"] || recomputed != [oracle["normalized_stdout_b64"], oracle["normalized_stderr_b64"]] then "fail_mismatch"
      elsif oracle["effects_sha256"] && attempt["effects_sha256"] != oracle["effects_sha256"] then "fail_effects"
      else "pass"
      end
    die.call("per-attempt verdict is not derived from production evidence: #{attempt['path']}:#{attempt['mode']}") unless attempt["verdict"] == expected
  end
end

executed = attempts.count { |r| r["spawned"] }
failures = attempts.reject { |r| r["verdict"] == "pass" }.map { |r| "#{r['path']}:#{r['mode']}:#{r['verdict']}" }
complete_pass = attempts.all? { |r| r["spawned"] && r["state"] == "complete" && r["verdict"] == "pass" }
expected_summary = {"type" => "summary", "verdict" => (complete_pass && executed == denominator && failures.empty? ? "pass" : "fail"),
                    "denominator" => denominator, "attempt_records" => denominator, "executed" => executed,
                    "missing_or_unspawned" => denominator - executed, "failures" => failures}
                   .merge(anchors)
                   .merge("candidates_sha256" => sha.call(candidates_path),
                          "candidate_manifest_sha256" => reviewed_candidate["manifest_sha256"],
                          "launcher_sha256" => reviewed_candidate["launcher_sha256"],
                          "payload_sha256" => reviewed_candidate["payload_sha256"])
summary_without_root = summary.reject { |key, _| key == "root_digest" }
die.call("summary is not independently derived from anchored evidence") unless summary_without_root == expected_summary
summary_hash = Digest::SHA256.hexdigest(JSON.generate(summary_without_root))
evidence_root = Digest::SHA256.hexdigest(([binding] + attempts.map { |r| r["evidence_sha256"] } + [summary_hash]).join("\n"))
die.call("summary-bound root digest mismatch") unless summary["root_digest"] == evidence_root
die.call("verdict/path mismatch") unless ARGV[0].end_with?(".#{summary['verdict']}")

# Authentication: a separately reviewed, committed root. Kept after the
# independent derivations above so mutations get the most precise diagnosis.
# realpath, not expand_path: `root` comes from __dir__, which already resolved
# symlinks, so an unresolved /tmp -> /private/tmp would never match.
evidence_abs = (File.realpath(ARGV[0]) rescue File.expand_path(ARGV[0]))
evidence_id = evidence_abs.start_with?(root + "/") ? evidence_abs[(root.size + 1)..] : evidence_abs
root_anchors = File.readlines(evidence_roots_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map { |line| line.split("\t", -1) }
anchor = root_anchors.find { |row| row[0, 4] == [manifest["story"], evidence_id, summary["verdict"], evidence_root] }
die.call("evidence root is not anchored to reviewed production evidence") unless anchor
if summary["verdict"] == "pass"
  die.call("PASS requires denominator=executed=#{denominator}, missing=0, every attempt complete/pass, and no failures") unless summary["denominator"] == denominator && summary["executed"] == denominator && summary["missing_or_unspawned"] == 0 && failures.empty? && complete_pass
end
puts "PASS: authenticated #{summary['verdict']} evidence, denominator=#{denominator} executed=#{executed} missing=#{denominator - executed} root_digest=#{evidence_root}"
