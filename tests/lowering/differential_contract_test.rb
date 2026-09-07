#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
RUNNER = File.join(ROOT, 'tools/lowering/differential.rb')

def run(env, *argv)
  Open3.capture3(env, *argv)
end

out, err, status = run({}, RUNNER, '--case', 'does-not-exist')
abort 'differential contract accepted a nonexistent case filter' if status.success?
abort "differential contract did not report an honest parity failure:\n#{out}#{err}" unless (out + err).include?('PARITY FAIL')

goroot, go_err, go_status = run({ 'GOTOOLCHAIN' => 'go1.27.0' }, 'go', 'env', 'GOROOT')
abort "authenticated Go 1.27.0 is unavailable for authenticity contract:\n#{go_err}" unless go_status.success?
go = File.join(goroot.strip, 'bin/go')

Dir.mktmpdir('s117-lowering-contract-') do |dir|
  transpiler, engine = File.join(dir, 'fake-transpiler'), File.join(dir, 'fake-engine')
  File.binwrite(transpiler, <<~'SH')
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then out="$2"; shift 2; continue; fi
      shift
    done
    case "${FAKE_MODE:-typed}" in
      wrapper)
        printf '%s\n' 'package main' 'import "os/exec"' 'func interpreterWrapper() { _ = exec.Command("/bin/true").Run() }' 'func main() { interpreterWrapper() }' > "$out"
        ;;
      *)
        printf '%s\n' 'package main' 'func twice(n int) int { return n * 2 }' 'func main() { total := 0; for i := 0; i < 3; i++ { total += twice(i) }; if total != 6 { panic(total) } }' > "$out"
        ;;
    esac
  SH
  File.binwrite(engine, "#!/bin/sh\nexit 0\n")
  FileUtils.chmod(0o755, transpiler)
  FileUtils.chmod(0o755, engine)

  base = [RUNNER, '--case', 'null-safety/flow-narrow', '--bashy', transpiler, '--engine', engine, '--go', go]
  typed_artifacts = File.join(dir, 'typed-artifacts')
  out, err, status = run({ 'FAKE_MODE' => 'typed' }, *(base + ['--typed-only', '--artifacts', typed_artifacts]))
  abort "direct typed compiler fixture failed:\n#{out}#{err}" unless status.success?
  abort 'typed-only fixture did not retain raw generated source' unless File.file?(File.join(typed_artifacts, 'null-safety', 'flow-narrow', 'generated.one.go'))
  abort 'typed-only binary had original source available' if File.exist?(File.join(typed_artifacts, 'null-safety', 'flow-narrow', 'compiled-state', 'flow-narrow.bpp'))
  abort 'subset pass was reported as compiler/corpus parity' unless out.include?('BASHSHARP33 PARITY SUBSET PASS') && out.include?('compiled compiler/corpus parity NOT ESTABLISHED')

  legal_artifacts = File.join(dir, 'legal-dynamic-artifacts')
  out, err, status = run({ 'FAKE_MODE' => 'wrapper' }, *(base + ['--artifacts', legal_artifacts]))
  abort "ordinary dynamic shell fallback was incorrectly rejected:\n#{out}#{err}" unless status.success?

  rejected_artifacts = File.join(dir, 'rejected-wrapper-artifacts')
  out, err, status = run({ 'FAKE_MODE' => 'wrapper' }, *(base + ['--typed-only', '--artifacts', rejected_artifacts]))
  abort 'typed-only fixture accepted fake Go interpreter wrapper' if status.success?
  abort "typed-only rejection did not name the dependency:\n#{out}#{err}" unless (out + err).include?('depends on an interpreter or generated runtime helper')
end

puts 'differential contract PASS: typed Go authenticates, wrapper is rejected, dynamic fallback remains legal, and subset does not establish compiler/corpus parity'
