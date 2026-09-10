# frozen_string_literal: true
# Sprint: #142; Story: #24; Story-ID: 605c7c4f2cad

require 'digest'
require 'json'
require ENV.fetch('GO_FULL_CORPUS_LIB', File.expand_path('../corpus/executor.rb', __dir__))

# Authentication and selection for named, arbitrary proper subsets of the
# official Go root inventory. The product driver calls this only after the
# complete inventory and all native observations have been joined.
module GoFullSubset
  SCHEMA = 'go-full-root-subset/v1'
  CLAIM_SCOPE = 'selected-roots-only; no axis or corpus verdict'
  OFFICIAL_ROOTS = 3495
  SHA256 = /\A[0-9a-f]{64}\z/
  NAME = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
  KEYS = %w[schema name claim_scope expected_count root_ids root_ids_sha256 inventory_sha256 runner_sha256 candidate_sha256].freeze
  CORPUS_SUMMARY_FIELDS = %w[verdict roots selected_root_denominator full_manifest_denominators selection_rule
                             all_runtime_tests_covered nested_process_instrumentation_complete generated_program_denominator_complete].freeze

  module_function

  def sha(value)
    Digest::SHA256.hexdigest(value.is_a?(String) ? value : Corpus.canonical(value))
  end

  def inventory_binding(inventory)
    sha(inventory.to_h { |name, record| [name, record.is_a?(Hash) ? record.fetch('sha256') : record] })
  end

  def runner_binding(paths)
    records = Array(paths).to_h { |path| [File.basename(path), Corpus.digest(path)] }
    raise Corpus::ContractError, 'duplicate subset runner filenames' unless records.length == Array(paths).length
    sha(records)
  end

  # Canonical filesystem identity of +path+: every existing component is
  # resolved through symlinks (dangling symlinks resolve through their
  # readlink target, since a later mkdir_p would follow them), while
  # non-existing trailing components are retained lexically so legitimate
  # not-yet-created subset directories still resolve against real ancestry.
  def canonical_path(path, depth = 0)
    raise Corpus::ContractError, 'subset evidence path exceeds symlink resolution depth' if depth > 40
    resolved = File::SEPARATOR
    File.expand_path(path).split(File::SEPARATOR).reject(&:empty?).each do |component|
      candidate = File.join(resolved, component)
      resolved = if File.symlink?(candidate)
                   target = File.readlink(candidate)
                   canonical_path(target.start_with?(File::SEPARATOR) ? target : File.expand_path(target, resolved), depth + 1)
                 else
                   candidate
                 end
    end
    resolved
  rescue SystemCallError => error
    raise Corpus::ContractError, "subset evidence path cannot be resolved: #{error.message}"
  end

  def overlapping?(evidence_form, root_form)
    evidence_form == root_form || evidence_form.start_with?(root_form + File::SEPARATOR) || root_form.start_with?(evidence_form + File::SEPARATOR)
  end

  # String ancestry is not filesystem ancestry on a case-insensitive volume:
  # two differently-cased path spellings can name the same inode.  Compare the
  # protected root's identity with every existing ancestor of the proposed
  # output (and vice versa) so an as-yet-uncreated leaf is covered too.  Do not
  # case-fold strings: on a case-sensitive filesystem those names are distinct.
  def filesystem_identity(path)
    stat = File.stat(path)
    [stat.dev, stat.ino]
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  rescue SystemCallError => error
    raise Corpus::ContractError, "subset evidence path cannot be inspected: #{error.message}"
  end

  def existing_ancestor_forms(path)
    ancestors = []
    current = File.expand_path(path)
    suffix = []
    loop do
      identity = filesystem_identity(current)
      ancestors << { path: current, identity: identity, suffix: suffix.dup } if identity
      parent = File.dirname(current)
      break if parent == current
      suffix.unshift(File.basename(current))
      current = parent
    end
    ancestors
  end

  # Prove case folding from the filesystem instead of assuming it from the
  # host OS. This keeps differently-cased names distinct on case-sensitive
  # volumes, including Linux, while allowing absent suffixes to be compared
  # according to the namespace in which they would later be created.
  def case_insensitive_ancestry?(path)
    current = File.expand_path(path)
    loop do
      identity = filesystem_identity(current)
      if identity
        basename = File.basename(current)
        alternate = basename.sub(/[A-Za-z]/) { |letter| letter == letter.downcase ? letter.upcase : letter.downcase }
        if alternate != basename
          alternate_identity = filesystem_identity(File.join(File.dirname(current), alternate))
          return true if alternate_identity == identity
        end
      end
      parent = File.dirname(current)
      break if parent == current
      current = parent
    end
    false
  end

  def suffixes_overlap?(left, right, case_insensitive:)
    shorter, longer = [left, right].sort_by(&:length)
    shorter.each_with_index.all? do |component, index|
      case_insensitive ? component.casecmp?(longer.fetch(index)) : component == longer.fetch(index)
    end
  end

  def filesystem_overlapping?(evidence_form, root_form)
    evidence_ancestors = existing_ancestor_forms(evidence_form)
    root_ancestors = existing_ancestor_forms(root_form)
    evidence_ancestors.each do |evidence_ancestor|
      root_ancestors.each do |root_ancestor|
        next unless evidence_ancestor.fetch(:identity) == root_ancestor.fetch(:identity)

        left = evidence_ancestor.fetch(:suffix)
        right = root_ancestor.fetch(:suffix)
        return true if suffixes_overlap?(left, right, case_insensitive: false)
        if case_insensitive_ancestry?(evidence_ancestor.fetch(:path)) ||
           case_insensitive_ancestry?(root_ancestor.fetch(:path))
          return true if suffixes_overlap?(left, right, case_insensitive: true)
        end
      end
    end
    false
  end

  # Lexical name/parent checks alone are spoofable: a lexical
  # subsets/<name> path can be a symlink resolving inside a protected
  # full-corpus evidence root. Ancestry is therefore enforced on both the
  # lexical and the canonically resolved forms of the evidence path and of
  # every protected root, before the caller performs any write.
  def protected_path!(evidence, name, protected_roots)
    evidence = File.expand_path(evidence)
    raise Corpus::ContractError, 'subset evidence must be named by its manifest under a subsets directory' unless File.basename(evidence) == name && File.basename(File.dirname(evidence)) == 'subsets'
    canonical_evidence = canonical_path(evidence)

    protected_roots.each do |root|
      root_forms = [File.expand_path(root), canonical_path(root)].uniq
      evidence_forms = [evidence, canonical_evidence].uniq
      root_forms.each do |root_form|
        evidence_forms.each do |evidence_form|
          if overlapping?(evidence_form, root_form) || filesystem_overlapping?(evidence_form, root_form)
            raise Corpus::ContractError, 'subset evidence overlaps a protected full-corpus evidence root'
          end
        end
      end
    end
    evidence
  end

  def load(path:, expected_sha256:, roots:, inventory:, candidate_path:, runner_paths:, evidence:, protected_roots: [])
    raise Corpus::ContractError, 'subset manifest SHA-256 is required' unless expected_sha256&.match?(SHA256)
    raise Corpus::ContractError, 'complete official inventory must be authenticated before subset selection' unless roots.length == OFFICIAL_ROOTS
    actual_sha256 = Corpus.digest(path)
    raise Corpus::ContractError, 'subset manifest changed' unless actual_sha256 == expected_sha256

    manifest = JSON.parse(File.read(path))
    raise Corpus::ContractError, 'unknown subset manifest fields' unless manifest.keys.sort == KEYS.sort
    raise Corpus::ContractError, 'invalid subset manifest schema' unless manifest['schema'] == SCHEMA
    name = manifest.fetch('name')
    raise Corpus::ContractError, 'invalid subset name' unless name.is_a?(String) && name.match?(NAME) && !name.start_with?('product-all-', 'native-', 'full-')
    raise Corpus::ContractError, 'subset attempted a corpus-level claim' unless manifest['claim_scope'] == CLAIM_SCOPE
    protected_path!(evidence, name, protected_roots)

    ids = manifest.fetch('root_ids')
    expected_count = manifest.fetch('expected_count')
    raise Corpus::ContractError, 'subset root IDs must be a sorted array of strings' unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && !id.empty? } && ids == ids.sort
    raise Corpus::ContractError, 'subset count differs from exact ID list' unless expected_count.is_a?(Integer) && expected_count.positive? && expected_count == ids.length
    raise Corpus::ContractError, 'subset must be a proper subset of the official corpus' unless expected_count < OFFICIAL_ROOTS
    raise Corpus::ContractError, 'duplicate subset root ID' unless ids.uniq.length == ids.length
    raise Corpus::ContractError, 'subset root ID digest differs' unless manifest['root_ids_sha256']&.match?(SHA256) && manifest['root_ids_sha256'] == sha(ids)

    by_id = roots.to_h { |root| [root.fetch('id'), root] }
    raise Corpus::ContractError, 'complete official inventory contains duplicate root IDs' unless by_id.length == OFFICIAL_ROOTS
    unknown = ids.reject { |id| by_id.key?(id) }
    raise Corpus::ContractError, 'unknown subset root ID: ' + unknown.first unless unknown.empty?
    raise Corpus::ContractError, 'subset inventory digest differs' unless manifest['inventory_sha256']&.match?(SHA256) && manifest['inventory_sha256'] == inventory_binding(inventory)
    raise Corpus::ContractError, 'subset runner digest differs' unless manifest['runner_sha256']&.match?(SHA256) && manifest['runner_sha256'] == runner_binding(runner_paths)
    raise Corpus::ContractError, 'subset candidate digest differs' unless manifest['candidate_sha256']&.match?(SHA256) && manifest['candidate_sha256'] == Corpus.digest(candidate_path)

    { 'manifest' => Corpus.file_record(path), 'runner' => Array(runner_paths).map { |runner_path| Corpus.file_record(runner_path) },
      'candidate' => Corpus.file_record(candidate_path), 'name' => name, 'claim_scope' => CLAIM_SCOPE,
      'expected_count' => expected_count, 'root_ids' => ids, 'root_ids_sha256' => manifest.fetch('root_ids_sha256'),
      'inventory_sha256' => manifest.fetch('inventory_sha256'), 'runner_sha256' => manifest.fetch('runner_sha256'),
      'candidate_sha256' => manifest.fetch('candidate_sha256'), 'roots' => ids.map { |id| by_id.fetch(id) } }
  rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => error
    raise Corpus::ContractError, "invalid subset manifest: #{error.message}"
  end

  def reauthenticate!(selection)
    %w[manifest candidate].each { |key| Corpus::Validation.file!(selection.fetch(key)) }
    selection.fetch('runner').each { |record| Corpus::Validation.file!(record) }
  end

  def summary(selection, rows, common)
    forbidden = common.keys & CORPUS_SUMMARY_FIELDS
    raise Corpus::ContractError, 'subset summary attempted corpus fields: ' + forbidden.sort.join(', ') unless forbidden.empty?
    ids = rows.map { |row| row.fetch('id') }
    raise Corpus::ContractError, 'subset result IDs differ from authenticated selection' unless ids == selection.fetch('root_ids')
    raise Corpus::ContractError, 'subset result denominator differs from authenticated selection' unless rows.length == selection.fetch('expected_count')
    reauthenticate!(selection)
    counts = rows.group_by { |row| row.fetch('axis') }.transform_values do |axis_rows|
      axis_rows.group_by { |row| row.fetch('product_verdict') }.transform_values(&:length)
    end
    common.merge('schema' => 'go-full-product-subset/v1', 'scope' => 'subset-only', 'claim_scope' => CLAIM_SCOPE,
      'name' => selection.fetch('name'), 'selected_root_count' => rows.length, 'selected_root_ids' => ids,
      'selected_root_ids_sha256' => selection.fetch('root_ids_sha256'), 'counts_by_axis' => counts,
      'selection' => selection.reject { |key, _| key == 'roots' }, 'per_root_verdicts' => rows.to_h { |row| [row.fetch('id'), row.fetch('product_verdict')] })
  end
end
