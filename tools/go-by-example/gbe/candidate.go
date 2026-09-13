// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// The reviewed-candidate binding shared by the gate and its independent
// validators, ported from tools/go-by-example/candidate.rb.
//
// Sprint 98 bound one reproducible executor digest from docs/go-by-example/
// executor.tsv. The Go-source front end is not that shape: it is a Makefile
// tag-enabled build (`make build BASHY_GOSOURCE=1`) that installs a small
// launcher beside a large `.real` payload, and whose lowering runtime is a set
// of replaced sibling modules. So the authority moved to a manifest, and the
// manifest is authenticated by the absorbed corpus primitives rather than by a
// second implementation of them here.
//
// The CLI arg contract is `--candidate MANIFEST` (`GBE_CANDIDATE` for the
// environment spelling). A caller chooses WHICH reviewed candidate to run; it
// cannot introduce one, because every field of the manifest must equal a row of
// docs/go-by-example/candidates.tsv, starting with the manifest's own digest.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
)

// CandidateError is GoByExampleCandidate::Error.
type CandidateError struct{ msg string }

func (e *CandidateError) Error() string { return e.msg }
func candidateErr(format string, args ...any) error {
	return &CandidateError{msg: fmt.Sprintf(format, args...)}
}

// A shipped launcher is a small stub beside its payload. A candidate whose
// launcher IS the payload is a different artifact shape than the one reviewed,
// so the two digests may never coincide.
var candidateFields = []string{"manifest_sha256", "launcher_sha256", "payload_sha256", "frontend_version", "go_identity", "build_recipe", "repositories"}

// Reviewed is one authenticated row of candidates.tsv as a field map.
type Reviewed struct {
	Fields       map[string]string
	Repositories []string          // sorted basenames
	Commits      map[string]string // basename -> commit
}

func (r *Reviewed) RepositoryRecords() []any {
	out := make([]any, 0, len(r.Repositories))
	for _, name := range r.Repositories {
		out = append(out, Obj("name", name, "commit", r.Commits[name]))
	}
	return out
}

// hostIdentity is RbConfig host_os/host_cpu normalized the way candidate.rb did.
func hostIdentity() (string, string) {
	return runtime.GOOS, runtime.GOARCH
}

var (
	reHex64      = regexp.MustCompile(`\A[0-9a-f]{64}\z`)
	reAllZero    = regexp.MustCompile(`\A0+\z`)
	reRepoName   = regexp.MustCompile(`\A[a-z0-9._-]+\z`)
	reCommitHash = regexp.MustCompile(`\A[0-9a-f]{40}\z`)
)

