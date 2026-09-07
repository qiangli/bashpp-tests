#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'json'
require 'digest'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'pathname'

# Interpreted source-case observations only; this is not compiled-profile proof.
module GoProfile
  ROOT = File.expand_path('../../..', __dir__)
  PROFILE = __dir__
  TSV = File.join(ROOT, 'docs/lowering/go-profile-cases.tsv')
  HEADER = %w[id category fixture expected_status stdout stderr public_test_ref].freeze

  def self.contained?(path, root)
    path.start_with?(root + File::SEPARATOR)
  end

  def self.load_rows(path, profile)
    profile = File.realpath(profile)
    lines = File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }
    raise 'missing or invalid TSV header' unless lines.shift == HEADER.join("\t")
    ids, fixtures, realpaths = [], [], []
    rows = lines.map.with_index do |line, index|
      cells = line.split("\t", -1)
      raise "row #{index + 2}: expected seven columns" unless cells.length == HEADER.length
      id, category, fixture, status, stdout, stderr, ref = cells
      raise "invalid case ID #{id.inspect}" unless id.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      raise "duplicate case ID #{id}" if ids.include?(id)
      raise "invalid category #{category.inspect}" unless category.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      segments = fixture.split('/', -1)
      safe = segments.length >= 2 && segments.all? { |part| part.match?(/\A[a-z0-9][a-z0-9.-]*\z/) && !%w[. ..].include?(part) }
      raise "unsafe fixture path #{fixture.inspect}" unless safe && fixture.end_with?('.bpp') && segments.first == category
      raise "duplicate fixture #{fixture}" if fixtures.include?(fixture)
      full = File.join(profile, fixture)
      raise "missing fixture #{fixture}" unless File.file?(full)
      resolved = File.realpath(full)
      raise "fixture escapes profile: #{fixture}" unless contained?(resolved, profile)
      raise "duplicate fixture target #{fixture}" if realpaths.include?(resolved)
      raise "invalid expected_status for #{id}" unless status.match?(/\A(?:0|[1-9][0-9]*)\z/) && status.to_i <= 255
      out, err = JSON.parse(stdout), JSON.parse(stderr)
      raise "non-string expected output for #{id}" unless out.is_a?(String) && err.is_a?(String)
      raise "missing public test reference for #{id}" unless ref.match?(/\Ash\/interp\/[a-z0-9_]+_test\.go:Test[A-Za-z0-9_]+(?:\/[^\t]+)?\z/)
      ids << id
      fixtures << fixture
      realpaths << resolved
      { id: id, category: category, fixture: fixture, status: status.to_i, stdout: out, stderr: err, ref: ref }
    end
    raise 'empty fixture manifest' if rows.empty?
    inventory = Dir.glob(File.join(profile, '**', '*.bpp')).map { |file| Pathname.new(file).relative_path_from(Pathname.new(profile)).to_s }.sort
    raise "fixture inventory differs: unlisted=#{inventory - fixtures} missing=#{fixtures - inventory}" unless inventory == fixtures.sort
    rows
  end

  def self.select_rows(rows, cases)
    missing = cases - rows.map { |row| row[:id] }
    raise "unknown --case: #{missing.join(', ')}" unless missing.empty?
    cases.empty? ? rows : rows.select { |row| cases.include?(row[:id]) }
  end

  def self.matches?(row, run)
    run[:rc] == row[:status] && run[:stdout] == row[:stdout] && run[:stderr] == row[:stderr]
  end

  def self.options(args)
    opts = { cases: [], bin: ENV['BASH_ENGINE_BIN'] }
    until args.empty?
      flag = args.shift
      case flag
      when '--self-test' then opts[:self_test] = true
      when '--case', '--bin', '--artifacts'
        value = args.shift
        raise "missing value for #{flag}" if value.nil? || value.empty? || value.start_with?('--')
        if flag == '--case' then opts[:cases] << value else opts[flag.delete_prefix('--').to_sym] = value end
      else raise "unknown argument #{flag.inspect}"
      end
    end
    opts
  end

  def self.self_test
    Dir.mktmpdir('go-profile-self-test-') do |dir|
      profile = File.join(dir, 'profile')
      FileUtils.mkdir_p(File.join(profile, 'example'))
      fixture = File.join(profile, 'example', 'one.bpp')
      manifest = File.join(dir, 'cases.tsv')
      row = ['one', 'example', 'example/one.bpp', '2', '""', '"failure\\n"', 'sh/interp/bashpp_test.go:TestExample']
      reset = lambda do
        File.write(fixture, "false\n")
        File.write(manifest, HEADER.join("\t") + "\n" + row.join("\t") + "\n")
      end
      rejects = lambda do |label, &block|
        begin
          block.call
        rescue StandardError
          next
        end
        raise "self-test failed: accepted #{label}"
      end
      reset.call
      rows = load_rows(manifest, profile)
      rejects.call('deleted fixture') { File.delete(fixture); load_rows(manifest, profile) }
      reset.call
      rejects.call('duplicate ID') { File.open(manifest, 'a') { |f| f.puts(row.join("\t")) }; load_rows(manifest, profile) }
      reset.call
      rejects.call('nonexistent selected case') { select_rows(load_rows(manifest, profile), ['missing']) }
      reset.call
      rejects.call('path traversal') do
        bad = row.dup
        bad[2] = 'example/../outside.bpp'
        File.write(manifest, HEADER.join("\t") + "\n" + bad.join("\t") + "\n")
        load_rows(manifest, profile)
      end
      reset.call
      rejects.call('unlisted fixture before selection') do
        File.write(File.join(profile, 'example', 'extra.bpp'), "true\n")
        select_rows(load_rows(manifest, profile), ['one'])
      end
      File.delete(File.join(profile, 'example', 'extra.bpp'))
      reset.call
      rejects.call('non-integer status') do
        bad = row.dup
        bad[3] = 'error'
        File.write(manifest, HEADER.join("\t") + "\n" + bad.join("\t") + "\n")
        load_rows(manifest, profile)
      end
      observed = { rc: 1, stdout: '', stderr: "failure\n" }
      raise 'self-test accepted wrong nonzero status' if matches?(rows.first, observed)
      raise 'self-test rejected exact status' unless matches?(rows.first, observed.merge(rc: 2))
    end
    puts 'PASS: validator self-tests (deletion, duplicates, selection, containment, inventory, exact status)'
  end

  def self.main(args)
    opts = options(args)
    return self_test if opts[:self_test]
    # Validate the complete inventory before applying any requested subset.
    rows = select_rows(load_rows(TSV, PROFILE), opts[:cases])
    raise 'set BASH_ENGINE_BIN or pass --bin PATH' if opts[:bin].nil? || opts[:bin].empty?
    bin = File.realpath(opts[:bin])
    raise 'interpreter must be an executable file' unless File.file?(bin) && File.executable?(bin)
    artifacts = opts[:artifacts] ? File.expand_path(opts[:artifacts]) : Dir.mktmpdir('go-profile-artifacts-')
    root = File.realpath(ROOT)
    raise '--artifacts must be outside the repository' if artifacts == root || contained?(artifacts, root)
    FileUtils.mkdir_p(artifacts)
    artifacts = File.realpath(artifacts)
    raise '--artifacts must be outside the repository' if artifacts == root || contained?(artifacts, root)
    meta = { validator: 'tests/lowering/go-profile/validate.rb', mode: 'interpreted', bin: bin,
             bin_sha256: Digest::SHA256.file(bin).hexdigest, started: Time.now.utc.iso8601,
             selected: rows.map { |row| row[:id] }, ruby: RUBY_VERSION }
    File.write(File.join(artifacts, 'meta.json'), JSON.pretty_generate(meta) + "\n")
    failures = []
    File.open(File.join(artifacts, 'runs.jsonl'), 'w') do |records|
      rows.each do |row|
        out, err, status = Open3.capture3(bin, '--bashpp', row[:fixture], chdir: PROFILE)
        run = { rc: status.exitstatus, stdout: out, stderr: err }
        match = matches?(row, run)
        failures << row[:id] unless match
        base = File.join(artifacts, row[:id])
        File.binwrite(base + '.stdout', out)
        File.binwrite(base + '.stderr', err)
        File.write(base + '.rc', "#{status.exitstatus || "signal:#{status.termsig}"}\n")
        record = { id: row[:id], fixture: row[:fixture], fixture_sha256: Digest::SHA256.file(File.join(PROFILE, row[:fixture])).hexdigest,
                   public_test_ref: row[:ref], expected_status: row[:status], rc: status.exitstatus, signal: status.termsig,
                   stdout_bytes: out.bytesize, stderr_bytes: err.bytesize, match: match }
        records.puts(JSON.generate(record))
        puts "#{match ? 'ok' : 'FAIL'} #{row[:id]} expected=#{row[:status]} actual=#{status.exitstatus.inspect}"
      end
    end
    puts "Artifacts: #{artifacts}"
    raise "#{failures.length}/#{rows.length} cases mismatched: #{failures.join(', ')}" unless failures.empty?
    puts "PASS: #{rows.length}/#{rows.length} interpreted source cases matched exact status and streams"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    GoProfile.main(ARGV.dup)
  rescue StandardError => e
    warn "FAIL: #{e.message}"
    exit 1
  end
end
