// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Versioned, deterministic stream normalizer for the tour differential
// evidence architecture — the `tour-normalizer/v1` rules pinned by Sprint 98
// (tools/tour/normalize.rb, retired), unchanged:
//
//  1. Strict UTF-8 gate. Invalid bytes are REJECTED, never transliterated or
//     replaced; the caller records the stream as invalid and stores no
//     normalized digest for it.
//  2. Line endings: CRLF and lone CR collapse to LF.
//  3. Pointer-sized hexadecimal addresses (at least eight hex digits) are
//     replaced with 0xADDR. Short hexadecimal values remain semantic output.
//
// No other substitution is performed. Timestamps, random draws, goroutine
// interleavings and scratch paths are NOT masked: the comparators in
// semantics.go adjudicate those instead.
//
// The identity of this file (its SHA-256) is pinned in every evidence
// manifest (`normalizer.sha256`); the gates re-hash it and fail closed on a
// mismatch, so changing the rules requires re-pinning — the audit trail.
//
// `tour normalize` exposes the same contract the Ruby script had: raw bytes
// on stdin, normalized bytes on stdout, exit 3 for a non-UTF-8 stream, and
// `--version` printing the version token.
package main

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"unicode/utf8"
)

const normalizerVersion = "tour-normalizer/v1"

// Digest of the retired Ruby implementation of the same v1 rules
// (tools/tour/normalize.rb, deleted by Sprint 155). Ledgers sealed against it
// remain authentic: the rules are identical, and the gates accept exactly this
// digest for that path and nothing else.
const retiredRubyNormalizerSHA256 = "7802ad55606fc6a425b026c15cb520127705ec6a9084288b9ef5b4209dffca08"

var (
	crlfRE    = regexp.MustCompile(`\r\n?`)
	pointerRE = regexp.MustCompile(`\b0x[0-9a-fA-F]{8,}\b`)
)

// normalizeV1 applies the rules. ok=false means the stream is not strict UTF-8.
func normalizeV1(raw []byte) ([]byte, bool) {
	if !utf8.Valid(raw) {
		return nil, false
	}
	text := crlfRE.ReplaceAll(raw, []byte("\n"))
	text = pointerRE.ReplaceAll(text, []byte("0xADDR"))
	return text, true
}

func cmdNormalize(args []string) int {
	for _, arg := range args {
		if arg == "--version" {
			fmt.Println(normalizerVersion)
			return 0
		}
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	out, ok := normalizeV1(raw)
	if !ok {
		return 3
	}
	os.Stdout.Write(out)
	return 0
}

// cmdUTF8Check: `tour utf8-check FILE` exits 0 iff the file is strict UTF-8.
// It replaces the inline Ruby probe the baseline runner and results gate used.
func cmdUTF8Check(args []string) int {
	var data []byte
	var err error
	if len(args) == 0 || args[0] == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(args[0])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if !utf8.Valid(data) {
		return 1
	}
	return 0
}
