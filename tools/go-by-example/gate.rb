#!/usr/bin/env ruby
# Differential gate for the pinned Go by Example corpus.
#
# Three observations of the SAME unchanged upstream bytes per program row:
#
#   oracle       pinned Go 1.27 `go build` (or `go test -c`) -> run the native
#                binary directly.  Never `go run`: its wrapper reports a child
#                `os.Exit(3)` as its own exit 1 plus an "exit status 3" line on
#                stderr, which conflates deliberate statuses with panics.
#   interpreted  bashy --bashpp --source=go <original .go> [argv...], or
#                bashy --bashpp --source=go --go-file A --go-file B for an
#                explicit multi-file package.
#   compiled     bashy transpile --bashpp --source=go <inputs> -o gen.go
#                --map gen.go.map, then pinned `go build` of the generated Go,
#                then run the resulting native artifact.
#
# `--source=go` now EXISTS in the tag-enabled candidate, so this gate drives the
# real front end rather than documenting a missing flag.  Multi-file input uses
# the product's own `--go-file` contract, repeated once per file; a second
# source file is never passed as a program argument, because the CLI would hand
# it to the program as argv.  The removed `--bashpp --compile -o` spelling never
# existed in any shipped CLI.
#
# Spawning, deadlines, process-group teardown and surviving-descendant checks
# are NOT reimplemented here.  They come from tools/corpus/executor.rb
# (`Corpus.capture`, `Corpus.success?`, `Corpus.snapshot`, `Corpus.file_record`,
# and the candidate/SDK provenance primitives).  This file owns only what is
# specific to this corpus: per-row behaviour adapters, the recipes, and the
# narrow declared comparators layered above those primitives.
#
# Every stage is recorded separately, so a transpile that succeeded can never
# be read as an artifact that ran.  Each mode gets its own freshly constructed
# execution root and its own copy of the source tree at the ORIGINAL relative
# asset paths (embed-directive resolves `folder/single_file.txt` relative to
# the source file, so a basename-flattened copy silently changes the program).
# Roots are snapshotted before and after, and the resulting filesystem effects
# are compared across modes alongside status, stdout and stderr.
require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "openssl"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "normalizer"
require_relative "candidate"
require_relative "inputs"
require_relative "runtime-config"
Thread.report_on_exception = false

ROOT = File.expand_path("../..", __dir__)
DOCS = ROOT + "/docs/go-by-example"
INV = ENV.fetch("GBE_INVENTORY", DOCS + "/inventory.tsv")
SCHEMA = ENV.fetch("GBE_SCHEMA", DOCS + "/behavior-schema.tsv")
CLS = DOCS + "/classification.tsv"
CANDIDATES = DOCS + "/candidates.tsv"
LAUNCHER_SOURCE = File.expand_path("launch.go", __dir__)

# --- CLI arg contract -------------------------------------------------------
# `--candidate MANIFEST` selects WHICH reviewed candidate to drive and `--bashy`
# names its launcher. There is no default candidate: a gate that silently ran
# whatever binary happened to be on PATH would be reporting on an unidentified
# product. The manifest cannot introduce a candidate either -- every field of it
# has to equal a reviewed row of docs/go-by-example/candidates.tsv.
candidate_arg = nil
bashy_arg = nil
results_arg = nil
argv = ARGV.dup
until argv.empty?
  case (flag = argv.shift)
  when "--candidate" then candidate_arg = argv.shift
  when "--bashy" then bashy_arg = argv.shift
  when "--evidence" then results_arg = argv.shift
  when /\A--candidate=(.*)\z/m then candidate_arg = Regexp.last_match(1)
  when /\A--bashy=(.*)\z/m then bashy_arg = Regexp.last_match(1)
  when /\A--evidence=(.*)\z/m then results_arg = Regexp.last_match(1)
  else abort("FATAL: unknown argument: #{flag}")
  end
end
RESULTS = results_arg || ENV.fetch("GBE_RESULTS", ROOT + "/.cache/go-by-example/results.jsonl")
BASHY = File.expand_path(bashy_arg || ENV["BASHY_BIN"] || "")

ROW_LIMIT = Float(ENV.fetch("GBE_ROW_TIMEOUT", "240"))
TRANSPILE_LIMIT = Float(ENV.fetch("GBE_TRANSPILE_TIMEOUT", "60"))
BUILD_LIMIT = Float(ENV.fetch("GBE_BUILD_TIMEOUT", "120"))
RUN_LIMIT = Float(ENV.fetch("GBE_RUN_TIMEOUT", "20"))
CLEANUP_LIMIT = Float(ENV.fetch("GBE_CLEANUP_TIMEOUT", "2"))

EVIDENCE_SCHEMA = 8
STORY = "Sprint118/Story3/fa07603b71dc"
MODES = %w[oracle interpreted compiled].freeze
# All three modes get the SAME environment block, with no exemption for the
# interpreter. examples/environment-variables prints every key it can see, so
# any extra key given to one mode is a guaranteed disagreement that the
# env_listing comparator cannot honestly absorb.
#
# The W1 contract question this file used to defer is now answered by
# measurement: the product's runtime import helper resolves stdlib and module
# imports through GOROOT and GOMODCACHE, and without them `--source=go` refuses
# every program with `could not import fmt ... ($GOROOT not set)`. Both keys are
# therefore part of the COMMON block -- granted to the oracle and to the
# compiled artifact exactly as they are granted to the interpreter -- so they
# are the same observation in examples/environment-variables in all three modes
# and the divergence list stays empty. Granting them to one side only is what
# would have been dishonest.
DECLARED_ENV_DIVERGENCE = [].freeze

def fatal(message)
  abort("FATAL: #{message}")
end

def sha(path)
  Digest::SHA256.file(path).hexdigest
end

def toks(value)
  value == "none" ? [] : value.split(",")
end

def left(deadline)
  deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def native?(path)
  Corpus.native_binary?(path)
end

# --- authenticated inputs ---------------------------------------------------

system(ROOT + "/tools/go-by-example/validate.sh") or fatal("corpus integrity gate failed") unless ENV["GBE_SKIP_INTEGRITY"] == "1"

