#!/usr/bin/env ruby
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
#
# Independent validation of the authenticated Bash++ candidate.
#
#   validate-candidate.rb --candidate MANIFEST --bashy LAUNCHER
#
# It shares no state with a gate run: it re-reads the reviewed table, re-hashes
# the manifest, re-authenticates the launcher, the .real payload and every
# declared repository at its clean exact commit, re-resolves the Go SDK and
# re-checks its identity and digest against the same reviewed toolchain pin the
# oracle uses. Nothing is taken from an evidence document.
#
# What it deliberately does NOT do is assert that the reviewed build recipe was
# observed. The manager supplies the authenticated manifest; this repository can
# bind the recipe string, the tag that enables the front end and the toolchain
# it names, and it can prove the bytes and revisions -- it cannot prove that a
# recipe produced a binary, and it does not pretend to.
require "open3"
require_relative "candidate"

def die(message)
  abort "FATAL: #{message}"
end

manifest_arg = nil
bashy_arg = nil
args = ARGV.dup
until args.empty?
  case (flag = args.shift)
  when "--candidate" then manifest_arg = args.shift
  when "--bashy" then bashy_arg = args.shift
  when /\A--candidate=(.*)\z/m then manifest_arg = Regexp.last_match(1)
  when /\A--bashy=(.*)\z/m then bashy_arg = Regexp.last_match(1)
  else die("unknown argument: #{flag}")
  end
end

begin
  toolchain = GoByExampleCandidate.toolchain
  manifest = GoByExampleCandidate.manifest_path(manifest_arg)
  reviewed = GoByExampleCandidate.reviewed(manifest_sha256: Corpus.digest(manifest))
  bashy = bashy_arg || ENV["BASHY_BIN"]
  die("pass --bashy LAUNCHER (or set BASHY_BIN) naming the candidate launcher") if bashy.to_s.empty?
  provenance = GoByExampleCandidate.authenticate(manifest, File.expand_path(bashy), reviewed, toolchain)
rescue GoByExampleCandidate::Error, Corpus::ContractError => e
  die(e.message)
rescue JSON::ParserError
  die("candidate manifest is not valid JSON")
end

# The SDK is resolved by the reviewed version and then authenticated by digest
# and by its own `go version` line -- the same two facts the gate binds, derived
# again here rather than copied from it.
goroot, status = Open3.capture2({"GOTOOLCHAIN" => toolchain["version"]}, "go", "env", "GOROOT")
die("cannot resolve the reviewed Go toolchain #{toolchain['version']}") unless status.success?
go = goroot.strip + "/bin/go"
identity, status = Open3.capture2({"GOTOOLCHAIN" => "local"}, go, "version")
die("resolved SDK is #{identity.strip.inspect}, not the reviewed #{toolchain['identity'].inspect}") unless status.success? && identity.strip == toolchain["identity"]
begin
  Corpus.authenticate_file(go, toolchain["go_sha256"])
rescue Corpus::ContractError => e
  die("SDK #{e.message}")
end
die("resolved GOROOT is not the #{toolchain['version']} release source") unless File.readlines(goroot.strip + "/VERSION").first.to_s.strip == toolchain["version"]

repositories = provenance.fetch("repositories").map { |r| "#{File.basename(r.fetch('path'))}@#{r.fetch('commit')[0, 12]}" }
puts "PASS: authenticated candidate #{provenance.dig('manifest', 'sha256')[0, 12]}"
puts "  launcher   #{provenance.dig('launcher', 'path')} #{provenance.fetch('launcher_sha256')[0, 12]}"
puts "  payload    #{provenance.dig('payload', 'path')} #{provenance.fetch('payload_sha256')[0, 12]}"
puts "  frontend   #{provenance.fetch('frontend_version')}"
puts "  recipe     #{provenance.fetch('build_recipe')}"
puts "  sdk        #{toolchain['identity']}"
puts "  runtime    #{repositories.join(' ')}"
puts "  lowering   #{provenance.dig('sh_module', 'path')}"
