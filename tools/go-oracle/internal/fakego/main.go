// Command fakego is a sabotage toolchain for the driver's mutation tests.
//
// A mutation test that breaks the compiler only proves something if the driver
// actually reaches a compile. A stub that fails EVERY subcommand dies during the
// driver's startup probes and never gets there, so it proves nothing — that is
// the trap this file exists to avoid. fakego therefore answers `version`, `env`
// and `list` exactly like a real toolchain and sabotages only the real work.
//
// It is a compiled native binary rather than a shell script on purpose. The
// oracle's toolchain-identity gate refuses anything that is not a native
// executable of the reviewed digest, so a script could not be used as a stand-in
// toolchain at all; a real binary can, once the test pins its digest. That keeps
// the identity gate mandatory in production and still lets the mutation tests
// sabotage the compiler.
//
// The mode is taken from the binary's own file name, because the driver invokes
// it by path with argv it controls:
//
//	go-refuse   every compile/link/build/run exits 3.
//	go-zero     every compile/link/build/run exits 0 and produces a ZERO-BYTE
//	            artifact (or none at all). This is the "it said it worked"
//	            failure mode: without artifact assertions the driver would record
//	            artifact_bytes 0 and call the file a pass.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func main() {
	mode := filepath.Base(os.Args[0])
	args := os.Args[1:]
	if len(args) == 0 {
		os.Exit(2)
	}

	switch args[0] {
	case "version":
		release := os.Getenv("FAKEGO_VERSION")
		if release == "" {
			release = "go1.27.0"
		}
		fmt.Printf("go version %s %s/%s\n", release, runtime.GOOS, runtime.GOARCH)
		return
	case "env":
		emitEnv(args[1:])
		return
	case "list":
		// An empty stdlib importcfg is fine: nothing here ever compiles.
		return
	}

	switch mode {
	case "go-zero":
		zeroArtifact(args)
		return
	default:
		fmt.Fprintln(os.Stderr, "fakego refuses to compile")
		os.Exit(3)
	}
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

func emitEnv(args []string) {
	env := map[string]string{
		"GOOS":         runtime.GOOS,
		"GOARCH":       runtime.GOARCH,
		"GOEXPERIMENT": firstNonEmpty(os.Getenv("FAKEGO_GOEXPERIMENT"), os.Getenv("GOEXPERIMENT")),
		"GODEBUG":      os.Getenv("GODEBUG"),
		"CGO_ENABLED":  "0",
		"GOROOT":       os.Getenv("FAKEGO_GOROOT"),
	}
	if len(args) > 0 && args[0] == "-json" {
		data, _ := json.Marshal(env)
		os.Stdout.Write(append(data, '\n'))
		return
	}
	for _, name := range args {
		fmt.Println(env[name])
	}
}

// zeroArtifact honours -o by creating an empty file, and creates the default
// "<name>.o" for a bare `go tool compile`. Exit status 0 throughout: the whole
// point is a toolchain that claims success without producing anything usable.
func zeroArtifact(args []string) {
	var out string
	var lastGo string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "-o" && i+1 < len(args):
			out = args[i+1]
			i++
		case strings.HasPrefix(args[i], "-"):
			// flag, ignore
		case strings.HasSuffix(args[i], ".go"):
			lastGo = args[i]
		}
	}
	if out == "" && lastGo != "" {
		out = strings.TrimSuffix(filepath.Base(lastGo), ".go") + ".o"
	}
	if out == "" {
		return
	}
	if os.Getenv("FAKEGO_OMIT_ARTIFACT") == "1" {
		// The other half of the same lie: exit 0 and write nothing at all.
		return
	}
	_ = os.MkdirAll(filepath.Dir(out), 0o755)
	f, err := os.Create(out)
	if err != nil {
		os.Exit(1)
	}
	f.Close()
}
