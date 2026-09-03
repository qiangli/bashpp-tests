#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Versioned, deterministic stream normalizer for the tour differential
# evidence architecture.
#
# Sprint 98 / Story #4 / Story-ID 759341a95870.
#
# A raw captured stdout/stderr stream is normalized to a canonical form so
# that two engines' outputs can be compared meaningfully AND so that an
# offline validator can INDEPENDENTLY recompute the normalization from the
# stored raw bytes and prove the recorded normalized fields were not
# fabricated. The normalizer is intentionally MINIMAL: aggressive
# normalization is itself a gaming vector (normalize everything to nothing
# and every mode looks equal), so this pass only removes provenance-neutral,
# genuinely-volatile noise and nothing else.
#
# The identity of this file (its SHA-256) is pinned in the evidence manifest
# as `normalizer_sha256`; both the runner and the validator invoke THIS exact
# file, and the validator fails closed if the on-disk normalizer's SHA does
# not match the manifest. Changing the rules therefore requires re-pinning,
# which is the audit trail.
#
# Contract:
#   stdin  : raw bytes of one captured stream
#   stdout : normalized bytes
#   exit 0 : normalized successfully (stream was strict UTF-8)
#   exit 3 : stream is NOT strict UTF-8 — REJECTED, never transliterated or
#            replaced; the caller records the stream as invalid and stores no
#            normalized digest for it.
#   --version : print the normalizer version token and exit 0.
#
# Version token: tour-normalizer/v1
#
# v1 rules, applied in order:
#   1. Strict UTF-8 gate. Invalid bytes -> exit 3 (no output).
#   2. Line endings: CRLF and lone CR collapse to LF.
#   3. Pointer-sized hexadecimal addresses (at least eight hex digits) are
#      replaced with 0xADDR. Short hexadecimal values remain semantic output.
#      dumps embed heap addresses that vary run to run; the fact that a value
#      is an address is semantic, its bits are not.
# No other substitution is performed. In particular timestamps, random draws,
# goroutine interleavings and scratch paths are NOT masked: the runner invokes
# every engine on a program at its stable inventory-relative path, and the
# verdict layer never depends on masking volatile *values* to succeed.

NORMALIZER_VERSION = 'tour-normalizer/v1'

if ARGV.include?('--version')
  puts NORMALIZER_VERSION
  exit 0
end

raw = STDIN.binmode.read
raw = ''.b if raw.nil?
text = raw.dup.force_encoding('UTF-8')
exit 3 unless text.valid_encoding?

# Rule 2: canonical LF line endings.
text = text.gsub(/\r\n?/, "\n")
# Rule 3: mask heap addresses.
text = text.gsub(/\b0x[0-9a-fA-F]{8,}\b/, '0xADDR')

STDOUT.binmode.write(text)
