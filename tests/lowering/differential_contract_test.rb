#!/usr/bin/env ruby
# Sprint: #117; Story: #8; Story-ID: 65f43d377225
require 'open3'

ROOT = File.expand_path('../..', __dir__)
RUNNER = File.join(ROOT, 'tools/lowering/differential.rb')

out, err, status = Open3.capture3(RUNNER, '--case', 'does-not-exist')
abort 'differential contract accepted a nonexistent case filter' if status.success?
abort "differential contract did not report an honest parity failure:\n#{out}#{err}" unless (out + err).include?('PARITY FAIL')
puts 'differential contract PASS: unavailable authenticated compiler is a failure, never success'