// reviewedCandidate is GoByExampleCandidate.reviewed: the reviewed row for this
// host (the one whose manifest digest matches, or the last one). Malformed
// rows are a repository defect, not something to fall back from.
func reviewedCandidate(path string, manifestSHA string) (*Reviewed, error) {
	goos, goarch := hostIdentity()
	table, err := readTSV(path)
	if err != nil {
		return nil, candidateErr("cannot read candidates table: %s", path)
	}
	var rows [][]string
	seen := map[string]bool{}
	for _, r := range table {
		if len(r) > 1 && r[0] == goos && r[1] == goarch {
			rows = append(rows, r)
		}
	}
	for _, r := range rows {
		key := ""
		if len(r) > 2 {
			key = r[2]
		}
		if seen[key] {
			return nil, candidateErr("duplicate reviewed candidate identity")
		}
		seen[key] = true
	}
	var row []string
	if manifestSHA != "" {
		for _, r := range rows {
			if len(r) > 2 && r[2] == manifestSHA {
				row = r
			}
		}
		if row == nil {
			return nil, candidateErr("candidate manifest is not the repository-reviewed manifest (%s)", manifestSHA)
		}
	} else if len(rows) > 0 {
		row = rows[len(rows)-1]
	}
	if row == nil {
		return nil, candidateErr("no repository-reviewed Bash++ candidate for %s/%s", goos, goarch)
	}
	if len(row) != 9 {
		return nil, candidateErr("reviewed candidate row is malformed")
	}
	fields := map[string]string{}
	for i, key := range candidateFields {
		fields[key] = row[2+i]
	}
	for _, key := range []string{"manifest_sha256", "launcher_sha256", "payload_sha256"} {
		if !reHex64.MatchString(fields[key]) || reAllZero.MatchString(fields[key]) {
			return nil, candidateErr("invalid reviewed candidate %s", key)
		}
	}
	if fields["launcher_sha256"] == fields["payload_sha256"] {
		return nil, candidateErr("reviewed candidate launcher and payload digests are identical")
	}
	if fields["frontend_version"] == "" {
		return nil, candidateErr("reviewed candidate declares no frontend version")
	}
	// Historical diagnostic builds used an optional tag. Final default builds
	// are equally admissible only when their exact recipe and all bytes match
	// the separately reviewed candidate row and manifest.
	identityWords := strings.Fields(fields["go_identity"])
	version := ""
	if len(identityWords) > 2 {
		version = identityWords[2]
	}
	recipe := fields["build_recipe"]
	explicitRelease := version != "" && strings.Contains(recipe, "GOTOOLCHAIN="+version)
	pinnedSDKPath := false
	if version != "" && strings.Contains(recipe, "GOTOOLCHAIN=local") {
		pattern := `(?:\A|\s)PATH=/[^\s:]+/golang\.org/toolchain@v0\.0\.1-` + regexp.QuoteMeta(version) + `\.` + regexp.QuoteMeta(goos) + `-` + regexp.QuoteMeta(goarch) + `/bin(?::|\s|\z)`
		pinnedSDKPath = regexp.MustCompile(pattern).MatchString(recipe)
	}
	if !explicitRelease && !pinnedSDKPath {
		return nil, candidateErr("reviewed build recipe does not pin the Go toolchain: %s", rubyInspect(recipe))
	}
	names, commits, err := parseRepositories(fields["repositories"])
	if err != nil {
		return nil, err
	}
	return &Reviewed{Fields: fields, Repositories: names, Commits: commits}, nil
}

