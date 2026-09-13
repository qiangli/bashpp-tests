// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Independent validation of the authenticated Bash++ candidate, ported from
// tools/go-by-example/validate-candidate.rb.
//
//	gbe validate-candidate --candidate MANIFEST --bashy LAUNCHER
//
// It shares no state with a gate run: it re-reads the reviewed table, re-hashes
// the manifest, re-authenticates the launcher, the .real payload and every
// declared repository at its clean exact commit, re-resolves the Go SDK and
// re-checks its identity and digest against the same reviewed toolchain pin the
// oracle uses. Nothing is taken from an evidence document.
//
// What it deliberately does NOT do is assert that the reviewed build recipe was
// observed. The manager supplies the authenticated manifest; this repository can
// bind the recipe string, the tag that enables the front end and the toolchain
// it names, and it can prove the bytes and revisions -- it cannot prove that a
// recipe produced a binary, and it does not pretend to.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func validateCandidateMain(args []string) {
	manifestArg, bashyArg := "", ""
	for i := 0; i < len(args); i++ {
		flag := args[i]
		switch {
		case flag == "--candidate" && i+1 < len(args):
			i++
			manifestArg = args[i]
		case flag == "--bashy" && i+1 < len(args):
			i++
			bashyArg = args[i]
		case strings.HasPrefix(flag, "--candidate="):
			manifestArg = flag[len("--candidate="):]
		case strings.HasPrefix(flag, "--bashy="):
			bashyArg = flag[len("--bashy="):]
		default:
			fatal("unknown argument: " + flag)
		}
	}
	toolchain, err := toolchainPin(DOCS + "/toolchain.tsv")
	if err != nil {
		fatal(err.Error())
	}
	manifest, err := manifestPath(manifestArg)
	if err != nil {
		fatal(err.Error())
	}
	manifestSHA, err := digest(manifest)
	if err != nil {
		fatal(err.Error())
	}
	reviewed, err := reviewedCandidate(DOCS+"/candidates.tsv", manifestSHA)
	if err != nil {
		fatal(err.Error())
	}
	bashy := bashyArg
	if bashy == "" {
		bashy = os.Getenv("BASHY_BIN")
	}
	if bashy == "" {
		fatal("pass --bashy LAUNCHER (or set BASHY_BIN) naming the candidate launcher")
	}
	provenance, err := authenticateManifest(manifest, expandPath(bashy), reviewed, toolchain, DOCS)
	if err != nil {
		if _, isJSON := err.(*jsonParseError); isJSON {
			fatal("candidate manifest is not valid JSON")
		}
		fatal(err.Error())
	}

	// The SDK is resolved by the reviewed version and then authenticated by
	// digest and by its own `go version` line -- the same two facts the gate
	// binds, derived again here rather than copied from it.
	gorootCmd := exec.Command("go", "env", "GOROOT")
	gorootCmd.Env = append(envWithout("GOTOOLCHAIN"), "GOTOOLCHAIN="+toolchain.Version)
	gorootOut, err := gorootCmd.Output()
	if err != nil {
		fatal("cannot resolve the reviewed Go toolchain " + toolchain.Version)
	}
	goroot := strings.TrimSpace(string(gorootOut))
	goBinary := goroot + "/bin/go"
	identityCmd := exec.Command(goBinary, "version")
	identityCmd.Env = append(envWithout("GOTOOLCHAIN"), "GOTOOLCHAIN=local")
	identity, err := identityCmd.Output()
	if err != nil || strings.TrimSpace(string(identity)) != toolchain.Identity {
		fatal("resolved SDK is " + rubyInspect(strings.TrimSpace(string(identity))) + ", not the reviewed " + rubyInspect(toolchain.Identity))
	}
	if _, err := authenticateFile(goBinary, toolchain.GoSHA256); err != nil {
		fatal("SDK " + err.Error())
	}
	versionFile, _ := os.ReadFile(goroot + "/VERSION")
	lines := rubyLinesChomp(string(versionFile))
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != toolchain.Version {
		fatal("resolved GOROOT is not the " + toolchain.Version + " release source")
	}

	var repositories []string
	for _, r := range provenance.Arr("repositories") {
		repo := r.(*Object)
		commit := repo.Str("commit")
		if len(commit) > 12 {
			commit = commit[:12]
		}
		repositories = append(repositories, filepath.Base(repo.Str("path"))+"@"+commit)
	}
	short := func(s string) string {
		if len(s) > 12 {
			return s[:12]
		}
		return s
	}
	fmt.Printf("PASS: authenticated candidate %s\n", short(provenance.Obj("manifest").Str("sha256")))
	fmt.Printf("  launcher   %s %s\n", provenance.Obj("launcher").Str("path"), short(provenance.Str("launcher_sha256")))
	fmt.Printf("  payload    %s %s\n", provenance.Obj("payload").Str("path"), short(provenance.Str("payload_sha256")))
	fmt.Printf("  frontend   %s\n", provenance.Str("frontend_version"))
	fmt.Printf("  recipe     %s\n", provenance.Str("build_recipe"))
	fmt.Printf("  sdk        %s\n", toolchain.Identity)
	fmt.Printf("  runtime    %s\n", strings.Join(repositories, " "))
	fmt.Printf("  lowering   %s\n", provenance.Obj("sh_module").Str("path"))
}
