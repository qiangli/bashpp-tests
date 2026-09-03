#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'evidence'

normalizer = File.expand_path('normalize.rb', __dir__)
passed = 0
check = lambda do |name, condition|
  abort "FAIL #{name}" unless condition
  passed += 1; puts "PASS #{name}"
end

Dir.mktmpdir('tour-evidence-selftest') do |dir|
  missing = TourEvidence.capture([File.join(dir, 'does-not-exist')], chdir: dir, timeout: 1)
  check.call('actual launch failure is explicit', !missing['spawned'] && missing['state'] == 'launch_failure' && missing['exit'].nil?)

  captured = TourEvidence.capture(
    [RbConfig.ruby, '-e', '$stdout.binmode.write("out\\r\\n"); $stderr.binmode.write("err\\n"); exit 7'],
    chdir: dir, timeout: 1
  )
  check.call('actual exit and raw streams are retained',
             captured['spawned'] && captured['state'] == 'exited' && captured['exit'] == 7 &&
             captured['stdout'] == "out\r\n".b && captured['stderr'] == "err\n".b)

  signaled = TourEvidence.capture(
    [RbConfig.ruby, '-e', 'Process.kill("TERM", Process.pid)'], chdir: dir, timeout: 1
  )
  check.call('actual signal exit is mapped deterministically',
             signaled['spawned'] && signaled['state'] == 'exited' && signaled['exit'] == 143)

  deadline = TourEvidence.capture([RbConfig.ruby, '-e', 'sleep 20'], chdir: dir, timeout: 1)
  check.call('actual deadline is bounded', deadline['spawned'] && deadline['state'] == 'deadline' && deadline['exit'].nil?)

  pidfile = File.join(dir, 'descendant.pid')
  source = <<~'RUBY'
    child = spawn(RbConfig.ruby, '-e', 'sleep 20')
    File.write(ARGV[0], child.to_s)
    sleep 20
  RUBY
  tree = TourEvidence.capture([RbConfig.ruby, '-rrbconfig', '-e', source, pidfile], chdir: dir, timeout: 1)
  child = Integer(File.read(pidfile)); sleep 0.1
  alive = begin
    Process.kill(0, child)
    true
  rescue Errno::ESRCH
    false
  end
  check.call('deadline kills descendant process group', tree['state'] == 'deadline' && !alive)

  baseline_raw = { 'stdout' => "same\n".b, 'stderr' => ''.b }
  changed_raw = { 'stdout' => "changed\n".b, 'stderr' => ''.b }
  baseline = { 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'normalized' => TourEvidence.derived(baseline_raw, normalizer) }
  same = { 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'normalized' => TourEvidence.derived(baseline_raw, normalizer) }
  changed = { 'spawned' => true, 'state' => 'exited', 'exit' => 0, 'normalized' => TourEvidence.derived(changed_raw, normalizer) }
  check.call('comparator accepts independently captured equality', TourEvidence.outcome(same, baseline) == 'PASS')
  check.call('comparator change becomes mismatch', TourEvidence.outcome(changed, baseline) == 'FAIL:mismatch')

  normalized = TourEvidence.normalize("pointer=0xDeAdBeef\r\nshort=0x2a\n".b, normalizer)
  check.call('normalizer applies only declared canonicalization',
             normalized['valid_utf8'] && Base64.strict_decode64(normalized['base64']) == "pointer=0xADDR\nshort=0x2a\n")

  invalid = TourEvidence.normalize("\xff".b, normalizer)
  invalid_attempt = {
    'spawned' => true, 'state' => 'exited', 'exit' => 0,
    'normalized' => { 'stdout' => invalid, 'stderr' => TourEvidence.normalize(''.b, normalizer) }
  }
  check.call('invalid UTF-8 is rejected without replacement',
             invalid == { 'valid_utf8' => false, 'bytes' => nil, 'sha256' => nil, 'base64' => nil } &&
             TourEvidence.outcome(invalid_attempt) == 'FAIL:invalid_utf8')

  # Keep the generated artifact directory outside the module. This is the
  # production layout and proves that go build is deliberately run from the
  # supplied module root, rather than accidentally succeeding because the
  # output directory happens to contain go.mod.
  mod = File.join(dir, 'compiled-module')
  out = File.join(dir, 'compiled-output')
  FileUtils.mkdir_p([File.join(mod, 'helper'), out])
  File.write(File.join(mod, 'go.mod'), "module example.local/context\n\ngo 1.23\n")
  File.write(File.join(mod, 'helper', 'helper.go'), "package helper\nfunc Value() string { return \"module-context\" }\n")
  source_path = File.join(mod, 'main.go')
  File.write(source_path, "package main\nimport (\"fmt\"; \"example.local/context/helper\")\nfunc main() { fmt.Println(helper.Value()) }\n")
  transpiler = File.join(dir, 'copy-transpiler')
  File.write(transpiler, "#!/bin/sh\nset -eu\n[ \"$1\" = transpile ]\n[ \"$3\" = -o ]\ncp \"$2\" \"$4\"\n")
  File.chmod(0o755, transpiler)
  go_bin = File.join(`go env GOROOT`.strip, 'bin', 'go')
  pipeline = TourEvidence.compiled_pipeline(
    bashy: transpiler, go_bin: go_bin, source: source_path,
    module_dir: mod, workdir: out, timeout: 15,
    env: { 'GOTOOLCHAIN' => 'local', 'BASHY_HINTS' => 'off' }
  )
  check.call('compiled pipeline builds from the supplied module context',
             pipeline['stage'] == 'run' && pipeline.dig('raw', 'exit') == 0 &&
             pipeline.dig('raw', 'stdout') == "module-context\n")
end

puts "Tour evidence subprocess self-tests OK: #{passed}/10"