# The candidate is authenticated before anything is staged, and it is
# authenticated through the shared corpus primitives: Corpus.authenticate_file
# for the launcher, its adjacent `.real` payload and the SDK, and
# Corpus.authenticate_candidate for every declared repository at its clean exact
# revision, untracked files included. The gate adds only the repository anchor:
# the supplied manifest must equal a reviewed row of candidates.tsv, so a caller
# selects a candidate but can never introduce one.
begin
  TOOLPIN = GoByExampleCandidate.toolchain(DOCS + "/toolchain.tsv")
  CANDIDATE_MANIFEST = GoByExampleCandidate.manifest_path(candidate_arg)
  REVIEWED = GoByExampleCandidate.reviewed(CANDIDATES, manifest_sha256: Corpus.digest(CANDIDATE_MANIFEST))
  CANDIDATE = GoByExampleCandidate.authenticate(CANDIDATE_MANIFEST, BASHY, REVIEWED, TOOLPIN)
rescue GoByExampleCandidate::Error, Corpus::ContractError => e
  fatal(e.message)
rescue JSON::ParserError
  fatal("candidate manifest is not valid JSON")
end
pin = ["", "", TOOLPIN["version"], TOOLPIN["identity"], TOOLPIN["go_sha256"]]

goroot_out, status = Open3.capture2({"GOTOOLCHAIN" => TOOLPIN["version"]}, "go", "env", "GOROOT")
fatal("cannot resolve pinned Go toolchain") unless status.success?
GOROOT = goroot_out.strip
GO = GOROOT + "/bin/go"
identity, status = Open3.capture2({"GOTOOLCHAIN" => "local"}, GO, "version")
fatal("Go identity mismatch") unless status.success? && identity.strip == pin[3]
fatal("Go binary checksum mismatch") unless sha(GO) == pin[4]
fatal("Go release source mismatch") unless File.readlines(GOROOT + "/VERSION").first.strip == pin[2]
fatal("Go tool is not native") unless native?(GO)
# The SDK the modules were fetched into is part of the same runtime context the
# product's import helper reads; it is supplied to every mode identically.
GOMODCACHE = (Open3.capture2({"GOTOOLCHAIN" => "local"}, GO, "env", "GOMODCACHE").first.strip rescue "")
fatal("cannot resolve the SDK module cache") if GOMODCACHE.empty? || !File.directory?(GOMODCACHE)

# The generated Go depends on the lowering runtime. It is no longer provisioned
# out of band through GBE_SH_MODULE, which was an unauthenticated environment
# path: it is the mvdan.cc/sh/v3 repository the AUTHENTICATED candidate declares,
# already proved to be at its clean reviewed commit.
SH_MODULE = CANDIDATE.dig("sh_module", "path")
REAL_BASHY = CANDIDATE.dig("launcher", "path")
BASHY_SHA = CANDIDATE.fetch("launcher_sha256")
PAYLOAD_SHA = CANDIDATE.fetch("payload_sha256")
bashy_version, status = Open3.capture2e(BASHY, "--version")
fatal("Bash++ identity command failed") unless status.success? && !bashy_version.empty?

# Every adapter here is a construction this file actually performs. A name that
# describes a control the gate cannot exercise does not belong in the registry.
ADAPTERS = %w[none argv_fixture fixed_env hermetic_cwd tmpdir input_file_fixture stdin_fixture local_http_origin loopback_server signal_injector exit_status_capture bounded_wait go_test_runner].freeze
NORMS = GoByExampleNormalizer::NAMES
schema = File.readlines(SCHEMA, chomp: true).map { |x| x.split("\t", -1) }
fatal("adapter registry differs from schema") unless schema.map { |r| r[1] if r[0] == "adapter" }.compact.sort == ADAPTERS.sort
fatal("normalizer registry differs from schema") unless schema.map { |r| r[1] if r[0] == "normalization" }.compact.sort == NORMS.sort

rows = File.readlines(INV, chomp: true).reject { |x| x.empty? || x.start_with?("#") }.map { |x| x.split("\t", -1) }.select { |r| %w[program test_program].include?(r[1]) }
fatal("expected exactly 85 program rows, got #{rows.size}") unless rows.size == 85
rows.each do |r|
  path = ROOT + "/" + r[0]
  fatal("source changed during gate: #{r[0]}") unless File.file?(path) && File.size(path).to_s == r[6] && sha(path) == r[7]
end
DENOMINATOR = rows.size * MODES.size

# --- process control --------------------------------------------------------

def sig(name, pgid)
  Process.kill(name, -pgid)
rescue Errno::ESRCH, Errno::EPERM
  nil
end

