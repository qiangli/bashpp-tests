#!/usr/bin/env ruby
# Sprint: #117; Story: #9; Story-ID: e400885f8746
# Independent metadata contract; does not invoke or share parsing with the runner.
require 'digest'
require 'json'

ROOT = File.expand_path('../..', __dir__)
PHASES = File.join(ROOT, 'docs/lowering/go-profile-phases.tsv')
HEADER = "id\tphase\tsource_sha256\treason\tpublic_test_ref".freeze
MANIFEST_HEADER = "id\tcategory\tfixture\texpected_status\tstdout\tstderr\tpublic_test_ref".freeze
IDENTITY_DIGEST = 'e6887c2b294f2db738d2f685a2e68c3f64152ce31a61bb27475f4ce60db69e3c'.freeze
SEMANTIC_REJECTIONS = %w[
  assert-impossible-neg cap-type-neg struct-literal-mixed-neg typed-overflow-neg
  for-cond-nonboolean-neg if-cond-nonboolean-neg range-scalar-arity-neg
  switch-case-type-neg assign-kind-mismatch-neg const-overflow-int8-neg
  short-decl-no-new-neg cannot-infer-neg constraint-violation-neg
  missing-method-neg undefined-receiver-neg
].sort.freeze
RUNTIME_ERRORS = %w[
  assert-fail-neg nil-deref-neg readonly-clear-neg readonly-bypass-neg panic-unrecovered
].sort.freeze

def require_contract(condition, message)
  raise message unless condition
end

def data_lines(text)
  text.lines(chomp: true).reject { |line| line.empty? || line.start_with?('#') }
end

# The original manifests remain the authority for source paths, public refs,
# statuses and exact streams. A frozen ordered identity digest prevents a
# same-count replacement of an approved case from changing the denominator.
originals = []
[
  ['go-profile-cases.tsv', 'go-profile', 52],
  ['profile-additional.tsv', 'profile-additional', 68]
].each do |manifest, folder, count|
  lines = data_lines(File.binread(File.join(ROOT, 'docs/lowering', manifest)))
  require_contract(lines.shift == MANIFEST_HEADER, "bad original manifest header: #{manifest}")
  require_contract(lines.length == count, "original manifest count changed: #{manifest}")
  lines.each do |line|
    fields = line.split("\t", -1)
    require_contract(fields.length == 7, "malformed original manifest row: #{manifest}")
    id, _category, fixture, status, stdout, stderr, reference = fields
    require_contract(status.match?(/\A(?:0|2)\z/), "unexpected original status for #{id}")
    require_contract(JSON.parse(stdout).is_a?(String) && JSON.parse(stderr).is_a?(String), "non-string streams for #{id}")
    fixture_root = File.realpath(File.join(ROOT, 'tests/lowering', folder))
    source = File.realpath(File.join(fixture_root, fixture))
    require_contract(source.start_with?(fixture_root + File::SEPARATOR), "fixture escapes its public root: #{id}")
    originals << { id: id, status: status.to_i, stdout: JSON.parse(stdout), stderr: JSON.parse(stderr),
                   reference: reference, sha256: Digest::SHA256.file(source).hexdigest }
  end
end
ids = originals.map { |row| row[:id] }
require_contract(ids.length == 120 && ids.uniq.length == 120, 'original 120 identities are not unique')
require_contract(Digest::SHA256.hexdigest(ids.join("\n") + "\n") == IDENTITY_DIGEST, 'approved ordered 120 identities changed')

def validate_phases(text, originals)
  lines = data_lines(text)
  require_contract(lines.shift == HEADER, 'phase header differs')
  rows = lines.map { |line| line.split("\t", -1) }
  require_contract(rows.all? { |row| row.length == 5 && row.all? { |field| !field.empty? && field.strip == field } }, 'malformed phase row')
  ids = rows.map(&:first)
  require_contract(ids.length == 120 && ids.uniq.length == 120, 'phase identities have omissions, extras or duplicates')
  require_contract(ids == originals.map { |row| row[:id] }, 'phase identities differ from original ordered identities')
  require_contract(rows.all? { |row| %w[artifact-run semantic-reject].include?(row[1]) }, 'unknown phase')
  rejected = rows.select { |row| row[1] == 'semantic-reject' }.map(&:first).sort
  require_contract(rejected == SEMANTIC_REJECTIONS, 'semantic-reject identities differ from the reviewed 15')
  require_contract(rows.count { |row| row[1] == 'artifact-run' } == 105, 'artifact-run denominator is not 105')
  runtime_errors = []
  rows.zip(originals).each do |row, original|
    id, phase, sha256, _reason, reference = row
    require_contract(sha256.match?(/\A[0-9a-f]{64}\z/) && sha256 == original[:sha256], "source hash mismatch: #{id}")
    require_contract(reference == original[:reference], "public reference mismatch: #{id}")
    if phase == 'semantic-reject'
      require_contract(original[:status] == 2 && original[:stdout].empty?, "semantic rejection changed the source observation: #{id}")
    elsif original[:status] != 0
      runtime_errors << id
    end
  end
  require_contract(runtime_errors.sort == RUNTIME_ERRORS, 'the five mandatory runtime errors changed phase')
  true
end

baseline = File.binread(PHASES)
validate_phases(baseline, originals)
mutations = {
  'missing identity' => baseline.lines.reject { |line| line.start_with?("nil-deref-neg\t") }.join,
  'extra identity' => baseline + "extra\tartifact-run\t#{'0' * 64}\treason\tpublic/ref\n",
  'duplicate identity' => baseline + baseline.lines.find { |line| line.start_with?("nil-deref-neg\t") },
  'same-count replacement' => baseline.sub("nil-deref-neg\t", "invented-case\t")
}
# Swap phases to retain 105/15 totals while violating both semantic identities.
mutations['runtime moved to rejection'] = baseline.sub("nil-deref-neg\tartifact-run\t", "nil-deref-neg\tsemantic-reject\t")
                                                .sub("assert-impossible-neg\tsemantic-reject\t", "assert-impossible-neg\tartifact-run\t")
mutations['unknown phase'] = baseline.sub("\tartifact-run\t", "\tunsupported\t")
mutations['source hash tamper'] = baseline.sub(/(\t)([0-9a-f]{64})(\t)/) { "#{$1}#{'0' * 64}#{$3}" }
mutations['public reference tamper'] = baseline.sub('sh/interp/bashpp_interface_test.go:', 'sh/interp/not-the-original_test.go:')
mutations['empty reason'] = baseline.sub(/(assert-fail-neg\tartifact-run\t[0-9a-f]{64}\t)[^\t]+\t/) { "#{$1}\t" }
mutations['extra column'] = baseline.lines.map { |line| line.start_with?("assert-fail-neg\t") ? line.chomp + "\textra\n" : line }.join
mutations.each do |label, text|
  require_contract(text != baseline, "no-op tamper: #{label}")
  rejected = false
  begin
    validate_phases(text, originals)
  rescue StandardError
    rejected = true
  end
  require_contract(rejected, "phase tamper accepted: #{label}")
end
puts "GO-PROFILE PHASES PASS: 120 identities, 105 artifact runs, 15 semantic rejections, 5 required runtime errors; #{mutations.length} tamper cases rejected"
