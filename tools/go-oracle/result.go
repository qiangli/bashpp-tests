package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// Step is one spawned process. The presence of a Step is the only evidence this
// driver accepts that work happened; a result with no steps is never a pass.
type Step struct {
	Command        []string `json:"command"`
	Dir            string   `json:"dir"`
	Exit           int      `json:"exit"`
	DurationMS     int64    `json:"duration_ms"`
	Artifact       string   `json:"artifact,omitempty"`
	ArtifactKind   string   `json:"artifact_kind,omitempty"`
	ArtifactBytes  int64    `json:"artifact_bytes,omitempty"`
	ArtifactSHA256 string   `json:"artifact_sha256,omitempty"`
	Output         string   `json:"output,omitempty"`
}

// Result is one corpus file. The top-level command/exit/duration/action/artifact
// fields describe the decisive step; Steps carries the whole sequence.
type Result struct {
	Path           string   `json:"path"`
	Dir            string   `json:"dir"`
	GoFile         string   `json:"go_file"`
	Action         string   `json:"action"`
	DeclaredAction string   `json:"declared_action"`
	Recipe         string   `json:"recipe"`
	Status         string   `json:"status"`
	ExpectFail     bool     `json:"expect_fail"`
	Command        []string `json:"command"`
	Exit           int      `json:"exit"`
	DurationMS     int64    `json:"duration_ms"`
	Artifact       string   `json:"artifact"`
	ArtifactKind   string   `json:"artifact_kind"`
	ArtifactBytes  int64    `json:"artifact_bytes"`
	ArtifactSHA256 string   `json:"artifact_sha256,omitempty"`
	Steps          []Step   `json:"steps"`
	Error          string   `json:"error,omitempty"`
	SkipReason     string   `json:"skip_reason,omitempty"`
}

// seal copies the decisive step up to the top level. The decisive step is the
// last one that ran: for every tranche-1 action the verdict is determined either
// by the final command's status or by a comparison performed on its output.
func (r *Result) seal() {
	if len(r.Steps) == 0 {
		return
	}
	last := r.Steps[len(r.Steps)-1]
	r.Command = last.Command
	r.Exit = last.Exit
	// The artifact is taken from the last step that named one. `go run` produces
	// no file, so for those actions the decisive artifact is the one the step
	// before it wrote — for runoutput, the GENERATED program.
	for i := len(r.Steps) - 1; i >= 0; i-- {
		if r.Steps[i].Artifact != "" {
			r.Artifact = r.Steps[i].Artifact
			r.ArtifactKind = r.Steps[i].ArtifactKind
			r.ArtifactBytes = r.Steps[i].ArtifactBytes
			r.ArtifactSHA256 = r.Steps[i].ArtifactSHA256
			break
		}
	}
}

// describeArtifact measures what a command actually produced. A recorded
// artifact of zero bytes is reported as zero rather than omitted: "the compiler
// wrote nothing" is a finding, not a missing field.
func describeArtifact(dir, rel string) (int64, string) {
	if rel == "" {
		return 0, ""
	}
	p := rel
	if !filepath.IsAbs(p) {
		p = filepath.Join(dir, rel)
	}
	info, err := os.Stat(p)
	if err != nil || info.IsDir() {
		return 0, ""
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return info.Size(), ""
	}
	sum := sha256.Sum256(data)
	return info.Size(), hex.EncodeToString(sum[:])
}