def alive?(pgid)
  Process.kill(0, -pgid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

def sentinel_held?(io, budget)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
  loop do
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return true if remaining <= 0
    return true unless IO.select([io], nil, nil, remaining)
    begin
      io.read_nonblock(4096)
    rescue EOFError
      return false
    rescue IO::WaitReadable
      next
    rescue IOError, Errno::EBADF
      return false
    end
  end
end

# `stop` is set the moment the stage ends. A program that exited before the
# adapter could drive it is not an adapter failure -- its own status and streams
# are the observation, and turning that into `adapter_error` would hide the real
# result behind an incomplete one. A deadline reached while the program is still
# running is a genuine adapter failure and still raises.
def drive(path, deadline, stop)
  socket = nil
  until socket
    return if stop[0]
    raise "server adapter deadline" unless left(deadline) > 0
    socket = TCPSocket.new("127.0.0.1", 8090) rescue nil
    sleep([0.02, left(deadline)].min) unless socket
  end
  if path.include?("tcp-server")
    socket.write("hello adapter\n")
    raise "bad TCP response" unless socket.gets == "ACK: HELLO ADAPTER\n"
  else
    socket.write("GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    raise "bad HTTP response" unless path.include?("context/") || socket.read.include?("hello")
  end
ensure
  socket&.close
end

# Loopback origin standing in for gobyexample.com so the network_client row is
# hermetic without editing the pinned program's URL.
class Origin
  attr_reader :url

  def initialize(deadline, dir)
    @deadline = deadline
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=gobyexample.com")
    cert.public_key = key.public_key
    cert.not_before = Time.at(0)
    cert.not_after = Time.utc(2100)
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = factory.issuer_certificate = cert
    cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(factory.create_extension("subjectAltName", "DNS:gobyexample.com"))
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    @ca = dir + "/hermetic-ca.pem"
    File.write(@ca, cert.to_pem)
    @ctx = OpenSSL::SSL::SSLContext.new
    @ctx.cert = cert
    @ctx.key = key
    @tcp = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@tcp.addr[1]}"
    @error = nil
    @thread = Thread.new do
      client = @tcp.accept
      line = client.gets
      raise "expected CONNECT gobyexample.com:443" unless line&.start_with?("CONNECT gobyexample.com:443 ")
      loop { break if client.gets == "\r\n" }
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
      ssl = OpenSSL::SSL::SSLSocket.new(client, @ctx)
      ssl.sync_close = true
      ssl.accept
      ssl.readpartial(4096)
      body = "<!doctype html>\n<html>\n<head><title>Go by Example</title></head>\n<body>\n<h1>Go by Example</h1>\n"
      ssl.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      ssl.close
    rescue StandardError => e
      @error = e
    end
  end

  def apply(env)
    env.merge("HTTPS_PROXY" => @url, "https_proxy" => @url, "SSL_CERT_FILE" => @ca)
  end

  def close
    @tcp.close rescue nil
    budget = [left(@deadline), CLEANUP_LIMIT].min
    joined = budget > 0 && @thread.join(budget)
    @thread.kill unless joined
    @thread.join(CLEANUP_LIMIT)
    raise @error if @error && ![IOError, Errno::EBADF, EOFError].any? { |k| @error.is_a?(k) }
    joined
  end
end

# One run/build stage. Spawning, the monotonic deadline, the process group, the
# reap, the teardown and the raw stream capture belong to Corpus.capture; this
# wrapper only layers the corpus-specific behaviour adapters above it and maps
# the corpus stage vocabulary onto the gate's.
#
# `launch:` routes a RUN stage through the corpus-owned tools/go-by-example/
# launch.go, which exec()s the program after publishing its pid and opening a
# liveness FIFO that
# every descendant inherits. That is what lets an adapter signal the program at
# a readiness line it observed, and what keeps a descendant that escaped into
# its own session -- invisible to Corpus.capture's kill(0, -pgid) -- reported as
# a leak rather than a clean exit. Neither needs a second spawn or timer.
def run(cmd, cwd, env, input, outer, child_limit, path, adapters, adapter_dir, log_prefix, launch: false)
  result = {"exit" => nil, "state" => "unspawned", "spawned" => false, "stdout" => "", "stderr" => "", "command" => cmd}
  budget = [left(outer), child_limit].min
  return result.merge("detail" => "child deadline expired before spawn") unless budget > 0
  # Adapters observe the SAME deadline Corpus.capture enforces, not the looser
  # row deadline: an adapter still waiting for a readiness line after the child
  # has already been killed would otherwise spin until the row budget expired
  # and be reported as a cleanup failure instead of the timeout it is.
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
  unless cmd.is_a?(Array) && !cmd.empty? && File.file?(cmd[0]) && File.executable?(cmd[0])
    return result.merge("detail" => "command is not an executable file: #{cmd[0]}")
  end
  FileUtils.mkdir_p(adapter_dir)
  FileUtils.mkdir_p(File.dirname(log_prefix))
  stdin_path = adapter_dir + "/stdin"
  File.binwrite(stdin_path, input.to_s)
  pidfile = adapter_dir + "/program.pid"
  fifo = adapter_dir + "/liveness.fifo"
  origin = nil
  liveness = nil
  threads = []
  argv = cmd
  stage = nil
  # Shared with the adapter threads; see drive/published_pid/await_output.
  stop = [false]
  begin
    origin = Origin.new(deadline, adapter_dir) if adapters.include?("local_http_origin")
    env = origin.apply(env) if origin
    if launch
      File.unlink(fifo) if File.exist?(fifo)
      File.mkfifo(fifo)
      # Opened before the spawn so the launcher's non-blocking write-open finds
      # a reader; the descriptor is what descendants inherit across exec.
      liveness = File.open(fifo, File::RDONLY | File::NONBLOCK)
      argv = [LAUNCHER, fifo, pidfile, "--", *cmd]
      result["launch_argv"] = argv
    end
    if adapters.include?("loopback_server")
      threads << Thread.new do
        pid = published_pid(pidfile, deadline, stop)
        next if pid.nil?
        drive(path, deadline, stop)
        sig("TERM", pid) unless stop[0]
      end
    end
    if adapters.include?("signal_injector")
      # "deliver the declared signal once the program has reported readiness":
      # signals.go prints its readiness line only after signal.Notify is armed.
      # A blind sleep raced it and killed the process under the DEFAULT SIGINT
      # disposition, so both sides produced empty output and the example's
      # actual behaviour was never observed. The readiness line is read from the
      # durable stdout log Corpus.capture is writing.
      threads << Thread.new do
        pid = published_pid(pidfile, deadline, stop)
        next if pid.nil?
        sig("INT", pid) if await_output(log_prefix + ".stdout", deadline, stop)
      end
    end
    stage = Corpus.capture(argv, cwd: cwd, log_prefix: log_prefix, env: env, timeout: budget, stdin: stdin_path)
  rescue Corpus::ContractError => e
    result["detail"] = "#{e.class}: #{e.message}"
  rescue SystemCallError => e
    result["detail"] = "#{e.class}: #{e.message}"
  rescue StandardError => e
    result["state"] = "adapter_error"
    result["detail"] = "#{e.class}: #{e.message}"
  ensure
    stop[0] = true
    threads.each do |thread|
      unless thread.join(CLEANUP_LIMIT)
        result["state"] = "cleanup_error"
        result["detail"] = [result["detail"], "adapter thread did not join within cleanup bound"].compact.join("; ")
        thread.kill
        thread.join(CLEANUP_LIMIT)
      end
      begin
        thread.value
      rescue StandardError => e
        result["state"] = "adapter_error"
        result["detail"] = [result["detail"], e.message].compact.join("; ")
      end
    end
    unless !origin || origin.close
      result["state"] = "cleanup_error"
      result["detail"] = [result["detail"], "origin thread did not join by row deadline"].compact.join("; ")
    end
  end

  if stage
    result["capture"] = stage
    result["spawned"] = stage["spawned"] ? true : false
    result["stdout"] = read_stream(log_prefix + ".stdout")
    result["stderr"] = read_stream(log_prefix + ".stderr")
    result["corpus_state"] = stage["state"]
    result["duration_seconds"] = stage["duration_seconds"]
    mapped =
      case stage["state"]
      when "exited" then "complete"
      when "deadline" then "timeout"
      when "process_leak" then "leak"
      else "unspawned"
      end
    # An adapter/cleanup diagnosis already recorded is the more precise one and
    # is not overwritten by the generic mapping.
    result["state"] = mapped unless %w[adapter_error cleanup_error].include?(result["state"])
    result["exit"] = stage["exit"] || (stage["signal"] && 128 + stage["signal"]) unless mapped == "timeout"
    if stage["state"] == "process_leak"
      result["detail"] = [result["detail"], "a descendant survived process-group termination"].compact.join("; ")
    end
    # The FIFO end is still held by any descendant that inherited it, including
    # one that called setsid() and is therefore invisible to kill(0, -pgid).
    if liveness && result["spawned"] && sentinel_held?(liveness, CLEANUP_LIMIT)
      result["state"] = "leak"
      result["detail"] = [result["detail"], "descendant survived process-group termination still holding the inherited liveness descriptor"].compact.join("; ")
    end
  end
  liveness&.close
  File.unlink(fifo) if File.exist?(fifo)
  result
end

def read_stream(path)
  File.binread(path)
rescue SystemCallError
  ""
end

# The pid the corpus-owned launcher published for itself before exec. Adapters
# wait for it rather than assuming one exists.
def published_pid(pidfile, deadline, stop)
  loop do
    return nil if stop[0]
    raise "adapter: the program never published its pid" unless left(deadline) > 0
    value = (File.read(pidfile) rescue nil)
    return Integer(value.strip) if value && !value.strip.empty?
    sleep 0.01
  end
end

def await_output(stream, deadline, stop)
  loop do
    return false if stop[0]
    raise "signal adapter: program never reported readiness" unless left(deadline) > 0
    return true if File.size?(stream)
    sleep 0.01
  end
end

# --- filesystem effects -----------------------------------------------------

# Sorted `relative-path<TAB>content-digest` listing of an execution root, walked
# by Corpus.snapshot so the entry vocabulary is the shared one. Every entry under
# the root is covered, including HOME, TMPDIR and dotfiles.
def snapshot(root)
  Corpus.snapshot(root).sort.map do |rel, entry|
    kind =
      case entry["kind"]
      when "file" then "file:" + entry["sha256"]
      when "symlink" then "symlink:" + entry["target"].to_s
      when "directory" then "dir"
      else "other"
      end
    "#{rel}\t#{kind}"
  end.join("\n")
end

# Effects are compared after ONLY the row's declared tmp_path normalization,
# which is the sole reviewed transformation that describes a path. Nothing else
# in the registry may rewrite an effect listing.
EFFECT_NORMALIZATIONS = %w[tmp_path].freeze

def effect_digest(before, after, normalizations)
  b = before.split("\n")
  a = after.split("\n")
  delta = ((a - b).map { |l| "+#{l}" } + (b - a).map { |l| "-#{l}" }).sort.join("\n")
  licensed = normalizations & EFFECT_NORMALIZATIONS
  text = licensed.empty? ? delta : GoByExampleNormalizer.normalize(delta, licensed, :stdout)
  {"delta" => text, "sha256" => Digest::SHA256.hexdigest(text), "normalizations" => licensed}
end

# --- recipe construction ----------------------------------------------------

TEST_FUNCTION = /^func\s+((?:Test|Benchmark)[A-Za-z0-9_]*)\s*\(/

# The generated driver is a SEPARATE artifact beside the unchanged _test.go
# bytes; it never edits them. Verified against the upstream recipe: for the
# pinned testing-and-benchmarking row, `go build` of (unchanged bytes + this
# driver) run with -test.v produces byte-identical output and status to
# `go test -c` of the same bytes.
def test_driver(source_bytes, label)
  names = source_bytes.scan(TEST_FUNCTION).flatten
  tests = names.select { |n| n.start_with?("Test") }
  benchmarks = names.select { |n| n.start_with?("Benchmark") }
  raise "no Test functions found in #{label}" if tests.empty?
  <<~GO
    // GENERATED by tools/go-by-example/gate.rb for #{label}.
    // Not upstream bytes: a driver only, so the unchanged _test.go really runs
    // its assertions in every mode instead of being treated as a script.
    package main

    import (
    \t"regexp"
    \t"testing"
    )

    func gbeMatchString(pat, str string) (bool, error) { return regexp.MatchString(pat, str) }

    func main() {
    \ttesting.Main(gbeMatchString,
    \t\t[]testing.InternalTest{
    #{tests.map { |n| "\t\t\t{Name: #{n.inspect}, F: #{n}}," }.join("\n")}
    \t\t},
    \t\t[]testing.InternalBenchmark{
    #{benchmarks.map { |n| "\t\t\t{Name: #{n.inspect}, F: #{n}}," }.join("\n")}
    \t\t},
    \t\tnil,
    \t)
    }
  GO
end

# Place every declared runtime asset AT ITS ORIGINAL PATH RELATIVE TO THE
# PROGRAM. Copying by basename would break `//go:embed folder/single_file.txt`,
# which the Go compiler resolves against the directory holding the source file.
def stage_assets(dir, row)
  FileUtils.mkdir_p(dir)
  example_dir = File.dirname(row[0])
  toks(row[5]).each do |asset|
    raise "asset #{asset} is not inside #{example_dir}" unless asset.start_with?(example_dir + "/")
    target = File.join(dir, asset[(example_dir.size + 1)..])
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(ROOT + "/" + asset, target)
  end
  dir
end

def stage_sources(dir, row, name)
  stage_assets(dir, row)
  FileUtils.cp(ROOT + "/" + row[0], File.join(dir, name))
  dir
end

# A fresh, identically shaped execution root per mode: nothing but the runtime
# layout and the declared assets, so a filesystem comparison stays meaningful.
def stage_root(dir, row, adapters)
  stage_assets(dir, row)
  FileUtils.mkdir_p(dir + "/home")
  FileUtils.mkdir_p(dir + "/tmp")
  # input_file_fixture: the pinned bytes the program reads, created before the
  # baseline snapshot so it is an input and never counted as an effect.
  File.binwrite(dir + "/tmp/dat", "hello\ngo\n") if adapters.include?("input_file_fixture")
  dir
end

GO_MOD_ORACLE = "module gbe.oracle\n\ngo 1.27\n"
GO_MOD_LOWERED = "module gbelowered\n\ngo 1.27\n\nrequire mvdan.cc/sh/v3 v3.0.0\n\nreplace mvdan.cc/sh/v3 => #{SH_MODULE}\n"

def build_env(gocache, gomodcache, gohome, gotmp)
  {
    "LC_ALL" => "C.UTF-8", "LANG" => "C.UTF-8", "TZ" => "UTC",
    "HOME" => gohome, "TMPDIR" => gotmp, "GOTMPDIR" => gotmp,
    "GOROOT" => GOROOT, "PATH" => File.dirname(GO), "GOTOOLCHAIN" => "local",
    "GOCACHE" => gocache, "GOMODCACHE" => gomodcache,
    "GOFLAGS" => "-mod=mod -p=2", "GOPROXY" => "off", "GOSUMDB" => "off",
    "GOWORK" => "off", "CGO_ENABLED" => "0"
  }
end

# Run environment, identical in all three modes apart from the per-mode root
# prefix. PATH is provisioned only for the rows whose declared behavior is to
# execute another program; everything else runs with an empty PATH so a stray
# host tool cannot supply a result.
#
# GOROOT and GOMODCACHE are in the COMMON block. They are what the product's
# runtime import helper reads to resolve `import "fmt"` and module imports, and
# they are granted identically to the oracle binary and to the compiled
# artifact, which ignore them. examples/environment-variables therefore observes
# the same keys in all three modes -- the only way this harness may satisfy a
# product runtime need.
#
# GOCACHE is in that block for a measured reason of its own: the interpreted
# mode invokes the pinned toolchain AT RUN TIME, and with no explicit cache it
# falls back to $HOME -- which this harness deliberately places INSIDE the
# compared execution root, so several thousand build-cache entries were being
# recorded as program effects. Pointing all three modes at one cache outside the
# roots is environment construction, not normalization: it makes the effect
# channel measure the program rather than the toolchain. It does not hide the
# run-time toolchain use itself, which prerequisites.md records. Supported
# telemetry opt-outs are configured identically before each effect baseline.
#
# Note what none of this is: an empty PATH is command-lookup isolation, not an
# OS-level denial of the SDK or of the source tree, and the evidence says so
# rather than claiming a sandbox it does not build.
def run_env(root, behaviors)
  {
    "PATH" => behaviors.include?("process_exec") ? "/usr/bin:/bin" : "",
    "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8", "TZ" => "UTC",
    "HOME" => root + "/home", "TMPDIR" => root + "/tmp", "PWD" => root,
    "BAR" => "",
    "GOROOT" => GOROOT, "GOMODCACHE" => GOMODCACHE, "GOCACHE" => RUN_GOCACHE,
    "GOTOOLCHAIN" => "local", "GOPROXY" => "off", "GOSUMDB" => "off",
    "BASHY_HINTS" => "off", "OTEL_TRACES_EXPORTER" => "none"
  }
end

# Root-independent form, so the three environments are actually comparable.
def env_profile(env, root)
  env.map { |k, v| [k, v.to_s.gsub(root, "${ROOT}")] }.sort
end

def relativize(value, replacements)
  replacements.reduce(value.to_s) { |acc, (from, to)| from.to_s.empty? ? acc : acc.gsub(from, to) }
end

def stage_record(name, result, replacements, extra = {})
  {
    "stage" => name,
    "capture" => result["capture"],
    "argv" => Array(result["command"]).map { |a| relativize(a, replacements) },
    # What Corpus.capture was actually handed, when the corpus-owned launcher
    # was interposed. Recorded so `argv` is never read as the whole truth about
    # how the stage was started.
    "launch_argv" => result["launch_argv"] && result["launch_argv"].map { |a| relativize(a, replacements) },
    "spawned" => result["spawned"], "state" => result["state"], "exit" => result["exit"],
    "detail" => result["detail"] && relativize(result["detail"], replacements),
    "stdout_sha256" => Digest::SHA256.hexdigest(result["stdout"]),
    "stderr_sha256" => Digest::SHA256.hexdigest(result["stderr"]),
    "stderr_head" => relativize(result["stderr"].to_s[0, 512], replacements)
  }.merge(extra).compact
end

def stage_ok?(result)
  result["state"] == "complete" && result["exit"] == 0
end

# --- evidence ---------------------------------------------------------------

def attempt_record(fields)
  record = fields.compact
  record["evidence_sha256"] = Digest::SHA256.hexdigest(JSON.generate(record))
  record
end

stat = File.stat(REAL_BASHY)
payload_stat = File.stat(REAL_BASHY + ".real")
# The whole candidate, not one artifact digest: launcher AND payload, the exact
# clean revision of every repository the candidate links (its lowering runtime
# and every other replaced module), the asserted build recipe, the front-end
# version and the SDK identity. `build_recipe` is bound, never inferred -- this
# repository can prove these bytes and these revisions, and it does not claim to
# have observed the build that produced them.
candidate = {
  "manifest_path" => CANDIDATE_MANIFEST, "manifest_sha256" => CANDIDATE.dig("manifest", "sha256"),
  "candidates_sha256" => CANDIDATE.fetch("candidates_sha256"),
  "launcher_path" => REAL_BASHY, "launcher_sha256" => BASHY_SHA,
  "payload_path" => CANDIDATE.dig("payload", "path"), "payload_sha256" => PAYLOAD_SHA,
  "frontend_version" => CANDIDATE.fetch("frontend_version"),
  "build_recipe" => CANDIDATE.fetch("build_recipe"),
  "go_identity" => CANDIDATE.fetch("go_identity"),
  "repositories" => CANDIDATE.fetch("repositories").map { |r| {"name" => File.basename(r.fetch("path")), "commit" => r.fetch("commit")} }.sort_by { |r| r["name"] },
  "sh_module_commit" => CANDIDATE.dig("sh_module", "commit"),
  "version_sha256" => Digest::SHA256.hexdigest(bashy_version),
  "device" => stat.dev, "inode" => stat.ino,
  "payload_device" => payload_stat.dev, "payload_inode" => payload_stat.ino
}
corpus_root = Digest::SHA256.hexdigest(rows.map { |r| "#{r[0]}\0#{r[7]}\n" }.join)
normalizer_path = ROOT + "/tools/go-by-example/normalizer.rb"
manifest = {
  "type" => "manifest", "schema" => EVIDENCE_SCHEMA, "story" => STORY,
  "corpus_sha256" => sha(INV), "corpus_root_sha256" => corpus_root,
  "behavior_schema_sha256" => sha(SCHEMA), "classification_sha256" => sha(CLS),
  "normalizer_version" => GoByExampleNormalizer::VERSION, "normalizer_sha256" => sha(normalizer_path),
  "toolchain_sha256" => sha(DOCS + "/toolchain.tsv"), "go_sha256" => pin[4],
  "candidate" => candidate,
  "denominator" => {"rows" => rows.size, "modes_per_row" => MODES.size, "attempts" => DENOMINATOR},
  "modes" => MODES,
  "recipe" => {
    "oracle" => "pinned go build (go test -c for test_program) then run the native binary",
    "interpreted" => "bashy --bashpp --source=go <source> [argv...]; explicit multi-file uses repeated --go-file",
    "compiled" => "bashy transpile --bashpp --source=go <source|--go-file...> -o gen.go --map gen.go.map; pinned go build; run the artifact",
    "multi_file_input" => "--go-file",
    "multi_file_program_arguments" => "-- separator before program argv",
    "declared_env_divergence" => DECLARED_ENV_DIVERGENCE,
    "common_runtime_go_env" => %w[GOROOT GOMODCACHE GOCACHE],
    "effect_normalizations" => EFFECT_NORMALIZATIONS,
    "process_primitives" => "tools/corpus/executor.rb Corpus.capture/success?/snapshot/file_record/authenticate_candidate",
    "corpus_executor_sha256" => sha(ROOT + "/tools/corpus/executor.rb"),
    "input_binding_sha256" => sha(ROOT + "/tools/go-by-example/inputs.rb"),
    "runtime_config_sha256" => sha(ROOT + "/tools/go-by-example/runtime-config.rb"),
    "runtime_telemetry" => {"OTEL_TRACES_EXPORTER" => "none", "Go" => "pinned go telemetry off in each isolated HOME before effect baseline"},
    "launcher_source_sha256" => sha(LAUNCHER_SOURCE),
    "source_absence" => "compilation inputs are absent from the run cwd and PATH is empty for every row that does not declare process_exec; this is cwd and command-lookup isolation, NOT an OS-level denial of the SDK or of the source tree",
    "source_layout" => "per mode, original program plus declared assets at their original relative paths"
  }
}
binding = Digest::SHA256.hexdigest(JSON.generate(manifest))
records = [manifest]
incomplete = false

FileUtils.mkdir_p(File.dirname(RESULTS))
journal = File.open(RESULTS + ".progress.jsonl", "wx", 0o600)
journal.puts(JSON.generate(manifest)); journal.flush
base = File.expand_path(ENV.fetch("GBE_WORK_ROOT", RESULTS + ".work"))
fatal("refusing to overwrite retained work: #{base}") if File.exist?(base)
FileUtils.mkdir_p(base)
begin
  gocache = base + "/gocache"
  gomodcache = GOMODCACHE
  gohome = base + "/gohome"
  gotmp = base + "/gotmp"
  [gocache, gomodcache, gohome, gotmp].each { |d| FileUtils.mkdir_p(d) }
  benv = build_env(gocache, gomodcache, gohome, gotmp)

  # The corpus-owned run launcher is compiled once, by the same pinned SDK as
  # the oracle, before any row is attempted. It is a native binary because a run
  # stage's PATH is deliberately empty: an interpreter that shells out at
  # startup could not run there, and granting one a PATH would change what
  # examples/environment-variables and the process_exec rows observe.
  launcher_src = base + "/launcher"
  FileUtils.mkdir_p(launcher_src)
  FileUtils.cp(LAUNCHER_SOURCE, launcher_src + "/launch.go")
  File.write(launcher_src + "/go.mod", "module gbelaunch\n\ngo 1.27\n")
  LAUNCHER = base + "/bin/gbe-launch"
  FileUtils.mkdir_p(base + "/bin")
  launcher_build = run([GO, "build", "-o", LAUNCHER, "."], launcher_src, benv, "",
                       Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUILD_LIMIT, BUILD_LIMIT,
                       "tools/go-by-example/launch.go", [], base + "/stage/launcher", base + "/logs/launcher")
  fatal("cannot build the corpus run launcher: #{launcher_build['detail'] || launcher_build['stderr'].to_s[0, 400]}") unless stage_ok?(launcher_build) && native?(LAUNCHER)
  # One run-time toolchain cache, outside every execution root, shared by all
  # three modes exactly like GOROOT and GOMODCACHE.
  RUN_GOCACHE = gocache
  FileUtils.mkdir_p(RUN_GOCACHE)
  replacements = {base => "${WORK}", ROOT => "${ROOT}", GOROOT => "${GOROOT}", SH_MODULE => "${SH_MODULE}"}

  rows.each_with_index do |row, index|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ROW_LIMIT
    path, kind, behavior_field, normalization_field, adapter_field, requires_field = row.values_at(0, 1, 2, 3, 4, 5)
    behaviors = toks(behavior_field)
    normalizations = toks(normalization_field)
    adapters = toks(adapter_field)
    test_row = kind == "test_program"
    name = File.basename(path)
    work = base + format("/%03d", index)
    FileUtils.mkdir_p(work)

    args = adapters.include?("argv_fixture") ? %w[foo bar baz] : []
    args = %w[-test.v] if test_row
    input = adapters.include?("stdin_fixture") ? "hello\nworld\n" : ""
    # Adapters that drive or signal the process under test apply to the run
    # stage only; a build must never be terminated by a client fixture, so the
    # build stages below are given an empty adapter list.
    run_adapters = adapters

    stages = {"oracle" => [], "interpreted" => [], "compiled" => []}
    binaries = {}
    input_bindings = [GoByExampleInputs.new(File.dirname(ROOT + "/" + path))]

    # -- oracle: build the pinned bytes natively, then run the binary.
    oracle_src = work + "/src/oracle"
    stage_sources(oracle_src, row, test_row ? "main_test.go" : name)
    File.write(oracle_src + "/go.mod", GO_MOD_ORACLE)
    input_bindings << GoByExampleInputs.new(oracle_src, allow_additions: true)
    oracle_bin = work + "/bin/oracle"
    FileUtils.mkdir_p(work + "/bin")
    oracle_build = run(test_row ? [GO, "test", "-c", "-o", oracle_bin, "."] : [GO, "build", "-o", oracle_bin, "."],
                       oracle_src, benv, "", deadline, BUILD_LIMIT, path, [],
                       work + "/stage/oracle-build", work + "/logs/oracle-build")
    GoByExampleInputs.enforce(oracle_build, input_bindings)
    stages["oracle"] << stage_record(test_row ? "oracle-test-build" : "oracle-build", oracle_build, replacements,
                                     "source_sha256" => row[7])
    if stage_ok?(oracle_build) && File.file?(oracle_bin) && File.executable?(oracle_bin) && native?(oracle_bin)
      binaries["oracle"] = oracle_bin
      stages["oracle"].last["native_file"] = Corpus.file_record(oracle_bin)
    end

    # -- product inputs: unchanged bytes, plus a generated driver for the test
    #    row. The driver is a separate file; the _test.go bytes are untouched.
    product_inputs = {}
    source_arguments = {}
    %w[interpreted compiled].each do |mode|
      product_src = work + "/src/" + mode
      stage_sources(product_src, row, name)
      inputs = [product_src + "/" + name]
      if test_row
        driver = product_src + "/gbe_test_driver.go"
        File.write(driver, test_driver(File.binread(ROOT + "/" + path), path))
        inputs << driver
      end
      fatal("staged product source diverged from the pinned bytes: #{path}") unless sha(product_src + "/" + name) == row[7]
      input_bindings << GoByExampleInputs.new(product_src)
      product_inputs[mode] = inputs.to_h { |file| [file, Corpus.file_record(file)] }
      source_arguments[mode] = inputs.size == 1 ? [inputs.first] : inputs.flat_map { |file| ["--go-file", file] }
    end

    # -- compiled: transpile the unchanged Go, build the generated Go, run it.
    transpile_dir = work + "/compiled/transpile"
    FileUtils.mkdir_p(transpile_dir)
    generated = transpile_dir + "/generated.go"
    source_map = transpile_dir + "/generated.go.map"
    transpile = run([BASHY, "transpile", "--bashpp", "--source=go", *source_arguments.fetch("compiled"), "-o", generated, "--map", source_map],
                    transpile_dir, benv, "", deadline, TRANSPILE_LIMIT, path, [],
                    work + "/stage/transpile", work + "/logs/transpile")
    GoByExampleInputs.enforce(transpile, input_bindings)
    stages["compiled"] << stage_record("transpile", transpile, replacements, "source_sha256" => row[7], "input_sha256" => product_inputs.fetch("compiled").transform_values { |r| r.fetch("sha256") })
    lowered_ok = stage_ok?(transpile) && File.size?(generated)
    if lowered_ok
      stages["compiled"].last["generated_go_sha256"] = sha(generated)
      # The declared source map is checked against the shared corpus schema, not
      # merely recorded: a transpile that emitted an unparseable, mis-positioned
      # or mis-digested map has not produced the artifact the contract describes,
      # and the compiled mode must not proceed as if it had.
      mapping = (JSON.parse(File.read(source_map)) rescue nil)
      if mapping && Corpus.valid_source_map?(mapping, Corpus.file_record(generated), product_inputs.fetch("compiled"))
        stages["compiled"].last["generated_file"] = Corpus.file_record(generated)
        stages["compiled"].last["source_map_file"] = Corpus.file_record(source_map)
        stages["compiled"].last["source_inputs"] = product_inputs.fetch("compiled")
        stages["compiled"].last["source_map_sha256"] = sha(source_map)
        input_bindings << GoByExampleInputs.new(transpile_dir)
      else
        lowered_ok = false
        stages["compiled"].last["state"] = "invalid_source_map"
      end
    end

    if lowered_ok
      build_dir = work + "/compiled/build"
      stage_assets(build_dir, row)
      File.write(build_dir + "/go.mod", GO_MOD_LOWERED)
      FileUtils.cp(generated, build_dir + "/main.go")
      input_bindings << GoByExampleInputs.new(build_dir, allow_additions: true)
      lowered_bin = work + "/bin/lowered"
      build = run([GO, "build", "-o", lowered_bin, "."], build_dir, benv, "", deadline, BUILD_LIMIT, path, [],
                  work + "/stage/build", work + "/logs/build")
      GoByExampleInputs.enforce(build, input_bindings)
      stages["compiled"] << stage_record("build", build, replacements, "generated_go_sha256" => sha(generated))
      if stage_ok?(build) && File.file?(lowered_bin) && File.executable?(lowered_bin) && native?(lowered_bin)
        binaries["compiled"] = lowered_bin
        stages["compiled"].last["native_file"] = Corpus.file_record(lowered_bin)
        stages["compiled"].last["artifact_sha256"] = sha(lowered_bin)
        stages["compiled"].last["artifact_bytes"] = File.size(lowered_bin)
      end
    end

    input_bindings << GoByExampleInputs.new(work + "/bin")

    # -- three runs, each in its own freshly constructed execution root.
    observations = {}
    runtime_roots = MODES.to_h { |mode| [mode, stage_root(work + "/run/" + mode, row, adapters)] }
    MODES.each do |mode|
      root = runtime_roots.fetch(mode)
      # Adapter scratch (the loopback origin's trust anchor) lives OUTSIDE the
      # execution root so a gate fixture can never be read as a program effect.
      adapter_dir = work + "/adapters/" + mode
      FileUtils.mkdir_p(adapter_dir)
      env = run_env(root, behaviors)
      command =
        case mode
        when "oracle" then binaries["oracle"] && [binaries["oracle"], *args]
        when "compiled" then binaries["compiled"] && [binaries["compiled"], *args]
        else [BASHY, "--bashpp", "--source=go", *source_arguments.fetch("interpreted"), *(test_row && !args.empty? ? ["--", *args] : args)]
        end
      configuration = GoByExampleRuntimeConfig.configure(GO, root, env, deadline: deadline, log_prefix: work + "/logs/config-" + mode)
      before = snapshot(root)
      result =
        if command && input_bindings.all?(&:unchanged?) && configuration["state"] == "complete"
          run(command, root, env, input, deadline, RUN_LIMIT, path, run_adapters, adapter_dir,
              work + "/logs/run-" + mode, launch: true)
        else
          missing = mode == "oracle" ? "oracle build" : stages["compiled"].map { |s| s["stage"] }.last
          {"exit" => nil, "state" => "unspawned", "spawned" => false, "stdout" => "", "stderr" => "",
           "command" => [], "detail" => "no runnable artifact: #{missing} did not produce one"}
        end
      result["state"] = "configuration_failure" if configuration["state"] != "complete"
      GoByExampleInputs.enforce(result, input_bindings)
      after = snapshot(root)
      effects = begin
        effect_digest(before, after, normalizations)
      rescue StandardError => e
        result["detail"] = [result["detail"], "effect normalization failed: #{e.message}"].compact.join("; ")
        nil
      end
      stages[mode] << stage_record("run", result, replacements)
      observations[mode] = {"configuration" => configuration, "result" => result, "effects" => effects, "env_profile" => env_profile(env, root)}
    end

    profiles = MODES.map { |m| observations[m]["env_profile"] }
    divergence = profiles.flatten(1).uniq - profiles.reduce(:&)
    fatal("undeclared environment divergence on #{path}: #{(divergence.map(&:first).uniq - DECLARED_ENV_DIVERGENCE).inspect}") unless (divergence.map(&:first).uniq - DECLARED_ENV_DIVERGENCE).empty?

    reference = observations["oracle"]
    reference_normalized = begin
      [GoByExampleNormalizer.normalize(reference["result"]["stdout"], normalizations, :stdout),
       GoByExampleNormalizer.normalize(reference["result"]["stderr"], normalizations, :stderr)]
    rescue StandardError
      nil
    end

    MODES.each do |mode|
      observation = observations[mode]
      result = observation["result"]
      incomplete ||= result["state"] != "complete" || !result["spawned"]
      normalized = begin
        [GoByExampleNormalizer.normalize(result["stdout"], normalizations, :stdout),
         GoByExampleNormalizer.normalize(result["stderr"], normalizations, :stderr)]
      rescue StandardError => e
        result["detail"] = [result["detail"], e.message].compact.join("; ")
        nil
      end
      verdict =
        if result["state"] != "complete" then "fail_incomplete"
        elsif normalized.nil? || reference_normalized.nil? || observation["effects"].nil? then "fail_normalization"
        elsif mode == "oracle" then "pass"
        elsif result["exit"] != reference["result"]["exit"] || normalized != reference_normalized then "fail_mismatch"
        elsif reference["effects"] && observation["effects"]["sha256"] != reference["effects"]["sha256"] then "fail_effects"
        else "pass"
        end
      records << attempt_record(
        "type" => "attempt", "path" => path, "mode" => mode, "kind" => kind,
        "spawned" => result["spawned"], "state" => result["state"], "exit" => result["exit"],
        "raw_stdout_b64" => Base64.strict_encode64(result["stdout"]),
        "raw_stderr_b64" => Base64.strict_encode64(result["stderr"]),
        "normalized_stdout_b64" => normalized && Base64.strict_encode64(normalized[0]),
        "normalized_stderr_b64" => normalized && Base64.strict_encode64(normalized[1]),
        "effects_sha256" => observation["effects"] && observation["effects"]["sha256"],
        "effects_delta" => observation["effects"] && observation["effects"]["delta"],
        "stages" => stages[mode], "configuration" => observation.fetch("configuration"),
        "verdict" => verdict, "detail" => result["detail"] && relativize(result["detail"], replacements),
        "binding_sha256" => binding
      )
    end

    rows_unchanged = sha(ROOT + "/" + path)
    fatal("source changed during gate: #{path}") unless rows_unchanged == row[7]
    records.last(MODES.size).each { |record| journal.puts(JSON.generate(record)) }
    journal.flush; journal.fsync
    puts "ROW #{index + 1}/#{rows.size} #{path}: " + records.last(MODES.size).map { |r| "#{r['mode']}=#{r['verdict']}(#{r['state']},#{r['exit']})" }.join(" ")
    $stdout.flush
  end
end

journal.close

attempts = records.count { |r| r["type"] == "attempt" }
fatal("missing-attempt evidence: expected #{DENOMINATOR} attempt records, got #{attempts}") unless attempts == DENOMINATOR
fatal("candidate mutation during gate") unless File.realpath(BASHY) == REAL_BASHY && sha(REAL_BASHY) == BASHY_SHA && File.stat(REAL_BASHY).ino == candidate["inode"]
fatal("candidate payload mutation during gate") unless sha(REAL_BASHY + ".real") == PAYLOAD_SHA && File.stat(REAL_BASHY + ".real").ino == candidate["payload_inode"]
fatal("candidate manifest mutation during gate") unless sha(CANDIDATE_MANIFEST) == candidate["manifest_sha256"] && sha(CANDIDATES) == candidate["candidates_sha256"]
records.each do |record|
  next unless record["type"] == "attempt"
  body = record.reject { |k, _| k == "evidence_sha256" }
  fatal("result tampering detected") unless record["binding_sha256"] == binding && record["evidence_sha256"] == Digest::SHA256.hexdigest(JSON.generate(body))
end

# Temp workspace cleanup and all joins precede publication. Unspawned commands
# remain attempt evidence, but are never included in the executed numerator.
executed = records.count { |r| r["type"] == "attempt" && r["spawned"] }
failures = records.select { |r| r["type"] == "attempt" && r["verdict"] != "pass" }.map { |r| "#{r['path']}:#{r['mode']}:#{r['verdict']}" }
verdict = failures.empty? && !incomplete && attempts == DENOMINATOR && executed == DENOMINATOR ? "pass" : "fail"
summary = {
  "type" => "summary", "verdict" => verdict, "denominator" => DENOMINATOR,
  "attempt_records" => attempts, "executed" => executed, "missing_or_unspawned" => DENOMINATOR - executed,
  "failures" => failures,
  "corpus_sha256" => manifest["corpus_sha256"], "corpus_root_sha256" => corpus_root,
  "behavior_schema_sha256" => manifest["behavior_schema_sha256"], "classification_sha256" => manifest["classification_sha256"],
  "normalizer_version" => manifest["normalizer_version"], "normalizer_sha256" => manifest["normalizer_sha256"],
  "toolchain_sha256" => manifest["toolchain_sha256"], "go_sha256" => manifest["go_sha256"],
  "candidates_sha256" => candidate["candidates_sha256"], "candidate_manifest_sha256" => candidate["manifest_sha256"],
  "launcher_sha256" => BASHY_SHA, "payload_sha256" => PAYLOAD_SHA
}
summary_hash = Digest::SHA256.hexdigest(JSON.generate(summary))
root_digest = Digest::SHA256.hexdigest(([Digest::SHA256.hexdigest(JSON.generate(manifest))] +
                                        records.select { |r| r["type"] == "attempt" }.map { |r| r["evidence_sha256"] } +
                                        [summary_hash]).join("\n"))
summary["root_digest"] = root_digest
records << summary

FileUtils.mkdir_p(File.dirname(RESULTS))
dest = "#{RESULTS}.#{verdict}"
payload = records.map { |r| JSON.generate(r) }.join("\n") + "\n"
temp = dest + ".tmp.#{$$}"
File.open(temp, "wb", 0o600) { |f| f.write(payload); f.flush; f.fsync }
File.rename(temp, dest)
fatal("verdict=fail denominator=#{DENOMINATOR} executed=#{executed} missing=#{DENOMINATOR - executed}; first: #{failures.first}; evidence: #{dest}") if verdict == "fail"
puts "PASS: verdict=pass denominator=#{DENOMINATOR} executed=#{executed} evidence=#{dest} root_digest=#{root_digest}"