// rubyInspect renders a string the way String#inspect does for the plain
// ASCII values that reach diagnostics here.
func rubyInspect(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\t':
			b.WriteString(`\t`)
		case '#':
			if i+1 < len(s) && (s[i+1] == '{' || s[i+1] == '$' || s[i+1] == '@') {
				b.WriteString(`\#`)
			} else {
				b.WriteByte(c)
			}
		default:
			if c < 0x20 || c == 0x7f {
				fmt.Fprintf(&b, `\x%02X`, c)
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func parseRepositories(value string) ([]string, map[string]string, error) {
	pairs := strings.Split(value, ";")
	if value == "" {
		pairs = nil
	}
	names := []string{}
	commits := map[string]string{}
	if len(pairs) == 0 {
		return nil, nil, candidateErr("reviewed candidate repository list is malformed")
	}
	for _, entry := range pairs {
		name, commit, _ := strings.Cut(entry, "=")
		if !reRepoName.MatchString(name) || !reCommitHash.MatchString(commit) {
			return nil, nil, candidateErr("reviewed candidate repository list is malformed")
		}
		names = append(names, name)
		commits[name] = commit
	}
	sorted := append([]string(nil), names...)
	sort.Strings(sorted)
	if strings.Join(sorted, ";") != strings.Join(names, ";") || len(commits) != len(names) {
		return nil, nil, candidateErr("reviewed candidate repository list is unsorted or duplicated")
	}
	return names, commits, nil
}

// Toolchain is the reviewed Go release for this host from toolchain.tsv.
type Toolchain struct {
	Version  string
	Identity string
	GoSHA256 string
}

// toolchainPin is GoByExampleCandidate.toolchain: the toolchain identity is
// bound to the same reviewed release as the oracle, so a pass can never be
// assembled from a Go 1.27 oracle plus a candidate some other release built.
func toolchainPin(path string) (*Toolchain, error) {
	goos, goarch := hostIdentity()
	rows, err := readTSV(path)
	if err != nil {
		return nil, candidateErr("cannot read toolchain table: %s", path)
	}
	for _, r := range rows {
		if len(r) >= 5 && r[0] == goos && r[1] == goarch {
			return &Toolchain{Version: r[2], Identity: r[3], GoSHA256: r[4]}, nil
		}
	}
	return nil, candidateErr("no authenticated Go toolchain pin for %s/%s", goos, goarch)
}

// manifestPath is GoByExampleCandidate.manifest_path: where --candidate came
// from, in precedence order. Absent is a provisioning error: there is no
// default candidate and no implicit fall-back to a binary merely found on PATH.
func manifestPath(argvValue string) (string, error) {
	path := argvValue
	if path == "" {
		path = os.Getenv("GBE_CANDIDATE")
	}
	if path == "" {
		return "", candidateErr("pass --candidate MANIFEST (or set GBE_CANDIDATE) naming the authenticated Bash++ candidate manifest; there is no default candidate")
	}
	if !isRegularFile(path) {
		return "", candidateErr("candidate manifest is not a readable file: %s", path)
	}
	return realPath(path)
}

// moduleName reads the `module` directive of path/go.mod.
func moduleName(path string) string {
	data, err := os.ReadFile(filepath.Join(path, "go.mod"))
	if err != nil {
		return ""
	}
	for _, line := range rubyLinesChomp(string(data)) {
		if strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(line[len("module "):])
		}
	}
	return ""
}

// authenticateManifest is GoByExampleCandidate.authenticate: a supplied
// manifest against the reviewed table and the bytes on disk. Returns the
// provenance the gate records; errors on any divergence.
func authenticateManifest(manifest string, bashy string, row *Reviewed, tool *Toolchain, docs string) (*Object, error) {
	if row.Fields["go_identity"] != tool.Identity {
		return nil, candidateErr("reviewed candidate go_identity %s is not the reviewed toolchain %s", rubyInspect(row.Fields["go_identity"]), rubyInspect(tool.Identity))
	}
	sum, err := digest(manifest)
	if err != nil {
		return nil, err
	}
	if sum != row.Fields["manifest_sha256"] {
		return nil, candidateErr("candidate manifest is not the repository-reviewed manifest (%s)", sum)
	}
	data, err := os.ReadFile(manifest)
	if err != nil {
		return nil, err
	}
	parsed, err := Parse(data)
	if err != nil {
		return nil, &jsonParseError{err}
	}
	doc, ok := parsed.(*Object)
	if !ok {
		return nil, candidateErr("candidate manifest is not a JSON object")
	}
	for _, key := range []string{"launcher_sha256", "payload_sha256", "frontend_version", "build_recipe"} {
		if v, isStr := doc.Get(key).(string); !isStr || v != row.Fields[key] {
			return nil, candidateErr("candidate manifest %s differs from the reviewed table", key)
		}
	}
	declared, isArr := doc.Get("repositories").([]any)
	if !isArr || len(declared) == 0 {
		return nil, candidateErr("candidate manifest declares no repositories")
	}
	supplied := map[string]string{}
	var suppliedNames []string
	var declaredPaths []string
	for _, entry := range declared {
		repo, _ := entry.(*Object)
		if repo == nil || !repo.Has("path") {
			return nil, candidateErr("candidate manifest declares no repositories")
		}
		path := fmt.Sprint(repo.Get("path"))
		name := filepath.Base(path)
		commit, _ := repo.Get("commit").(string)
		if _, dup := supplied[name]; !dup {
			suppliedNames = append(suppliedNames, name)
		}
		supplied[name] = commit
		declaredPaths = append(declaredPaths, path)
	}
	sort.Strings(suppliedNames)
	same := len(suppliedNames) == len(row.Repositories)
	for i := range suppliedNames {
		if !same || suppliedNames[i] != row.Repositories[i] || supplied[suppliedNames[i]] != row.Commits[suppliedNames[i]] {
			same = false
		}
	}
	if !same {
		return nil, candidateErr("candidate manifest repository set differs from the reviewed runtime dependencies: %s vs %s", rubyStringArray(suppliedNames), rubyStringArray(row.Repositories))
	}
	if !isRegularFile(bashy) || !isExecutable(bashy) {
		return nil, candidateErr("Bash++ candidate launcher missing: %s", bashy)
	}
	// The corpus primitives own launcher/payload digest authentication and the
	// clean-exact-revision check for every declared repository, including
	// untracked files.
	provenance, err := authenticateCandidate(expandPath(bashy), doc)
	if err != nil {
		return nil, err
	}
	if !nativeBinary(expandPath(bashy) + ".real") {
		return nil, candidateErr("candidate payload is not a native binary")
	}
	sh := ""
	for _, path := range declaredPaths {
		if moduleName(path) == "mvdan.cc/sh/v3" {
			sh = path
			break
		}
	}
	if sh == "" {
		return nil, candidateErr("the authenticated candidate declares no mvdan.cc/sh/v3 lowering runtime; the compiled mode cannot build generated Go without it")
	}
	shReal, err := realPath(sh)
	if err != nil {
		return nil, err
	}
	candidatesSHA, err := digest(filepath.Join(docs, "candidates.tsv"))
	if err != nil {
		return nil, err
	}
	provenance.Set("manifest", Obj("path", manifest, "sha256", sum))
	provenance.Set("sh_module", Obj("path", shReal, "commit", supplied[filepath.Base(sh)]))
	provenance.Set("go_identity", row.Fields["go_identity"])
	provenance.Set("candidates_sha256", candidatesSHA)
	return provenance, nil
}

type jsonParseError struct{ err error }

func (e *jsonParseError) Error() string { return e.err.Error() }

func rubyStringArray(values []string) string {
	parts := make([]string, len(values))
	for i, v := range values {
		parts[i] = rubyInspect(v)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}
// pinnedGoroot resolves the reviewed release the way `go` itself would
// (`GOTOOLCHAIN=<version> go env GOROOT`) and authenticates its bin/go by the
// digest in toolchain.tsv. When the go on PATH is a same-version build with
// another digest (a distribution package), the toolchain module GOTOOLCHAIN
// would otherwise select -- GOMODCACHE/golang.org/toolchain@v0.0.1-<version>.<os>-<arch>
// -- is tried next; the digest requirement is never relaxed.
func pinnedGoroot(toolpin *Toolchain) (string, error) {
	gorootCmd := exec.Command("go", "env", "GOROOT")
	gorootCmd.Env = append(envWithout("GOTOOLCHAIN"), "GOTOOLCHAIN="+toolpin.Version)
	gorootOut, err := gorootCmd.Output()
	if err != nil {
		return "", fmt.Errorf("cannot resolve pinned Go toolchain")
	}
	goroot := strings.TrimSpace(string(gorootOut))
	if sum, err := sha256File(goroot + "/bin/go"); err == nil && sum == toolpin.GoSHA256 {
		return goroot, nil
	}
	modcacheCmd := exec.Command("go", "env", "GOMODCACHE")
	modcacheCmd.Env = append(envWithout("GOTOOLCHAIN"), "GOTOOLCHAIN=local")
	modcacheOut, _ := modcacheCmd.Output()
	goos, goarch := hostIdentity()
	module := strings.TrimSpace(string(modcacheOut)) + "/golang.org/toolchain@v0.0.1-" + toolpin.Version + "." + goos + "-" + goarch
	if sum, err := sha256File(module + "/bin/go"); err == nil && sum == toolpin.GoSHA256 {
		return module, nil
	}
	return goroot, nil
}
