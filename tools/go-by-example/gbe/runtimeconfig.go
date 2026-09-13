// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Supported telemetry opt-outs, configured identically in every mode's
// isolated HOME before the effect baseline is taken. Ported from
// tools/go-by-example/runtime-config.rb.
package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var reTelemetryMode = regexp.MustCompile(`\Aoff(?: \d{4}-\d{2}-\d{2})?\z`)

// configureRuntime is GoByExampleRuntimeConfig.configure: `go telemetry off`
// then `go env -json GOTELEMETRY GOTELEMETRYDIR`, both captured, then the mode
// file proved to live inside the isolated HOME.
func configureRuntime(goBinary string, root string, env map[string]string, deadline float64, logPrefix string) *Object {
	stages := []any{}
	fail := func(message string) *Object {
		return Obj("state", "configuration_failure", "detail", message, "stages", stages)
	}
	commands := [][]string{{goBinary, "telemetry", "off"}, {goBinary, "env", "-json", "GOTELEMETRY", "GOTELEMETRYDIR"}}
	var last *Object
	for index, argv := range commands {
		budget := deadline - monotonicSeconds()
		if !(budget > 0) {
			return fail("runtime configuration deadline expired")
		}
		// `[budget, 20].min`: the Integer 20 unless the Float budget is smaller.
		timeout := Int(20)
		if budget < 20 {
			timeout = Flt(budget)
		}
		stage, err := capture(argv, root, logPrefix+"/"+itoa(index), env, timeout, os.DevNull)
		if err != nil {
			return fail(err.Error())
		}
		stages = append(stages, stage)
		last = stage
		if !success(stage) {
			return fail("SDK telemetry configuration failed")
		}
	}
	data, err := os.ReadFile(last.Obj("stdout").Str("path"))
	if err != nil {
		return fail(err.Error())
	}
	config, err := ParseObject(data)
	if err != nil {
		return fail(err.Error())
	}
	if config.Str("GOTELEMETRY") != "off" {
		return fail("Go telemetry did not report off")
	}
	dir, ok := config.Get("GOTELEMETRYDIR").(string)
	if !ok {
		return fail("key not found: \"GOTELEMETRYDIR\"")
	}
	mode := filepath.Join(dir, "mode")
	modeReal, err := realPath(mode)
	if err != nil {
		return fail(err.Error())
	}
	rootReal, err := realPath(root)
	if err != nil {
		return fail(err.Error())
	}
	if !strings.HasPrefix(modeReal, rootReal+"/") {
		return fail("telemetry configuration escaped isolated HOME")
	}
	record, err := fileRecord(mode)
	if err != nil {
		return fail(err.Error())
	}
	return Obj("state", "complete", "environment", Obj("OTEL_TRACES_EXPORTER", env["OTEL_TRACES_EXPORTER"]),
		"go_mode", "off", "mode_file", record, "stages", stages)
}
